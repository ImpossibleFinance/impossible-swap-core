// SPDX-License-Identifier: GPL-3
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import './interfaces/IImpossibleSwapFactory.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';
import './libraries/ReentrancyGuard.sol';

import './interfaces/IImpossibleSwapRouter.sol';
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

contract ImpossibleSwapRouter is IImpossibleSwapRouter, ReentrancyGuard {
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
     @notice Helper function for basic swap
     @dev Requires the initial amount to have been sent to the first pair contract
     @param amounts[] An array of trade amounts. Trades are made from arr idx 0 to arr end idx sequentially
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
    */
    function _swap(uint256[] memory amounts, address[] memory path) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = ImpossibleLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? ImpossibleLibrary.pairFor(factory, output, path[i + 2]) : address(this);
            IImpossiblePair(ImpossibleLibrary.pairFor(factory, input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    /**
     @notice Swap function - receive maximum output given fixed input
     @dev Openzeppelin reentrancy guards
     @param amountIn The exact input amount
     @param amountOutMin The minimum output amount allowed for a successful swap
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @return amounts Array of actual output token amounts received per swap, sequentially.
    */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) nonReentrant returns (uint256[] memory amounts) {
        amounts = ImpossibleLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        wrapSafeTransfer(path[0], msg.sender, ImpossibleLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path);
        unwrapSafeTransfer(path[path.length - 1], to, amounts[amounts.length - 1]);
    }

    /**
     @notice Swap function - receive desired output amount given a maximum input amount
     @dev Openzeppelin reentrancy guards
     @param amountOut The exact output amount desired
     @param amountInMax The maximum input amount allowed for a successful swap
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @return amounts Array of actual output token amounts received per swap, sequentially.
    */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) nonReentrant returns (uint256[] memory amounts) {
        amounts = ImpossibleLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'ImpossibleRouter: EXCESSIVE_INPUT_AMOUNT');
        wrapSafeTransfer(path[0], msg.sender, ImpossibleLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path);
        unwrapSafeTransfer(path[path.length - 1], to, amountOut);
    }

    /**
     @notice Swap function - receive maximum output given fixed input of ETH
     @dev Openzeppelin reentrancy guards
     @param amountOutMin The minimum output amount allowed for a successful swap
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @return amounts Array of actual output token amounts received per swap, sequentially.
    */
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) nonReentrant returns (uint256[] memory amounts) {
        require(path[0] == WETH, 'ImpossibleRouter: INVALID_PATH');
        amounts = ImpossibleLibrary.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(ImpossibleLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path);
        unwrapSafeTransfer(path[path.length - 1], to, amounts[amounts.length - 1]);
    }

    /**
    @notice Swap function - receive desired ETH output amount given a maximum input amount
     @dev Openzeppelin reentrancy guards
     @param amountOut The exact output amount desired
     @param amountInMax The maximum input amount allowed for a successful swap
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @return amounts Array of actual output token amounts received per swap, sequentially.
    */
    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) nonReentrant returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, 'ImpossibleRouter: INVALID_PATH');
        amounts = ImpossibleLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'ImpossibleRouter: EXCESSIVE_INPUT_AMOUNT');
        wrapSafeTransfer(path[0], msg.sender, ImpossibleLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path);
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /**
     @notice Swap function - receive maximum ETH output given fixed input of tokens
     @dev Openzeppelin reentrancy guards
     @param amountIn The amount of input tokens
     @param amountOutMin The minimum ETH output amount required for successful swaps
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @return amounts Array of actual output token amounts received per swap, sequentially.
    */
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) nonReentrant returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, 'ImpossibleRouter: INVALID_PATH');
        amounts = ImpossibleLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        wrapSafeTransfer(path[0], msg.sender, ImpossibleLibrary.pairFor(factory, path[0], path[1]), amounts[0]);
        _swap(amounts, path);
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /**
     @notice Swap function - receive maximum tokens output given fixed ETH input
     @dev Openzeppelin reentrancy guards
     @param amountOut The minimum output amount in tokens required for successful swaps
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @return amounts Array of actual output token amounts received per swap, sequentially.
    */
    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) nonReentrant returns (uint256[] memory amounts) {
        require(path[0] == WETH, 'ImpossibleRouter: INVALID_PATH');
        amounts = ImpossibleLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'ImpossibleRouter: EXCESSIVE_INPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(ImpossibleLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path);
        unwrapSafeTransfer(path[path.length - 1], to, amountOut);
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    /**
     @notice Helper function for swap supporting fee on transfer tokens
     @dev Requires the initial amount to have been sent to the first pair contract
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
    */
    function _swapSupportingFeeOnTransferTokens(address[] memory path) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (uint256 amount0Out, uint256 amount1Out) =
                ImpossibleLibrary.getAmountOutFeeOnTransfer(input, output, factory);
            address to = i < path.length - 2 ? ImpossibleLibrary.pairFor(factory, output, path[i + 2]) : address(this);
            IImpossiblePair(ImpossibleLibrary.pairFor(factory, input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    /**
     @notice Swap function for fee on transfer tokens, no WETH/WBNB
     @param amountIn The amount of input tokens
     @param amountOutMin The minimum token output amount required for successful swaps
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
    */
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) nonReentrant {
        wrapSafeTransfer(path[0], msg.sender, ImpossibleLibrary.pairFor(factory, path[0], path[1]), amountIn);
        _swapSupportingFeeOnTransferTokens(path);
        uint256 balance = IERC20(path[path.length - 1]).balanceOf(address(this));
        require(balance >= amountOutMin, 'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        unwrapSafeTransfer(path[path.length - 1], to, balance);
    }

    /**
     @notice Swap function for fee on transfer tokens with WETH/WBNB
     @param amountOutMin The minimum underlying token output amount required for successful swaps
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
    */
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) nonReentrant {
        require(path[0] == WETH, 'ImpossibleRouter: INVALID_PATH');
        uint256 amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(ImpossibleLibrary.pairFor(factory, path[0], path[1]), amountIn));
        _swapSupportingFeeOnTransferTokens(path);
        uint256 balance = IERC20(path[path.length - 1]).balanceOf(address(this));
        require(balance >= amountOutMin, 'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        unwrapSafeTransfer(path[path.length - 1], to, balance);
    }

    /**
     @notice Swap function for fee on transfer tokens, no WETH/WBNB
     @param amountIn The amount of input tokens
     @param amountOutMin The minimum ETH output amount required for successful swaps
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
    */
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) nonReentrant {
        require(path[path.length - 1] == WETH, 'ImpossibleRouter: INVALID_PATH');
        wrapSafeTransfer(path[0], msg.sender, ImpossibleLibrary.pairFor(factory, path[0], path[1]), amountIn);
        _swapSupportingFeeOnTransferTokens(path);
        uint256 amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
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
