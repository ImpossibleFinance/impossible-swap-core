// SPDX-License-Identifier: GPL-3
pragma solidity =0.7.6;

import './IImpossiblePair.sol';
import './IImpossibleRouterInterface.sol';

interface IImpossibleRouterInterface {
    function factory() external returns (address factoryAddr);

    function swap(uint256[] memory amounts, address[] memory path) external;

    function swapSupportingFeeOnTransferTokens(address[] memory path) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin
    ) external returns (uint256 amountA, uint256 amountB);
}
