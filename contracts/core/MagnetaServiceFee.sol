// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MagnetaServiceFee
/// @notice Minimal NATIVE fee collector for OFF-CHAIN Magneta operations
///         (wallet generation, vanity addresses, snapshots, balance checks…)
///         that have no on-chain op-tx to bake a fee into. The user calls
///         {payFee} with the native fee for a given `opId`; it forwards the fee
///         to the FeeVault and emits {ServiceFeePaid} with a monotonic nonce so
///         the server (MagnetaTerminal / the listener) can verify the payment
///         on-chain — single-use, correct amount, correct op — before unlocking
///         the off-chain work.
///
/// @dev    Native-only by product policy (users never convert to USDC). The fee
///         is PROTOCOL-SET per op (`opFee`, owner/Safe-controlled) — never a
///         caller argument — so it cannot be under-paid: {payFee} requires
///         `msg.value == opFee[opId]`. This is a soft (detect-not-prevent) gate:
///         the off-chain op runs on the server, so a determined user could skip
///         the call; the compensating control is MagnetaTerminal reconciliation
///         (op usage vs {ServiceFeePaid} events per op). Bounded by
///         {maxOpFee} to prevent a fat-finger / extractive fee.
contract MagnetaServiceFee is Ownable2Step {
    /// @notice Native sink for collected fees (the Magneta FeeVault).
    address public feeVault;

    /// @notice Protocol-set native fee per off-chain op id (wei). 0 = disabled.
    mapping(bytes32 => uint256) public opFee;

    /// @notice Upper bound on any single {opFee}. Owner-settable because native
    ///         amounts are chain-specific. Default 1 native unit.
    uint256 public maxOpFee = 1 ether;

    /// @notice Monotonic counter making every {ServiceFeePaid} event unique, so
    ///         the server can key single-use verification on (txHash, nonce).
    uint256 public paymentNonce;

    event ServiceFeePaid(address indexed payer, bytes32 indexed opId, uint256 amount, uint256 nonce);
    event OpFeeUpdated(bytes32 indexed opId, uint256 fee);
    event MaxOpFeeUpdated(uint256 maxFee);
    event FeeVaultUpdated(address indexed vault);

    error ZeroVault();
    error FeeNotSet(bytes32 opId);
    error WrongFeeAmount(uint256 sent, uint256 required);
    error FeeTooHigh();
    error TransferFailed();

    constructor(address _feeVault) {
        if (_feeVault == address(0)) revert ZeroVault();
        feeVault = _feeVault;
    }

    /// @notice Pay the protocol-set native fee for `opId`. `msg.value` must equal
    ///         `opFee[opId]` exactly (which must be non-zero / enabled). Forwards
    ///         to the FeeVault and emits a nonced event for off-chain verification.
    function payFee(bytes32 opId) external payable {
        uint256 required = opFee[opId];
        if (required == 0) revert FeeNotSet(opId);
        if (msg.value != required) revert WrongFeeAmount(msg.value, required);
        (bool ok, ) = payable(feeVault).call{value: msg.value}("");
        if (!ok) revert TransferFailed();
        emit ServiceFeePaid(msg.sender, opId, msg.value, paymentNonce++);
    }

    /// @notice Owner (Safe) sets the native fee for an off-chain op id.
    function setOpFee(bytes32 opId, uint256 fee) external onlyOwner {
        if (fee > maxOpFee) revert FeeTooHigh();
        opFee[opId] = fee;
        emit OpFeeUpdated(opId, fee);
    }

    /// @notice Owner (Safe) sets the upper bound for {setOpFee}.
    function setMaxOpFee(uint256 maxFee) external onlyOwner {
        maxOpFee = maxFee;
        emit MaxOpFeeUpdated(maxFee);
    }

    /// @notice Owner (Safe) rotates the FeeVault sink.
    function setFeeVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroVault();
        feeVault = vault;
        emit FeeVaultUpdated(vault);
    }
}
