// SPDX-License-Identifier: GPL-3
pragma solidity ^0.8.0;

interface IImpossibleCallee {
    function ImpossibleCall(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}
