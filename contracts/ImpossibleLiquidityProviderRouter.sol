// SPDX-License-Identifier: GPL-3
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import './interfaces/IImpossibleSwapFactory.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';
import './libraries/ReentrancyGuard.sol';

import './interfaces/IImpossibleLiquidityProviderRouter.sol';
import './libraries/ImpossibleLibrary.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';
import './interfaces/IImpossibleWrappedToken.sol';
import './interfaces/IImpossibleWrapperFactory.sol';

/**
    @title  Router02 for Impossible Swap V3
    @author Impossible Finance
    @notice This router builds upon basic Uni V2 Router02 by allowing custom
            calculations based on settings in pairs (uni/xybk/custom fees)
    @dev    See documentation at: https://docs.impossible.finance/impossible-swap/overview
    @dev    Very little logical changes made in Router02. Most changes to accomodate xybk are in Library
*/

contract ImpossibleLiquidityProviderRouter is IImpossibleLiquidityProviderRouter, ReentrancyGuard {
    using SafeMath for uint256;

    address public immutable override factory;
    address public immutable wrapFactory;
    address public override WETH; // Can be set by WETHSetter once only
    address private WETHSetter; // to reduce deployed bytecode size

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, 'ImpossibleRouter: EXPIRED');
        _;
    }

    /**
     @notice Constructor for IF Router
     @param _pairFactory Address of IF Pair Factory
     @param _wrapFactory Address of IF`
     @param _WETHSetter Address of WETHSetter 
    */
    constructor(
        address _pairFactory,
        address _wrapFactory,
        address _WETHSetter
    ) {
        factory = _pairFactory;
        wrapFactory = _wrapFactory;
        WETHSetter = _WETHSetter;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    /**
     @notice Helper function for sending tokens that might need to be wrapped
     @param token The address of the token that might have a wrapper
     @param src The source to take underlying tokens from
     @param dst The destination to send wrapped tokens to
     @param amt The amount of tokens to send (wrapped tokens, not underlying)
    */
    function wrapSafeTransfer(
        address token,
        address src,
        address dst,
        uint256 amt
    ) internal {
        address underlying = IImpossibleWrapperFactory(wrapFactory).wrappedTokensToTokens(token);
        if (underlying == address(0x0)) {
            TransferHelper.safeTransferFrom(token, src, dst, amt);
        } else {
            uint256 underlyingAmt = IImpossibleWrappedToken(token).amtToUnderlyingAmt(amt);
            TransferHelper.safeApprove(underlying, token, underlyingAmt);
            IImpossibleWrappedToken(token).deposit(dst, underlyingAmt);
        }
    }

    /**
     @notice Helper function for sending tokens that might need to be unwrapped
     @param token The address of the token that might be wrapped
     @param dst The destination to send underlying tokens to
     @param amt The amount of wrapped tokens to send (wrapped tokens, not underlying)
    */
    function unwrapSafeTransfer(
        address token,
        address dst,
        uint256 amt
    ) internal {
        address underlying = IImpossibleWrapperFactory(wrapFactory).wrappedTokensToTokens(token);
        if (underlying == address(0x0)) {
            TransferHelper.safeTransfer(token, dst, amt);
        } else {
            IImpossibleWrappedToken(token).withdraw(dst, amt);
        }
    }

    /**
     @notice Function to set weth address
     @dev We use this logic to allow routers to have same address on every chain through create2
     @dev Wasn't possible in previous design as WETH/WBNB/WFTM etc have different contract addresses
     @dev Only can be set once, and only can be set by WETHSetter
     @param _WETH The address of wrapped native token (WETH, WBNB etc)
    */
    function setWETH(address _WETH) public {
        require(WETH == address(0x0), 'ImpossibleRouter: Already set');
        require(msg.sender == WETHSetter, 'ImpossibleRouter: ?');
        WETH = _WETH;
    }

    /**
     @notice Helper function for adding liquidity
     @dev Logic is unchanged from uniswap-V2-Router02
     @param tokenA The address of underlying tokenA to add
     @param tokenB The address of underlying tokenB to add
     @param amountADesired The desired amount of tokenA to add
     @param amountBDesired The desired amount of tokenB to add
     @param amountAMin The min amount of tokenA to add (amountAMin:amountBDesired sets bounds on ratio)
     @param amountBMin The min amount of tokenB to add (amountADesired:amountBMin sets bounds on ratio)
     @return amountA Actual amount of tokenA added as liquidity to pair
     @return amountB Actual amount of tokenB added as liquidity to pair
    */
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        // create the pair if it doesn't exist yet
        if (IImpossibleSwapFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IImpossibleSwapFactory(factory).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB, ) = ImpossibleLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = ImpossibleLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'ImpossibleRouter: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = ImpossibleLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'ImpossibleRouter: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /**
     @notice Function for basic add liquidity functionality
     @dev Openzeppelin reentrancy guards
     @param tokenA The address of underlying tokenA to add
     @param tokenB The address of underlying tokenB to add
     @param amountADesired The desired amount of tokenA to add
     @param amountBDesired The desired amount of tokenB to add
     @param amountAMin The min amount of tokenA to add (amountAMin:amountBDesired sets bounds on ratio)
     @param amountBMin The min amount of tokenB to add (amountADesired:amountBMin sets bounds on ratio)
     @param to The address to mint LP tokens to
     @param deadline The block number after which this transaction is invalid
     @return amountA Amount of tokenA added as liquidity to pair
     @return amountB Actual amount of tokenB added as liquidity to pair
     @return liquidity Actual amount of LP tokens minted
    */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        nonReentrant
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = ImpossibleLibrary.pairFor(factory, tokenA, tokenB);
        wrapSafeTransfer(tokenA, msg.sender, pair, amountA);
        wrapSafeTransfer(tokenB, msg.sender, pair, amountB);
        liquidity = IImpossiblePair(pair).mint(to);
    }

    /**
     @notice Function for add liquidity functionality with 1 token being WETH/WBNB
     @dev Openzeppelin reentrancy guards
     @param token The address of the non-ETH underlying token to add
     @param amountTokenDesired The desired amount of non-ETH underlying token to add
     @param amountTokenMin The min amount of non-ETH underlying token to add (amountTokenMin:ETH sent sets bounds on ratio)
     @param amountETHMin The min amount of WETH/WBNB to add (amountTokenDesired:amountETHMin sets bounds on ratio)
     @param to The address to mint LP tokens to
     @param deadline The block number after which this transaction is invalid
     @return amountToken Amount of non-ETH underlying token added as liquidity to pair
     @return amountETH Actual amount of WETH/WBNB added as liquidity to pair
     @return liquidity Actual amount of LP tokens minted
    */
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        nonReentrant
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        )
    {
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = ImpossibleLibrary.pairFor(factory, token, WETH);
        wrapSafeTransfer(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IImpossiblePair(pair).mint(to);
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH); // refund dust eth, if any
    }

    /**
     @notice Helper function for removing liquidity
     @dev Logic is unchanged from uniswap-V2-Router02
     @param tokenA The address of underlying tokenA in LP token
     @param tokenB The address of underlying tokenB in LP token
     @param liquidity The amount of LP tokens to burn
     @param amountAMin The min amount of underlying tokenA that has to be received
     @param amountBMin The min amount of underlying tokenB that has to be received
     @param deadline The block number after which this transaction is invalid
     @return amountA Actual amount of underlying tokenA received
     @return amountB Actual amount of underlying tokenB received
    */
    function _removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) private ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = ImpossibleLibrary.pairFor(factory, tokenA, tokenB);
        IImpossiblePair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint256 amount0, uint256 amount1) = IImpossiblePair(pair).burn(address(this));
        (address token0, ) = ImpossibleLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'ImpossibleRouter: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'ImpossibleRouter: INSUFFICIENT_B_AMOUNT');
    }

    /**
     @notice Function for basic remove liquidity functionality
     @dev Openzeppelin reentrancy guards
     @param tokenA The address of underlying tokenA in LP token
     @param tokenB The address of underlying tokenB in LP token
     @param liquidity The amount of LP tokens to burn
     @param amountAMin The min amount of underlying tokenA that has to be received
     @param amountBMin The min amount of underlying tokenB that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @return amountA Actual amount of underlying tokenA received
     @return amountB Actual amount of underlying tokenB received
    */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) nonReentrant returns (uint256 amountA, uint256 amountB) {
        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, deadline);
        unwrapSafeTransfer(tokenA, to, amountA);
        unwrapSafeTransfer(tokenB, to, amountB);
    }

    /**
     @notice Function for remove liquidity functionality with 1 token being WETH/WBNB
     @dev Openzeppelin reentrancy guards
     @param token The address of the non-ETH underlying token to receive
     @param liquidity The amount of LP tokens to burn
     @param amountTokenMin The desired amount of non-ETH underlying token that has to be received
     @param amountETHMin The min amount of ETH that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @return amountToken Actual amount of non-ETH underlying token received
     @return amountETH Actual amount of WETH/WBNB received
    */
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) nonReentrant returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = _removeLiquidity(token, WETH, liquidity, amountTokenMin, amountETHMin, deadline);
        unwrapSafeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /**
    @notice Function for remove liquidity functionality using EIP712 permit
     @dev Openzeppelin reentrancy guards
     @param tokenA The address of underlying tokenA in LP token
     @param tokenB The address of underlying tokenB in LP token
     @param liquidity The amount of LP tokens to burn
     @param amountAMin The min amount of underlying tokenA that has to be received
     @param amountBMin The min amount of underlying tokenB that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @param approveMax How much tokens are approved for transfer (liquidity, or max)
     @param v,r,s Variables that construct a valid EVM signature
     @return amountA Actual amount of underlying tokenA received
     @return amountB Actual amount of underlying tokenB received
    */
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountA, uint256 amountB) {
        address pair = ImpossibleLibrary.pairFor(factory, tokenA, tokenB);
        uint256 value = approveMax ? uint256(-1) : liquidity;
        IImpossiblePair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        return removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    /**
     @notice Function for remove liquidity functionality using EIP712 permit with 1 token being WETH/WBNB
     @param token The address of the non-ETH underlying token to receive
     @param liquidity The amount of LP tokens to burn
     @param amountTokenMin The desired amount of non-ETH underlying token that has to be received
     @param amountETHMin The min amount of ETH that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @param approveMax How much tokens are approved for transfer (liquidity, or max)
     @param v,r,s Variables that construct a valid EVM signature
     @return amountToken Actual amount of non-ETH underlying token received
     @return amountETH Actual amount of WETH/WBNB received
    */
    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountToken, uint256 amountETH) {
        address pair = ImpossibleLibrary.pairFor(factory, token, WETH);
        uint256 value = approveMax ? uint256(-1) : liquidity;
        IImpossiblePair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    /**
     @notice Function for remove liquidity functionality with 1 token being WETH/WBNB
     @dev This is used when non-WETH/WBNB underlying token is fee-on-transfer: e.g. FEI algo stable v1
     @dev Openzeppelin reentrancy guards
     @param token The address of the non-ETH underlying token to receive
     @param liquidity The amount of LP tokens to burn
     @param amountTokenMin The desired amount of non-ETH underlying token that has to be received
     @param amountETHMin The min amount of ETH that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @return amountETH Actual amount of WETH/WBNB received
    */
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) nonReentrant returns (uint256 amountETH) {
        (, amountETH) = _removeLiquidity(token, WETH, liquidity, amountTokenMin, amountETHMin, deadline);
        unwrapSafeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /**
     @notice Function for remove liquidity functionality using EIP712 permit with 1 token being WETH/WBNB
     @dev This is used when non-WETH/WBNB underlying token is fee-on-transfer: e.g. FEI algo stable v1
     @param token The address of the non-ETH underlying token to receive
     @param liquidity The amount of LP tokens to burn
     @param amountTokenMin The desired amount of non-ETH underlying token that has to be received
     @param amountETHMin The min amount of ETH that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @param approveMax How much tokens are approved for transfer (liquidity, or max)
     @param v,r,s Variables that construct a valid EVM signature
     @return amountETH Actual amount of WETH/WBNB received
    */
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountETH) {
        address pair = ImpossibleLibrary.pairFor(factory, token, WETH);
        uint256 value = approveMax ? uint256(-1) : liquidity;
        IImpossiblePair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token,
            liquidity,
            amountTokenMin,
            amountETHMin,
            to,
            deadline
        );
    }

    /**
     @notice Quote returns amountB based on some amountA, in the ratio of reserveA:reserveB
     @param amountA The amount of token A
     @param reserveA The amount of reserveA
     @param reserveB The amount of reserveB
     @return amountB The amount of token B that matches amount A in the ratio of reserves
    */
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure virtual returns (uint256 amountB) {
        return ImpossibleLibrary.quote(amountA, reserveA, reserveB);
    }

    /**
     @notice Quotes maximum output given exact input amount of tokens and addresses of tokens in pair
     @dev The library function considers custom swap fees/invariants/asymmetric tuning of pairs
     @dev However, library function doesn't consider limits created by hardstops
     @param amountIn The input amount of token A
     @param tokenIn The address of input token
     @param tokenOut The address of output token
     @return uint256 The maximum output amount of token B for a valid swap
    */
    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external view returns (uint256) {
        return ImpossibleLibrary.getAmountOut(amountIn, tokenIn, tokenOut, factory);
    }

    /**
     @notice Quotes minimum input given exact output amount of tokens and addresses of tokens in pair
     @dev The library function considers custom swap fees/invariants/asymmetric tuning of pairs
     @dev However, library function doesn't consider limits created by hardstops
     @param amountOut The desired output amount of token A
     @param tokenIn The address of input token
     @param tokenOut The address of output token
     @return uint256 The minimum input amount of token A for a valid swap
    */
    function getAmountIn(
        uint256 amountOut,
        address tokenIn,
        address tokenOut
    ) external view returns (uint256) {
        return ImpossibleLibrary.getAmountIn(amountOut, tokenIn, tokenOut, factory);
    }

    /**
     @notice Quotes maximum output given exact input amount of tokens and addresses of tokens in trade sequence
     @dev The library function considers custom swap fees/invariants/asymmetric tuning of pairs
     @dev However, library function doesn't consider limits created by hardstops
     @param amountIn The input amount of token A
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @return amounts The maximum possible output amount of all tokens through sequential swaps
    */
    function getAmountsOut(uint256 amountIn, address[] memory path)
        external
        view
        virtual
        returns (uint256[] memory amounts)
    {
        return ImpossibleLibrary.getAmountsOut(factory, amountIn, path);
    }

    /**
     @notice Quotes minimum input given exact output amount of tokens and addresses of tokens in trade sequence
     @dev The library function considers custom swap fees/invariants/asymmetric tuning of pairs
     @dev However, library function doesn't consider limits created by hardstops
     @param amountOut The output amount of token A
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @return amounts The minimum output amount required of all tokens through sequential swaps
    */
    function getAmountsIn(uint256 amountOut, address[] memory path)
        external
        view
        virtual
        returns (uint256[] memory amounts)
    {
        return ImpossibleLibrary.getAmountsIn(factory, amountOut, path);
    }
}
