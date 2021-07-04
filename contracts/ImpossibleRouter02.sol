// SPDX-License-Identifier: GPL-3
pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import './interfaces/IImpossibleFactory.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';
import './libraries/ReentrancyGuard.sol';

import './interfaces/IImpossibleRouter02.sol';
import './libraries/ImpossibleLibrary.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

/*
    @title  Router02 for Impossible Swap V3
    @author Impossible Finance
    @notice This router builds upon basic Uni V2 Router02 by allowing custom
            calculations based on settings in pairs (uni/xybk/custom fees)
    @dev    See documentation at: https://docs.impossible.finance/impossible-swap/overview
    @dev    Very little logical changes made in Router02. Most changes to accomodate xybk are in Library
*/

contract ImpossibleRouter02 is IImpossibleRouter02, ReentrancyGuard {
    using SafeMath for uint256;

    address public immutable override factory;
    address public immutable override WETH;

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, 'ImpossibleRouter: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) {
        factory = _factory;
        WETH = _WETH;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    /*
     @notice Helper function for adding liquidity
     @dev Logic is unchanged from uniswap-V2-Router02
     @param tokenA The address of underlying tokenA to add
     @param tokenB The address of underlying tokenB to add
     @param amountADesired The desired amount of tokenA to add
     @param amountBDesired The desired amount of tokenB to add
     @param amountAMin The min amount of tokenA to add (amountAMin:amountBDesired sets bounds on ratio)
     @param amountBMin The min amount of tokenB to add (amountADesired:amountBMin sets bounds on ratio)
     @returns amountA Actual amount of tokenA added as liquidity to pair
     @returns amountB Actual amount of tokenB added as liquidity to pair
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
        if (IImpossibleFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            IImpossibleFactory(factory).createPair(tokenA, tokenB);
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

    /*
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
     @returns amountA Amount of tokenA added as liquidity to pair
     @returns amountB Actual amount of tokenB added as liquidity to pair
     @returns liquidity Actual amount of LP tokens minted
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
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IImpossiblePair(pair).mint(to);
    }

    /*
     @notice Function for add liquidity functionality with 1 token being WETH/WBNB
     @dev Openzeppelin reentrancy guards
     @param token The address of the non-ETH underlying token to add
     @param amountTokenDesired The desired amount of non-ETH underlying token to add
     @param amountTokenMin The min amount of non-ETH underlying token to add (amountTokenMin:ETH sent sets bounds on ratio)
     @param amountETHMin The min amount of WETH/WBNB to add (amountTokenDesired:amountETHMin sets bounds on ratio)
     @param to The address to mint LP tokens to
     @param deadline The block number after which this transaction is invalid
     @returns amountToken Amount of non-ETH underlying token added as liquidity to pair
     @returns amountETH Actual amount of WETH/WBNB added as liquidity to pair
     @returns liquidity Actual amount of LP tokens minted
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
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWETH(WETH).deposit{value: amountETH}();
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IImpossiblePair(pair).mint(to);
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH); // refund dust eth, if any
    }

    /*
     @notice Helper function for removing liquidity
     @dev Logic is unchanged from uniswap-V2-Router02
     @param tokenA The address of underlying tokenA in LP token
     @param tokenB The address of underlying tokenB in LP token
     @param liquidity The amount of LP tokens to burn
     @param amountAMin The min amount of underlying tokenA that has to be received
     @param amountBMin The min amount of underlying tokenB that has to be received
     @returns amountA Actual amount of underlying tokenA received
     @returns amountB Actual amount of underlying tokenB received
    */
    function _removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) private ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = ImpossibleLibrary.pairFor(factory, tokenA, tokenB);
        IImpossiblePair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint256 amount0, uint256 amount1) = IImpossiblePair(pair).burn(to);
        (address token0, ) = ImpossibleLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'ImpossibleRouter: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'ImpossibleRouter: INSUFFICIENT_B_AMOUNT');
    }

    /*
     @notice Function for basic remove liquidity functionality
     @dev Openzeppelin reentrancy guards
     @param tokenA The address of underlying tokenA in LP token
     @param tokenB The address of underlying tokenB in LP token
     @param liquidity The amount of LP tokens to burn
     @param amountAMin The min amount of underlying tokenA that has to be received
     @param amountBMin The min amount of underlying tokenB that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @returns amountA Actual amount of underlying tokenA received
     @returns amountB Actual amount of underlying tokenB received
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
        return _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    /*
     @notice Function for remove liquidity functionality with 1 token being WETH/WBNB
     @dev Openzeppelin reentrancy guards
     @param token The address of the non-ETH underlying token to receive
     @param liquidity The amount of LP tokens to burn
     @param amountTokenMin The desired amount of non-ETH underlying token that has to be received
     @param amountETHMin The min amount of ETH that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @returns amountToken Actual amount of non-ETH underlying token received
     @returns amountETH Actual amount of WETH/WBNB received
    */
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) nonReentrant returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) = _removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /*
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
     @returns amountA Actual amount of underlying tokenA received
     @returns amountB Actual amount of underlying tokenB received
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
    ) external virtual override nonReentrant returns (uint256 amountA, uint256 amountB) {
        address pair = ImpossibleLibrary.pairFor(factory, tokenA, tokenB);
        uint256 value = approveMax ? uint256(-1) : liquidity;
        IImpossiblePair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = _removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    /*
     @notice Function for remove liquidity functionality using EIP712 permit with 1 token being WETH/WBNB
     @param token The address of the non-ETH underlying token to receive
     @param liquidity The amount of LP tokens to burn
     @param amountTokenMin The desired amount of non-ETH underlying token that has to be received
     @param amountETHMin The min amount of ETH that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @param approveMax How much tokens are approved for transfer (liquidity, or max)
     @param v,r,s Variables that construct a valid EVM signature
     @returns amountToken Actual amount of non-ETH underlying token received
     @returns amountETH Actual amount of WETH/WBNB received
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

    /*
     @notice Function for remove liquidity functionality with 1 token being WETH/WBNB
     @dev This is used when non-WETH/WBNB underlying token is fee-on-transfer: e.g. FEI algo stable v1
     @dev Openzeppelin reentrancy guards
     @param token The address of the non-ETH underlying token to receive
     @param liquidity The amount of LP tokens to burn
     @param amountTokenMin The desired amount of non-ETH underlying token that has to be received
     @param amountETHMin The min amount of ETH that has to be received
     @param to The address to send underlying tokens to
     @param deadline The block number after which this transaction is invalid
     @returns amountETH Actual amount of WETH/WBNB received
    */
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) nonReentrant returns (uint256 amountETH) {
        (, amountETH) = _removeLiquidity(token, WETH, liquidity, amountTokenMin, amountETHMin, address(this), deadline);
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /*
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
     @returns amountETH Actual amount of WETH/WBNB received
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

    /*
     @notice Helper function for basic swap
     @dev Requires the initial amount to have been sent to the first pair contract
     @param amounts[] An array of trade amounts. Trades are made from arr idx 0 to arr end idx sequentially
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param _to The address that receives the final tokens
    */
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0, ) = ImpossibleLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? ImpossibleLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IImpossiblePair(ImpossibleLibrary.pairFor(factory, input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    /*
     @notice Swap function - receive maximum output given fixed input
     @dev Openzeppelin reentrancy guards
     @param amountIn The exact input amount
     @param amountOutMin The minimum output amount allowed for a successful swap
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @param amounts[] Array of actual output token amounts received per swap, sequentially.
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
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            ImpossibleLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    /*
     @notice Swap function - receive desired output amount given a maximum input amount
     @dev Openzeppelin reentrancy guards
     @param amountOut The exact output amount desired
     @param amountInMax The maximum input amount allowed for a successful swap
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @param amounts[] Array of actual output token amounts received per swap, sequentially.
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
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            ImpossibleLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, to);
    }

    /*
     @notice Swap function - receive maximum output given fixed input of ETH
     @dev Openzeppelin reentrancy guards
     @param amountOutMin The minimum output amount allowed for a successful swap
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @param amounts[] Array of actual output token amounts received per swap, sequentially.
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
        _swap(amounts, path, to);
    }

    /*
    @notice Swap function - receive desired ETH output amount given a maximum input amount
     @dev Openzeppelin reentrancy guards
     @param amountOut The exact output amount desired
     @param amountInMax The maximum input amount allowed for a successful swap
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @param amounts[] Array of actual output token amounts received per swap, sequentially.
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
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            ImpossibleLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /*
     @notice Swap function - receive maximum ETH output given fixed input of tokens
     @dev Openzeppelin reentrancy guards
     @param amountIn The amount of input tokens
     @param amountOutMin The minimum ETH output amount required for successful swaps
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @param amounts[] Array of actual output token amounts received per swap, sequentially.
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
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            ImpossibleLibrary.pairFor(factory, path[0], path[1]),
            amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /*
     @notice Swap function - receive maximum tokens output given fixed ETH input
     @dev Openzeppelin reentrancy guards
     @param amountOut The minimum output amount in tokens required for successful swaps
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param to The address that receives the output tokens
     @param deadline The block number after which this transaction is invalid
     @param amounts[] Array of actual output token amounts received per swap, sequentially.
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
        _swap(amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    /*
     @notice Helper function for swap supporting fee on transfer tokens
     @dev Requires the initial amount to have been sent to the first pair contract
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @param _to The address that receives the output tokens
    */
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint256 i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (uint256 amount0Out, uint256 amount1Out) =
                ImpossibleLibrary.getAmountOutFeeOnTransfer(input, output, factory);
            address to = i < path.length - 2 ? ImpossibleLibrary.pairFor(factory, output, path[i + 2]) : _to;
            IImpossiblePair(ImpossibleLibrary.pairFor(factory, input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) nonReentrant {
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            ImpossibleLibrary.pairFor(factory, path[0], path[1]),
            amountIn
        );
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

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
        uint256 balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) nonReentrant {
        require(path[path.length - 1] == WETH, 'ImpossibleRouter: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            ImpossibleLibrary.pairFor(factory, path[0], path[1]),
            amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint256 amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'ImpossibleRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    /*
     @notice Quote returns amountB based on some amountA, in the ratio of reserveA:reserveB
     @param amountA The amount of token A
     @param reserveA The amount of reserveA
     @param reserveB The amount of reserveB
     @returns amountB The amount of token B that matches amount A in the ratio of reserves
    */
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure virtual override returns (uint256 amountB) {
        return ImpossibleLibrary.quote(amountA, reserveA, reserveB);
    }

    /*
     @notice Quotes maximum output given exact input amount of tokens and addresses of tokens in pair
     @dev The library function considers custom swap fees/invariants/asymmetric tuning of pairs
     @dev However, library function doesn't consider limits created by hardstops
     @param amountIn The input amount of token A
     @param tokenIn The address of input token
     @param tokenOut The address of output token
     @returns uint256 The maximum output amount of token B for a valid swap
    */
    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external view override returns (uint256) {
        return ImpossibleLibrary.getAmountOut(amountIn, tokenIn, tokenOut, factory);
    }

    /*
     @notice Quotes minimum input given exact output amount of tokens and addresses of tokens in pair
     @dev The library function considers custom swap fees/invariants/asymmetric tuning of pairs
     @dev However, library function doesn't consider limits created by hardstops
     @param amountOut The desired output amount of token A
     @param tokenIn The address of input token
     @param tokenOut The address of output token
     @returns uint256 The minimum input amount of token A for a valid swap
    */
    function getAmountIn(
        uint256 amountOut,
        address tokenIn,
        address tokenOut
    ) external view override returns (uint256) {
        return ImpossibleLibrary.getAmountIn(amountOut, tokenIn, tokenOut, factory);
    }

    /*
     @notice Quotes maximum output given exact input amount of tokens and addresses of tokens in trade sequence
     @dev The library function considers custom swap fees/invariants/asymmetric tuning of pairs
     @dev However, library function doesn't consider limits created by hardstops
     @param amountIn The input amount of token A
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @returns amounts[] The maximum possible output amount of all tokens through sequential swaps
    */
    function getAmountsOut(uint256 amountIn, address[] memory path)
        external
        view
        virtual
        override
        returns (uint256[] memory amounts)
    {
        return ImpossibleLibrary.getAmountsOut(factory, amountIn, path);
    }

    /*
     @notice Quotes minimum input given exact output amount of tokens and addresses of tokens in trade sequence
     @dev The library function considers custom swap fees/invariants/asymmetric tuning of pairs
     @dev However, library function doesn't consider limits created by hardstops
     @param amountOut The output amount of token A
     @param path[] An array of token addresses. Trades are made from arr idx 0 to arr end idx sequentially
     @returns amounts[] The minimum output amount required of all tokens through sequential swaps
    */
    function getAmountsIn(uint256 amountOut, address[] memory path)
        external
        view
        virtual
        override
        returns (uint256[] memory amounts)
    {
        return ImpossibleLibrary.getAmountsIn(factory, amountOut, path);
    }
}
