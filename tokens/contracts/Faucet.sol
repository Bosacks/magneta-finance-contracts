// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// ⚠️ TESTNET ONLY ⚠️
///
/// Faucet is for low-value testnet drip use only. Sentinelle Multi-AI
/// 2026-05-22 (CAUTION 62/100) flagged the contract's design-level
/// risks as acceptable in a testnet context but unsuitable for
/// production:
///   - HIGH SC01: single-EOA owner can drain via withdrawAll or
///     manipulate dripAmount / cooldownTime parameters without
///     timelock.
///   - HIGH SC03: Sybil drain via permissionless dripTo to unlimited
///     fresh recipients; also enables cooldown griefing against
///     legitimate users.
///   - MEDIUM SC04: unbounded parameter setting (dripAmount=0 wastes
///     cooldowns, cooldownTime=0 removes rate limiting).
/// Do NOT deploy on a chain where the dispensed asset has economic
/// value. For mainnet faucet equivalents add multisig, Sybil
/// resistance (proof-of-personhood), and parameter bounds.

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Faucet
 * @dev A simple faucet contract that dispenses native currency (ETH/MATIC/etc)
 *      to users who request it. Includes cooldown logic off-chain or on-chain?
 *      Let's keep it simple: Drip amount is configurable.
 */
contract Faucet is Ownable2Step, ReentrancyGuard {
    uint256 public dripAmount = 0.05 ether;
    uint256 public cooldownTime = 1 days;

    mapping(address => uint256) public lastDripTime;

    event Drip(address indexed to, uint256 amount);
    event Deposit(address indexed from, uint256 amount);
    event DripAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event CooldownTimeUpdated(uint256 oldCooldown, uint256 newCooldown);
    event Withdrawn(address indexed to, uint256 amount);

    constructor(uint256 _dripAmount) Ownable(msg.sender) {
        dripAmount = _dripAmount;
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    function drip() external nonReentrant {
        _drip(payable(msg.sender));
    }

    function dripTo(address payable recipient) external nonReentrant {
        _drip(recipient);
    }

    function _drip(address payable recipient) internal {
        require(recipient != address(0), "Faucet: Zero address");
        require(address(this).balance >= dripAmount, "Faucet: Empty");
        require(block.timestamp >= lastDripTime[recipient] + cooldownTime, "Faucet: Cooldown active");

        lastDripTime[recipient] = block.timestamp;

        uint256 amount = dripAmount;
        (bool sent, ) = recipient.call{value: amount}("");
        require(sent, "Faucet: Failed to send Ether");

        emit Drip(recipient, amount);
    }

    function setDripAmount(uint256 _amount) external onlyOwner {
        emit DripAmountUpdated(dripAmount, _amount);
        dripAmount = _amount;
    }

    function setCooldownTime(uint256 _seconds) external onlyOwner {
        emit CooldownTimeUpdated(cooldownTime, _seconds);
        cooldownTime = _seconds;
    }

    function withdrawAll() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "Nothing to withdraw");
        emit Withdrawn(msg.sender, balance);
        (bool sent, ) = msg.sender.call{value: balance}("");
        require(sent, "Failed to withdraw");
    }
}
