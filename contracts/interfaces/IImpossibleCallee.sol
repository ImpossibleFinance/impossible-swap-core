// SPDX-License-Identifier: GPL-3
pragma solidity =0.7.6;

interface IImpossibleCallee {
    function ImpossibleCall(address sender, uint amount0, uint amount1, bytes calldata data) external;
}
