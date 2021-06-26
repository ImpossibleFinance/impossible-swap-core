// SPDX-License-Identifier: GPL-3
pragma solidity =0.7.6;

import './ImpossibleERC20.sol';

import './libraries/Math.sol';
import './libraries/ReentrancyGuard.sol';

import './interfaces/IImpossiblePair.sol';
import './interfaces/IERC20.sol';
import './interfaces/IImpossibleFactory.sol';
import './interfaces/IImpossibleCallee.sol';

contract ImpossiblePair is IImpossiblePair, ImpossibleERC20, ReentrancyGuard {
    using SafeMath for uint256;

    uint256 public constant override MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    uint256 private constant FEE = 201; // 1/201=0.4795% fee collected from LP if (feeOn)
    // Consider making fee updatable 
    uint256 private constant THIRTY_MINS = 600; // 30 mins in 3 second blocks for BSC  - update if not BSC
    // TODO: fix this so that there's a testing period that's 50 blocks instead.
    uint256 private constant ONE_DAY = 50; // 50 for testing, will be 24*60*60/3 = 28800 in production.
    uint256 private constant TWO_WEEKS = 403200; // 2 * 7 * 24 * 60 * 60 / 3;

    address public override factory;
    address public override token0;
    address public override token1;
    address public override router;

    uint128 private reserve0; // Single storage slot
    uint128 private reserve1; // Single storage slot

    uint256 public kLast;

    // Variables for xybk invariant.
    uint32 private boost0; // Boost0 applies when pool balance0 >= balance1 (when token1 is the more expensive token)
    uint32 private boost1; // Boost1 applies when pool balance1 > balance0 (when token0 is the more expensive token)
    uint32 private newBoost0;
    uint32 private newBoost1;
    uint16 private tradeFee; // Tradefee=amt of fees collected per swap denoted in basis points
    bool private isXybk;

    uint256 public startBlockChange; // Boost linearly interpolates between start/end block when changing
    uint256 public endBlockChange; // BSC mines 10m blocks a year. uint32 lasts 400 years before overflowing

    uint8 public ratioStart;
    uint8 public ratioEnd;

//  TODO: Confirm modifiers
    uint256 private feesAccrued;

    // Delay sets the duration for boost changes over time
    uint256 public override delay;

    modifier onlyIFRouter() {
        require(msg.sender == router, 'IF: FORBIDDEN');
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == IImpossibleFactory(factory).governance(), 'IF: FORBIDDEN'); // NOTE: Comment out when running tests to allow calls to makeXybk
        _;
    }

    function getFeeAndXybk() external view override returns (uint256 _tradeFee, bool _isXybk) {
        _tradeFee = tradeFee;
        _isXybk = isXybk;
    }

    // Get reserves. No timestamp unlike uni
    function getReserves() public view override returns (uint256 _reserve0, uint256 _reserve1) {
        _reserve0 = uint256(reserve0);
        _reserve1 = uint256(reserve1);
    }

    // Helper function to get boost values
    function getBoost()
        internal
        view
        returns (
            uint32 _newBoost0,
            uint32 _newBoost1,
            uint32 _boost0,
            uint32 _boost1
        )
    {
        _newBoost0 = newBoost0;
        _newBoost1 = newBoost1;
        _boost0 = boost0;
        _boost1 = boost1;
    }

    // Helper function to calculate interpolated boost values. Allows for staircasing change of boost over time. Decimal places rounds down
    function linInterpolate(
        uint32 oldBst,
        uint32 newBst,
        uint256 end
    ) internal view returns (uint256) {
        uint256 start = startBlockChange;
        if (newBst > oldBst) {
            // old + diff * (curr-start) / (end-start)
            return
                uint256(oldBst).add(
                    (uint256(newBst).sub(uint256(oldBst))).mul(block.number.sub(start)).div(end.sub(start))
                );
        } else {
            // old - diff * (curr-start) / (end-start)
            return
                uint256(oldBst).sub(
                    (uint256(oldBst).sub(uint256(newBst))).mul(block.number.sub(start)).div(end.sub(start))
                );
        }
    }

    // Calculates boost if in the middle of a linear interpolation, else return _newBoosts
    function calcBoost() public view override returns (uint256 _boost0, uint256 _boost1) {
        uint256 _endBlockChange = endBlockChange;
        if (block.number >= _endBlockChange) {
            (uint32 _newBoost0, uint32 _newBoost1, , ) = getBoost();
            _boost0 = uint256(_newBoost0);
            _boost1 = uint256(_newBoost1);
        } else {
            (uint32 _newBoost0, uint32 _newBoost1, uint32 _oldBoost0, uint32 _oldBoost1) = getBoost();
            _boost0 = linInterpolate(_oldBoost0, _newBoost0, _endBlockChange);
            _boost1 = linInterpolate(_oldBoost1, _newBoost1, _endBlockChange);
        }
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'IF: TRANSFER_FAILED');
    }

    // Causes pool to use xybk invariant to uni invariant
    function makeXybk(
        uint8 _ratioStart,
        uint8 _ratioEnd,
        uint32 _boost0,
        uint32 _boost1
    ) external onlyGovernance nonReentrant {
        require(!isXybk, 'IF: IS_ALREADY_XYBK');
        require(0 <= _ratioStart && _ratioEnd <= 100, 'IF: IF: INVALID_RATIO');
        require(_boost0 >= 1 && _boost1 >= 1 && _boost0 <= 1000000 && _boost1 <= 1000000, 'IF: INVALID_BOOST');
        require(block.number >= endBlockChange, 'IF: BOOST_ALREADY_CHANGING');
        (uint256 _reserve0, uint256 _reserve1) = getReserves();
        _mintFee(_reserve0, _reserve1);
        boost0 = newBoost0;
        boost1 = newBoost1;
        newBoost0 = _boost0;
        newBoost1 = _boost1;
        startBlockChange = block.number;
        endBlockChange = block.number + delay;
        ratioStart = _ratioStart;
        ratioEnd = _ratioEnd;
        isXybk = true;
        emit changeInvariant(isXybk, _ratioStart, _ratioEnd);
        emit updatedBoost(boost0, boost1, newBoost0, newBoost1, startBlockChange, endBlockChange);
    }

    // makeUni requires pool to already be at boost=1. Setting isXybk=false makes efficient uni swaps.
    // Removing isXybk state might save gas on xybk swaps. Then, isXybk is a function that returns calcBoost() == (1, 1)
    function makeUni() external onlyGovernance nonReentrant {
        require(isXybk, 'IF: IS_ALREADY_UNI');
        require(block.number >= endBlockChange, 'IF: BOOST_ALREADY_CHANGING');
        require(newBoost0 == 1 && newBoost1 == 1, 'IF: INVALID_BOOST');
        isXybk = false;
        boost0 = 1;
        boost1 = 1;
        ratioStart = 0;
        ratioEnd = 100;
        emit changeInvariant(isXybk, ratioStart, ratioEnd);
    }

    function updateTradeFees(uint16 _fee) external onlyGovernance {
        require(_fee <= 1000, 'IF: INVALID_FEE'); // capped at 10%
        emit updatedTradeFees(tradeFee, _fee);
        // fee is uint so can't be negative
        tradeFee = _fee;
    }

    // Allows delay change. Default is a 1 day delay
    // Timelock of 30 minutes is a minimum
    function updateDelay(uint256 _delay) external onlyGovernance {
        require(_delay >= THIRTY_MINS && delay <= TWO_WEEKS, 'IF: INVALID_DELAY');
        emit updatedDelay(delay, _delay);
        delay = _delay;
    }

    // Updates lower/upper hardstops for a pool
    function updateHardstops(uint8 _ratioStart, uint8 _ratioEnd) external onlyGovernance nonReentrant {
        require(isXybk, 'IF: IS_CURRENTLY_UNI');
        require(0 <= _ratioStart && _ratioEnd <= 100, 'IF: INVALID_RATIO');
        ratioStart = _ratioStart;
        ratioEnd = _ratioEnd;
        emit updatedHardstops(_ratioStart, _ratioEnd);
    }

    // Updates boost values. Boost changes over delay number of blocks.
    function updateBoost(uint32 _boost0, uint32 _boost1) external onlyGovernance nonReentrant {
        require(isXybk, 'IF: IS_CURRENTLY_UNI');
        require(_boost0 >= 1 && _boost1 >= 1 && _boost0 <= 1000000 && _boost1 <= 1000000, 'IF: INVALID_BOOST');
        require(block.number >= endBlockChange, 'IF: BOOST_ALREADY_CHANGING');
        boost0 = newBoost0;
        boost1 = newBoost1;
        newBoost0 = _boost0;
        newBoost1 = _boost1;
        startBlockChange = block.number;
        endBlockChange = block.number + delay;
        emit updatedBoost(boost0, boost1, newBoost0, newBoost1, startBlockChange, endBlockChange);
    }

    constructor() {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(
        address _token0,
        address _token1,
        address _router
    ) external override {
        require(msg.sender == factory, 'IF: FORBIDDEN'); // sufficient check
        router = _router;
        token0 = _token0;
        token1 = _token1;
        boost0 = 1;
        boost1 = 1;
        newBoost0 = 1;
        newBoost1 = 1;
        tradeFee = 30; // 30 basis points
        delay = ONE_DAY;
    }

    // update reserves and, on the first call per block, price accumulators
    // PriceCumulativeLast calculations will cost too much gas for Impossibleswap invariant - scrap feature
    function _update(uint256 balance0, uint256 balance1) private {
        reserve0 = uint128(balance0);
        reserve1 = uint128(balance1);
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 4/5th of the growth in sqrt(k)
    function _mintFee(uint256 _reserve0, uint256 _reserve1) private returns (bool feeOn) {
        address feeTo = IImpossibleFactory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK =
                    isXybk ? Math.sqrt(_xybkComputeK(_reserve0, _reserve1)) : Math.sqrt(_reserve0.mul(_reserve1));
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator = totalSupply.mul(rootK.sub(rootKLast)).mul(4);
                    uint256 denominator = rootK.add(rootKLast.mul(4));
                    uint256 liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // Unchanged - LP tokens represent proportion of tokens in pool
    function mint(address to) external override nonReentrant returns (uint256 liquidity) {
        (uint256 _reserve0, uint256 _reserve1) = getReserves(); // gas savings
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0.sub(_reserve0);
        uint256 amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'IF: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1);
        if (feeOn) kLast = isXybk ? _xybkComputeK(balance0, balance1) : balance0.mul(balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint256 _reserve0, uint256 _reserve1) = getReserves(); // gas savings
        bool feeOn = _mintFee(_reserve0, _reserve1);
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        {
            // Scope for _totalSupply is only within this block
            uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
            amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
            amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution

            require(amount0 > 0 && amount1 > 0, 'IF: INSUFFICIENT_LIQUIDITY_BURNED');

            if (feeOn) {
                uint256 _FEE = FEE;
                amount0 -= amount0.div(_FEE);
                amount1 -= amount1.div(_FEE);
                // Check that this doesn't break scope or stack limit
                // Takes the 0.4975% Fee of LP tokens and adds allowance to claim for the IImpossibleFactory feeTo Address
                feesAccrued.add(amount0.div(_FEE));
                // _safeTransfer(address(this), IImpossibleFactory(factory).feeTo(), liquidity.div(_FEE));
                _burn(address(this), liquidity.sub(liquidity.div(_FEE)));
            } else {
                _burn(address(this), liquidity);
            }

            // Outside of this if feeOn statement, returns the appropriate funds to the user
            _safeTransfer(_token0, to, amount0);
            _safeTransfer(_token1, to, amount1);
        }

        // Grabs the new balances of the tokens in the LP pool after the withdrawal takes place
        {
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
            _update(balance0, balance1);
            if (feeOn) kLast = isXybk ? _xybkComputeK(balance0, balance1) : balance0.mul(balance1);
        }
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // Without safety checks, calling swap directly will throw failure at bounds
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external override onlyIFRouter nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, 'IF: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint256 _reserve0, uint256 _reserve1) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'IF: INSUFFICIENT_LIQUIDITY');

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
            if (_isXybk) {
                bool side = balance0 >= balance1;
                uint256 ratio = side ? ratioStart : ratioEnd;
                if (side && ratio > 0) {
                    require(balance1.mul(ratio) < balance0.mul(100 - ratio), 'IF: EXCEED_UPPER_STOP');
                } else if (!side && ratio < 100) {
                    require(balance0.mul(ratio) > balance1.mul(100 - ratio), 'IF: EXCEED_LOWER_STOP');
                }
            }
            uint256 _tradeFee = uint256(tradeFee); // Gas savings?
            uint256 balance0Adjusted = balance0.mul(10000).sub(amount0In.mul(_tradeFee)); // tradeFee amt of basis pts
            uint256 balance1Adjusted = balance1.mul(10000).sub(amount1In.mul(_tradeFee)); // tradeFee amt of basis pts
            _isXybk
                ? require(
                    _xybkCheckK(balance0Adjusted, balance1Adjusted, _xybkComputeK(_reserve0, _reserve1).mul(10000**2)),
                    'IF: INSUFFICIENT_XYBK_K'
                )
                : require(
                    balance0Adjusted.mul(balance1Adjusted) >= _reserve0.mul(_reserve1).mul(10000**2),
                    'IF: INSUFFICIENT_UNI_K'
                );
        }

        _update(balance0, balance1);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // Calculating new stableswap invariant K value given balance0, balance1
    // Exact calculation of K given token balances. Called after mint/burn/swaps
    // let i=(boost-1)*(x+y)/(4*boost-2); sqrtK = sqrt(i**2 + b0*b1/(2*boost-1)) + i
    function _xybkComputeK(uint256 _balance0, uint256 _balance1) private view returns (uint256 k) {
        (uint256 _boost0, uint256 _boost1) = calcBoost();
        uint256 boost = (_balance0 > _balance1) ? _boost0.sub(1) : _boost1.sub(1);
        uint256 denom = boost.mul(2).add(1); // 1+2*boost
        uint256 term = boost.mul(_balance0.add(_balance1)).div(denom.mul(2)); // boost*(x+y)/(2+4*boost)
        k = (Math.sqrt(term**2 + _balance0.mul(_balance1).div(denom)) + term)**2;
    }

    // Calculating new stableswap invariant K given balance0, balance1, old K
    // Called to check K invariance post-swap
    // let i=(boost-1)*sqrt(K_old); K_new = (b0+i)*(b1+i)/(boost**2)
    // If K_new > K_old, this check still maintains correctness
    function _xybkCheckK(
        uint256 _balance0,
        uint256 _balance1,
        uint256 _oldK
    ) private view returns (bool) {
        uint256 sqrtOldK = Math.sqrt(_oldK);
        (uint256 _boost0, uint256 _boost1) = calcBoost();
        uint256 boost = (_balance0 > _balance1) ? _boost0.sub(1) : _boost1.sub(1);
        uint256 innerTerm = boost.mul(sqrtOldK);
        return (_balance0.add(innerTerm)).mul(_balance1.add(innerTerm)).div((boost.add(1))**2) >= _oldK;
    }

//  Can be called by anyone 
// TODO: Confirm if this should be called by anyone versus if we should limit to only fee address itself should call 
// In theory, there could be other addresses that call this in a cron job every say 2 weeks.
    function claimFees() external override nonReentrant {
        uint256 transferAmount = feesAccrued;
        feesAccrued = 0; //Resets amount owed to claim to zero first
        _safeTransfer(address(this), IImpossibleFactory(factory).feeTo(), feesAccrued); //Tranfers owed debt to fee collection address
    }

    // force balances to match reserves
    function skim(address to) external override nonReentrant {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        (uint256 _reserve0, uint256 _reserve1) = getReserves();
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(_reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(_reserve1));
    }

    // force reserves to match balances
    function sync() external override nonReentrant {
        uint256 _balance0 = IERC20(token0).balanceOf(address(this));
        uint256 _balance1 = IERC20(token1).balanceOf(address(this));
        _update(_balance0, _balance1);
    }
}
