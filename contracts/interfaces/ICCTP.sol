// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Circle CCTP TokenMessenger — burn USDC on source, mint on destination.
interface ITokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);
}

/// @notice Circle CCTP MessageTransmitter — relay attestation to mint on destination.
interface IMessageTransmitter {
    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool success);
}
