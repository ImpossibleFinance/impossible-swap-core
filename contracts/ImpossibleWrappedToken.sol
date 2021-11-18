// SPDX-License-Identifier: GPL-3

pragma solidity =0.7.6;

import './interfaces/IImpossibleWrappedToken.sol';
import './interfaces/IERC20.sol';
import './libraries/SafeMath.sol';
import './libraries/ReentrancyGuard.sol';

contract ImpossibleWrappedToken is IImpossibleWrappedToken, ReentrancyGuard {
    using SafeMath for uint256;

    string public override name;
    string public override symbol;
    uint8 public override decimals = 18;
    uint256 public override totalSupply;

    IERC20 public underlying;
    uint256 public underlyingBalance;
    uint256 public ratioNum;
    uint256 public ratioDenom;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(
        address _underlying,
        uint256 _ratioNum,
        uint256 _ratioDenom
    ) {
        underlying = IERC20(_underlying);
        ratioNum = _ratioNum;
        ratioDenom = _ratioDenom;
        string memory desc = string(abi.encodePacked(underlying.symbol()));
        name = string(abi.encodePacked('IF-Wrapped ', desc));
        symbol = string(abi.encodePacked('WIF ', desc));
    }

    // amt = amount of wrapped tokens
    function deposit(address dst, uint256 amt) public override nonReentrant returns (uint256 wad) {
        bool success = underlying.transferFrom(msg.sender, address(this), amt);
        require(success, 'ImpossibleWrapper: TRANSFERFROM_FAILED');
        wad = amt.mul(ratioNum).div(ratioDenom);
        balanceOf[dst] = balanceOf[dst].add(wad);
        totalSupply = totalSupply.add(wad);
        underlyingBalance = underlyingBalance.add(amt);
        emit Transfer(address(0), dst, wad);
    }

    // wad = amount of wrapped tokens
    function withdraw(address dst, uint256 wad) public override nonReentrant returns (uint256 transferAmt) {
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(wad);
        totalSupply = totalSupply.sub(wad);
        underlyingBalance = underlyingBalance.sub(transferAmt);
        transferAmt = wad.mul(ratioDenom).div(ratioNum);
        bool success = underlying.transfer(dst, transferAmt);
        require(success, 'IF Wrapper: UNDERLYING_TRANSFER_FAIL');
        emit Transfer(msg.sender, address(0), wad);
        return transferAmt;
    }

    function _withdraw(address dst, uint256 wad) internal returns (uint256 transferAmt) {}

    function amtToUnderlyingAmt(uint256 amt) public view override returns (uint256) {
        return amt.mul(ratioDenom).div(ratioNum);
    }

    function approve(address guy, uint256 wad) public override returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public override returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(
        address src,
        address dst,
        uint256 wad
    ) public override returns (bool) {
        require(balanceOf[src] >= wad, '');

        if (src != msg.sender && allowance[src][msg.sender] != uint256(-1)) {
            require(allowance[src][msg.sender] >= wad, 'ImpossibleWrapper: INSUFF_ALLOWANCE');
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }
}
