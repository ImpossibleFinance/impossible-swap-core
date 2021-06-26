// SPDX-License-Identifier: GPL-3
pragma solidity =0.7.6;

import './interfaces/IImpossibleFactory.sol';
import './ImpossiblePair.sol';

contract ImpossibleFactory is IImpossibleFactory {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(ImpossiblePair).creationCode));

    address public override feeTo;
    address public override governance;
    address public router;
    bool whitelist;
    mapping(address => bool) approvedTokens;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    constructor(address _governance) {
        governance = _governance;
    }

    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }

    function setRouter(address _router) external {
        require(msg.sender == address(governance), "IF: FORBIDDEN");
        require(router == address(0x0), 'IF: ROUTER_SET');
        router = _router;
    }

    function changeTokenAccess(address token, bool allowed) external {
        require(msg.sender == address(governance), 'IF: FORBIDDEN');
        approvedTokens[token] = allowed;
    }

    function setWhitelist(bool b) external {
        require(msg.sender == address(governance), "IF: FORBIDDEN");
        whitelist = b;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        // tokens must not be identical (i.e. have same address)
        if (whitelist) {
            require(approvedTokens[tokenA] && approvedTokens[tokenB], 'IF: Unapproved tokens');
        }
        require(tokenA != tokenB, 'IF: IDENTICAL_ADDRESSES');
        // order token addresses from low to high
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // token0 and token1 should always be ordered from low to high, so only check token0
        require(token0 != address(0), 'IF: ZERO_ADDRESS');
        // both directions of mappings should always exist, so we only need to check one direction
        // (see code below for logic that adds mappings)
        require(getPair[token0][token1] == address(0), 'IF: PAIR_EXISTS');

        // deploy pair contract using create2 opcode
        // for more info: https://hackernoon.com/using-ethereums-create2-nw2137q7
        bytes memory bytecode = type(ImpossiblePair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // deploy pair
        IImpossiblePair(pair).initialize(token0, token1, router);
        // populate mappings in both forward and reverse directions
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        // add new pair to array of all pair addresses
        allPairs.push(pair);
        // emit event
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        // setter of feeTo must be `feeToSetter`
        require(msg.sender == governance, 'IF: FORBIDDEN');
        // set feeTo
        feeTo = _feeTo;
    }

    function setGovernance(address _governance) external override {
        // setter of feeToSetter must be current `feeToSetter`
        require(msg.sender == governance, 'IF: FORBIDDEN');
        // set feeToSetter
        governance = _governance;
    }
}
