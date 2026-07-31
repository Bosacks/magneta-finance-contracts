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
    /// @param tokenSource    For cross-chain value ops: address holding bridged
    ///                       tokens (typically the gateway). Zero = pull from caller.
    /// @param guid           Unique identifier of the authenticated message that
    ///                       produced this dispatch (F-22/F-31 — audit-13
    ///                       re-scan-15 remediation). Populated as follows:
    ///                         - LZ-bridged command/value ops: the LayerZero
    ///                           GUID of the message (`_guid` in `_lzReceive`,
    ///                           or the same GUID carried through to
    ///                           `fulfillValueOp` for the keeper/fulfill path
    ///                           — it was already verified once at receipt
    ///                           time and is unique per LZ spec).
    ///                         - Keeper/relayer paths without a native LZ GUID:
    ///                           a synthetic identifier that is unique and
    ///                           authenticated for that flow (e.g. an already-
    ///                           verified EIP-712 intent hash).
    ///                         - Local direct calls (`executeOperation`):
    ///                           `bytes32(0)` — there is no cross-chain message
    ///                           to identify; modules fall back to the
    ///                           composite (originChainId, caller, op, inner)
    ///                           replay key for this case.
    struct Context {
        address caller;
        uint256 originChainId;
        address feeVault;
        address tokenSource;
        bytes32 guid;
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
