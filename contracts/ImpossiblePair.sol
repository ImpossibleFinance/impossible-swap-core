/// SPDX-License-Identifier: GPL-3
pragma solidity =0.7.6;

import './ImpossibleERC20.sol';

import './libraries/Math.sol';
import './libraries/ReentrancyGuard.sol';

import './interfaces/IImpossiblePair.sol';
import './interfaces/IERC20.sol';
import './interfaces/IImpossibleSwapFactory.sol';
import './interfaces/IImpossibleCallee.sol';

/**
    @title  Pair contract for Impossible Swap V3
    @author Impossible Finance
    @notice This factory builds upon basic Uni V2 Pair by adding xybk
            invariant, ability to switch between invariants/boost levels,
            and ability to set asymmetrical tuning.
    @dev    See documentation at: https://docs.impossible.finance/impossible-swap/overview
*/
contract ImpossiblePair is IImpossiblePair, ImpossibleERC20, ReentrancyGuard {
    using SafeMath for uint256;

    uint256 public constant override MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    /**
     @dev It's impractical to call evm_mine 28800 times per test so we set to 50
     @dev These time vars are based on BSC's 3 second block time
    */
    uint256 private constant THIRTY_MINS = 600;
    uint32 private constant TWO_WEEKS = 403200;
    uint32 private constant ONE_DAY_PROD = 28800;
    uint32 private constant ONE_DAY_TESTING = 50;

    /**
     @dev tradeFee is fee collected per swap in basis points. Init at 30bp.
    */
    uint16 private tradeFee = 30;

    /**
     @dev tradeState Tracks what directional trades are allowed for this pair.
    */
    TradeState public tradeState;

    bool private isXybk;

    address public override factory;
    address public override token0;
    address public override token1;
    address public router;
    address public routerExtension;

    uint128 private reserve0;
    uint128 private reserve1;

    uint256 public kLast;

    /**
     @dev These are the variables for boost.
     @dev Boosts in practice are a function of oldBoost, newBoost, startBlock and endBlock
     @dev We linearly interpolate between oldBoost and newBoost over the blocks
     @dev Note that governance being able to instantly change boosts is dangerous
     @dev Boost0 applies when pool balance0 >= balance1 (when token1 is the more expensive token)
     @dev Boost1 applies when pool balance1 > balance0 (when token0 is the more expensive token)
    */
    uint32 private oldBoost0 = 1;
    uint32 private oldBoost1 = 1;
    uint32 private newBoost0 = 1;
    uint32 private newBoost1 = 1;
    uint32 private currBoost0 = 1;
    uint32 private currBoost1 = 1;

    /**
     @dev BSC mines 10m blocks a year. uint32 will last 400 years before overflowing
    */
    uint256 public startBlockChange;
    uint256 public endBlockChange;

    /**
     @dev withdrawalFeeRatio is the fee collected on burn. Init as 1/201=0.4795% fee (if feeOn)
    */
    uint256 public withdrawalFeeRatio = 201; //

    /**
     @dev Delay sets the duration for boost changes over time. Init as 1 day
     @dev In test environment, set to 50 blocks.
    */
    uint256 public override delay = ONE_DAY_TESTING;

    modifier onlyIFRouter() {
        require(msg.sender == router || msg.sender == routerExtension, 'IF: FORBIDDEN');
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == IImpossibleSwapFactory(factory).governance(), 'IF: FORBIDDEN');
        _;
    }

    /**
     @notice Gets the fee per swap in basis points, as well as if this pair is uni or xybk
     @return _tradeFee Fee per swap in basis points
     @return _tradeState What trades are allowed for this pair
     @return _isXybk Boolean if this swap is using uniswap or xybk
    */
    function getPairSettings()
        external
        view
        override
        returns (
            uint16 _tradeFee,
            TradeState _tradeState,
            bool _isXybk
        )
    {
        _tradeFee = tradeFee;
        _tradeState = tradeState;
        _isXybk = isXybk;
    }

    /**
     @notice Gets the reserves in the pair contract
     @return _reserve0 Reserve amount of token0 in the pair
     @return _reserve1 Reserve amount of token1 in the pair
    */
    function getReserves() public view override returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = uint256(reserve0);
        _reserve1 = uint256(reserve1);
    }

    /**
     @notice Getter for the stored boost state
     @dev Helper function for internal use. If uni invariant, all boosts=1
     @return _newBoost0 New boost0 value
     @return _newBoost1 New boost1 value
     @return _oldBoost0 Old boost0 value
     @return _oldBoost1 Old boost1 value
    */
    function getBoost()
        internal
        view
        returns (
            uint32 _newBoost0,
            uint32 _newBoost1,
            uint32 _oldBoost0,
            uint32 _oldBoost1,
            uint32 _currBoost0,
            uint32 _currBoost1
        )
    {
        _newBoost0 = newBoost0;
        _newBoost1 = newBoost1;
        _oldBoost0 = oldBoost0;
        _oldBoost1 = oldBoost1;
        _currBoost0 = currBoost0;
        _currBoost1 = currBoost1;
    }

    /**
     @notice Helper function to calculate a linearly interpolated boost
     @dev Calculations: old + |new - old| * (curr-start)/end-start
     @param oldBst The old boost
     @param newBst The new boost
     @param end The endblock which linear interpolation ends at
     @return uint256 Linearly interpolated boost value
    */
    function linInterpolate(
        uint32 oldBst,
        uint32 newBst,
        uint256 end
    ) internal view returns (uint256) {
        uint256 start = startBlockChange;
        if (newBst > oldBst) {
            /// old + diff * (curr-start) / (end-start)
            return
                uint256(oldBst).add(
                    (uint256(newBst).sub(uint256(oldBst))).mul(block.number.sub(start)).div(end.sub(start))
                );
        } else {
            /// old - diff * (curr-start) / (end-start)
            return
                uint256(oldBst).sub(
                    (uint256(oldBst).sub(uint256(newBst))).mul(block.number.sub(start)).div(end.sub(start))
                );
        }
    }

    /**
     @notice Function to get/calculate actual boosts in the system
     @dev If block.number > endBlock, just return new boosts
     @return _boost0 The actual boost0 value
     @return _boost1 The actual boost1 value
    */
    function calcBoost() public view override returns (uint256 _boost0, uint256 _boost1) {
        uint256 _endBlockChange = endBlockChange;
        if (block.number >= _endBlockChange) {
            (uint32 _newBoost0, uint32 _newBoost1, , , , ) = getBoost();
            _boost0 = uint256(_newBoost0);
            _boost1 = uint256(_newBoost1);
        } else {
            (
                uint32 _newBoost0,
                uint32 _newBoost1,
                uint32 _oldBoost0,
                uint32 _oldBoost1,
                uint32 _currBoost0,
                uint32 _currBoost1
            ) = getBoost();
            _boost0 = linInterpolate(_oldBoost0, _newBoost0, _endBlockChange);
            _boost1 = linInterpolate(_oldBoost1, _newBoost1, _endBlockChange);
            if (xybkComputeK(_boost0, _boost1) < kLast) {
                _boost0 = _currBoost0;
                _boost1 = _currBoost1;
            }
        }
    }

    function calcBoostWithUpdate() internal returns (uint256 _boost0, uint256 _boost1) {
        (_boost0, _boost1) = calcBoost();
        currBoost0 = uint32(_boost0);
        currBoost1 = uint32(_boost1);
    }

    /**
     @notice Safe transfer implementation for tokens
     @dev Requires the transfer to succeed and return either null or True
     @param token The token to transfer
     @param to The address to transfer to
     @param value The amount of tokens to transfer
    */
    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'IF: TRANSFER_FAILED');
    }

    /**
     @notice Switches pool from uniswap invariant to xybk invariant
     @dev Can only be called by IF governance
     @dev Requires the pool to be uniswap invariant currently
     @param _newBoost0 The new boost0
     @param _newBoost1 The new boost1
    */
    function makeXybk(uint32 _newBoost0, uint32 _newBoost1) external onlyGovernance nonReentrant {
        require(!isXybk, 'IF: IS_ALREADY_XYBK');
        _updateBoost(_newBoost0, _newBoost1);
        isXybk = true;
        emit changeInvariant(isXybk, _newBoost0, _newBoost1);
    }

    /**
     @notice Switches pool from xybk invariant to uniswap invariant
     @dev Can only be called by IF governance
     @dev Requires the pool to be xybk invariant currently
    */
    function makeUni() external onlyGovernance nonReentrant {
        require(isXybk, 'IF: IS_ALREADY_UNI');
        require(block.number >= endBlockChange, 'IF: BOOST_ALREADY_CHANGING');
        require(newBoost0 == 1 && newBoost1 == 1, 'IF: INVALID_BOOST');
        isXybk = false;
        oldBoost0 = 1; // Set boost to 1
        oldBoost1 = 1; // xybk with boost=1 is just xy=k formula
        emit changeInvariant(isXybk, newBoost0, newBoost1);
    }

    /**
     @notice Setter function for trade fee per swap
     @dev Can only be called by IF governance
     @dev uint8 fee means 255 basis points max, or max trade fee of 2.56%
     @dev uint8 type means fee cannot be negative
     @param _newFee The new trade fee collected per swap, in basis points
    */
    function updateTradeFees(uint8 _newFee) external onlyGovernance {
        uint16 _oldFee = tradeFee;
        tradeFee = uint16(_newFee);
        emit updatedTradeFees(_oldFee, _newFee);
    }

    /**
     @notice Setter function for time delay for boost changes
     @dev Can only be called by IF governance
     @dev Delay must be between 30 minutes and 2 weeks
     @param _newDelay The new time delay in BSC blocks (3 second block time)
    */
    function updateDelay(uint256 _newDelay) external onlyGovernance {
        require(_newDelay >= THIRTY_MINS && delay <= TWO_WEEKS, 'IF: INVALID_DELAY');
        uint256 _oldDelay = delay;
        delay = _newDelay;
        emit updatedDelay(_oldDelay, _newDelay);
    }

    /**
     @notice Setter function for trade state for this pair
     @dev Can only be called by IF governance
     @param _tradeState See line 45 for TradeState enum settings
    */
    function updateTradeState(TradeState _tradeState) external onlyGovernance nonReentrant {
        require(isXybk, 'IF: IS_CURRENTLY_UNI');
        tradeState = _tradeState;
        emit updatedTradeState(_tradeState);
    }

    /**
     @notice Setter function for pool boost state
     @dev Can only be called by IF governance
     @dev Pool has to be using xybk invariant to update boost
     @param _newBoost0 The new boost0
     @param _newBoost1 The new boost1
    */
    function updateBoost(uint32 _newBoost0, uint32 _newBoost1) external onlyGovernance nonReentrant {
        require(isXybk, 'IF: IS_CURRENTLY_UNI');
        _updateBoost(_newBoost0, _newBoost1);
    }

    /**
     @notice Internal helper function to change boosts
     @dev _newBoost0 and _newBoost1 have to be between 1 and 1000000
     @dev Pool cannot already have changing boosts
     @param _newBoost0 The new boost0
     @param _newBoost1 The new boost1
    */
    function _updateBoost(uint32 _newBoost0, uint32 _newBoost1) internal {
        require(
            _newBoost0 >= 1 && _newBoost1 >= 1 && _newBoost0 <= 1000000 && _newBoost1 <= 1000000,
            'IF: INVALID_BOOST'
        );
        require(block.number >= endBlockChange, 'IF: BOOST_ALREADY_CHANGING');
        (uint256 _reserve0, uint256 _reserve1) = getReserves();
        _mintFee(_reserve0, _reserve1);
        oldBoost0 = newBoost0;
        oldBoost1 = newBoost1;
        newBoost0 = _newBoost0;
        newBoost1 = _newBoost1;
        startBlockChange = block.number;
        endBlockChange = block.number + delay;
        emit updatedBoost(oldBoost0, oldBoost1, newBoost0, newBoost1, startBlockChange, endBlockChange);
    }

    /**
     @notice Setter function for the withdrawal fee that goes to Impossible per burn
     @dev Can only be called by IF governance
     @dev Fee is 1/_newFeeRatio. So <1% is 1/(>=100)
     @param _newFeeRatio The new fee ratio
    */
    function updateWithdrawalFeeRatio(uint256 _newFeeRatio) external onlyGovernance {
        require(_newFeeRatio >= 100, 'IF: INVALID_FEE'); // capped at 1%
        uint256 _oldFeeRatio = withdrawalFeeRatio;
        withdrawalFeeRatio = _newFeeRatio;
        emit updatedWithdrawalFeeRatio(_oldFeeRatio, _newFeeRatio);
    }

    /**
     @notice Constructor function for pair address
     @dev For pairs associated with IF swap, msg.sender is always the factory
    */
    constructor() {
        factory = msg.sender;
    }

    /**
     @notice Initialization function by factory on deployment
     @dev Can only be called by factory, and will only be called once
     @dev _initBetterDesc adds token0/token1 symbols to ERC20 LP name, symbol
     @param _token0 Address of token0 in pair
     @param _token0 Address of token1 in pair
     @param _router Address of trusted IF router
    */
    function initialize(
        address _token0,
        address _token1,
        address _router,
        address _routerExtension
    ) external override {
        require(msg.sender == factory, 'IF: FORBIDDEN');
        router = _router;
        routerExtension = _routerExtension;
        token0 = _token0;
        token1 = _token1;
        _initBetterDesc(_token0, _token1);
    }

    /**
     @notice Updates reserve state in pair
     @dev No TWAP/oracle functionality
     @param balance0 The new balance for token0
     @param balance1 The new balance for token1
    */
    function _update(uint256 balance0, uint256 balance1) private {
        reserve0 = uint128(balance0);
        reserve1 = uint128(balance1);
        emit Sync(reserve0, reserve1);
    }

    /**
     @notice Mints fee to IF governance multisig treasury
     @dev If feeOn, mint liquidity equal to 4/5th of growth in sqrt(K)
     @param _reserve0 The latest balance for token0 for fee calculations
     @param _reserve1 The latest balance for token1 for fee calculations
     @return feeOn If the mint/burn fee is turned on in this pair
    */
    function _mintFee(uint256 _reserve0, uint256 _reserve1) private returns (bool feeOn) {
        address feeTo = IImpossibleSwapFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 oldK = kLast; // gas savings
        if (feeOn) {
            if (oldK != 0) {
                (uint256 _boost0, uint256 _boost1) = calcBoostWithUpdate();
                uint256 newRootK = isXybk
                    ? Math.sqrt(xybkComputeK(_boost0, _boost1))
                    : Math.sqrt(_reserve0.mul(_reserve1));
                uint256 oldRootK = Math.sqrt(oldK);
                if (newRootK > oldRootK) {
                    uint256 numerator = totalSupply.mul(newRootK.sub(oldRootK)).mul(4);
                    uint256 denominator = newRootK.add(oldRootK.mul(4));
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (oldK != 0) {
            kLast = 0;
        }
    }

    /**
     @notice Mints LP tokens based on sent underlying tokens. Underlying tokens must already be sent to contract
     @dev Function should be called from IF router unless you know what you're doing
     @dev Openzeppelin reentrancy guards are used
     @dev First mint must have both token0 and token1. 
     @param to The address to mint LP tokens to
     @return liquidity The amount of LP tokens minted
    */
    function mint(address to) external override nonReentrant returns (uint256 liquidity) {
        (uint256 _reserve0, uint256 _reserve1) = getReserves(); // gas savings
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0.sub(_reserve0);
        uint256 amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(
                _reserve0 > 0 ? amount0.mul(_totalSupply) / _reserve0 : uint256(-1),
                _reserve1 > 0 ? amount1.mul(_totalSupply) / _reserve1 : uint256(-1)
            );
        }
        require(liquidity > 0, 'IF: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1);
        (uint256 _boost0, uint256 _boost1) = calcBoostWithUpdate();
        if (feeOn) kLast = isXybk ? xybkComputeK(_boost0, _boost1) : balance0.mul(balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     @notice Burns LP tokens and returns underlying tokens. LP tokens must already be sent to contract
     @dev Function should be called from IF router unless you know what you're doing
     @dev Openzeppelin reentrancy guards are used
     @param to The address to send underlying tokens to
     @return amount0 The amount of token0's sent
     @return amount1 The amount of token1's sent
    */
    function burn(address to) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint256 _reserve0, uint256 _reserve1) = getReserves(); // gas savings
        bool feeOn = _mintFee(_reserve0, _reserve1);
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        {
            uint256 _totalSupply = totalSupply;
            amount0 = liquidity.mul(balance0) / _totalSupply;
            amount1 = liquidity.mul(balance1) / _totalSupply;
            require(amount0 > 0 || amount1 > 0, 'IF: INSUFFICIENT_LIQUIDITY_BURNED');

            address _feeTo = IImpossibleSwapFactory(factory).feeTo();
            // Burning fees are paid if burner is not IF fee collector
            if (msg.sender != _feeTo) {
                if (feeOn) {
                    uint256 _feeRatio = withdrawalFeeRatio; // default is 1/201 ~= 0.4975%
                    amount0 -= amount0.div(_feeRatio);
                    amount1 -= amount1.div(_feeRatio);
                    // Transfers withdrawalFee of LP tokens to IF feeTo
                    uint256 transferAmount = liquidity.div(_feeRatio);
                    _safeTransfer(address(this), IImpossibleSwapFactory(factory).feeTo(), transferAmount);
                    _burn(address(this), liquidity.sub(transferAmount));
                } else {
                    _burn(address(this), liquidity);
                }
            }

            _safeTransfer(_token0, to, amount0);
            _safeTransfer(_token1, to, amount1);
        }

        {
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
            _update(balance0, balance1);
            if (feeOn) kLast = isXybk ? xybkComputeK(balance0, balance1) : balance0.mul(balance1);
        }
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     @notice Performs a swap operation. Tokens must already be sent to contract
     @dev Input/output amount of tokens must >0 and pool needs to have sufficient liquidity
     @dev Openzeppelin reentrancy guards are used
     @dev Post-swap invariant check is performed (either uni or xybk)
     @param amount0Out The amount of token0's to output
     @param amount1Out The amount of token1's to output
     @param to The address to output tokens to
     @param data Call data allowing for another function call
    */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external override onlyIFRouter nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, 'IF: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint256 _reserve0, uint256 _reserve1) = getReserves(); // gas savings
        require(amount0Out <= _reserve0 && amount1Out <= _reserve1, 'IF: INSUFFICIENT_LIQUIDITY');

        uint256 balance0;
        uint256 balance1;
        uint256 amount0In;
        uint256 amount1In;
        {
            require(to != token0 && to != token1, 'IF: INVALID_TO');
            if (amount0Out > 0) _safeTransfer(token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0) IImpossibleCallee(to).ImpossibleCall(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(token0).balanceOf(address(this));
            balance1 = IERC20(token1).balanceOf(address(this));
            // Check bounds
            amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
            amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        }

        require(amount0In > 0 || amount1In > 0, 'IF: INSUFFICIENT_INPUT_AMOUNT');

        {
            // Avoid stack too deep errors
            bool _isXybk = isXybk;
            uint256 _tradeFee = uint256(tradeFee);
            uint256 balance0Adjusted = balance0.mul(10000).sub(amount0In.mul(_tradeFee)); // tradeFee amt of basis pts
            uint256 balance1Adjusted = balance1.mul(10000).sub(amount1In.mul(_tradeFee)); // tradeFee amt of basis pts
            if (_isXybk) {
                // Check if trade is legal
                TradeState _tradeState = tradeState;
                require(
                    (_tradeState == TradeState.SELL_ALL) ||
                        (_tradeState == TradeState.SELL_TOKEN_0 && amount1Out == 0) ||
                        (_tradeState == TradeState.SELL_TOKEN_1 && amount0Out == 0),
                    'IF: TRADE_NOT_ALLOWED'
                );

                (uint256 boost0, uint256 boost1) = calcBoostWithUpdate();
                uint256 scaledOldK = xybkComputeK(boost0, boost1).mul(10000**2);
                require(
                    xybkCheckK(boost0, boost1, balance0Adjusted, balance1Adjusted, scaledOldK),
                    'IF: INSUFFICIENT_XYBK_K'
                );
            } else {
                require(
                    balance0Adjusted.mul(balance1Adjusted) >= _reserve0.mul(_reserve1).mul(10000**2),
                    'IF: INSUFFICIENT_UNI_K'
                );
            }
        }

        _update(balance0, balance1);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /** 
     @notice Calculates xybk K value
     @dev Uses library function, same as router
     @param _boost0 boost0 to calculate xybk K with
     @param _boost1 boost1 to calculate xybk K with
     @return k The k value given these reserves and boost values
     */
    function xybkComputeK(uint256 _boost0, uint256 _boost1) internal view returns (uint256 k) {
        (uint256 _reserve0, uint256 _reserve1) = getReserves();
        uint256 boost = (_reserve0 > _reserve1) ? _boost0.sub(1) : _boost1.sub(1);
        uint256 denom = boost.mul(2).add(1); // 1+2*boost
        uint256 term = boost.mul(_reserve0.add(_reserve1)).div(denom.mul(2)); // boost*(x+y)/(2+4*boost)
        k = (Math.sqrt(term**2 + _reserve0.mul(_reserve1).div(denom)) + term)**2;
    }

    /**
     @notice Performing K invariant check through an approximation from old K
     @dev More details on math at: https://docs.impossible.finance/impossible-swap/swap-math
     @dev If K_new >= K_old, correctness should still hold
     @param boost0 Current boost0 in pair
     @param boost1 Current boost1 in pair
     @param balance0 Current state of balance0 in pair
     @param balance1 Current state of balance1 in pair
     @param oldK The pre-swap K value
     @return bool Whether the new balances satisfy the K check for xybk
    */
    function xybkCheckK(
        uint256 boost0,
        uint256 boost1,
        uint256 balance0,
        uint256 balance1,
        uint256 oldK
    ) internal pure returns (bool) {
        uint256 oldSqrtK = Math.sqrt(oldK);
        uint256 boost = (balance0 > balance1) ? boost0.sub(1) : boost1.sub(1);
        uint256 innerTerm = boost.mul(oldSqrtK);
        return (balance0.add(innerTerm)).mul(balance1.add(innerTerm)).div((boost.add(1))**2) >= oldK;
    }

    /**
     @notice Forces balances to match reserves
     @dev Requires balance0 >= reserve0 and balance1 >= reserve1
     @param to Address to send excess underlying tokens to
    */
    function skim(address to) external override nonReentrant {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        (uint256 _reserve0, uint256 _reserve1) = getReserves();
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(_reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(_reserve1));
    }

    /**
     @notice Forces reserves to match balances
    */
    function sync() external override nonReentrant {
        uint256 _balance0 = IERC20(token0).balanceOf(address(this));
        uint256 _balance1 = IERC20(token1).balanceOf(address(this));
        _update(_balance0, _balance1);
    }
}
