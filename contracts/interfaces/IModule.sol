// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IModule
/// @notice Uniform entry point for every MagnetaGateway module (LP, TokenOps,
///         TaxClaim, Swap). The gateway ABI-encodes caller context and forwards
///         any msg.value; the module decodes the `params` blob itself.
interface IModule {
    /// @notice Context forwarded by the gateway on every dispatch.
    /// @param caller         msg.sender at the gateway (EOA or contract)
    /// @param originChainId  Chain id where the op was initiated (== block.chainid
    ///                       for local calls; differs for LZ-forwarded messages)
    /// @param feeVault       Address that must receive the Magneta markup
    struct Context {
        address caller;
        uint256 originChainId;
        address feeVault;
    }

    /// @notice Run the module's operation.
    /// @dev Implementations MUST NOT trust `params` beyond what they can verify
    ///      against on-chain state. Gateway-level access control is the only
    ///      caller restriction (msg.sender == gateway).
    /// @param ctx     Forwarded caller context
    /// @param params  Module-specific ABI-encoded payload
    /// @return result ABI-encoded module output
    function execute(Context calldata ctx, bytes calldata params)
        external
        payable
        returns (bytes memory result);
}
