// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMagnetaGateway
/// @notice Per-chain facade that dispatches cross-chain operations to pluggable modules.
///         One gateway is deployed per chain. All sites (tokens/dex/scope) call this
///         through the chain-service SDK. Can be invoked directly (same-chain ops) or
///         via a LayerZero message (cross-chain ops from another gateway).
interface IMagnetaGateway {
    /// @notice Operation catalogue. Each OpType is handled by exactly one module.
    enum OpType {
        // LP
        CREATE_LP,
        REMOVE_LP,
        BURN_LP,
        CREATE_LP_AND_BUY,
        // Token ops
        MINT,
        UPDATE_METADATA,
        FREEZE_ACCOUNT,
        UNFREEZE_ACCOUNT,
        AUTO_FREEZE,
        REVOKE_PERMISSION,
        // Tax / fees
        CLAIM_TAX_FEES,
        // Swap
        SWAP_LOCAL,
        SWAP_OUT
    }

    /// @notice Emitted when a module processes an operation.
    /// @param op      Operation type dispatched
    /// @param module  Module address that handled it
    /// @param caller  msg.sender on-chain (wallet or local gateway proxy)
    /// @param originChainId  Source chain id (== block.chainid for local calls)
    /// @param resultHash     keccak256 of the module's ABI-encoded result
    event OperationExecuted(
        OpType indexed op,
        address indexed module,
        address indexed caller,
        uint256 originChainId,
        bytes32 resultHash
    );

    /// @notice Emitted when the module registry is updated.
    event ModuleSet(OpType indexed op, address indexed module);

    /// @notice Emitted when the Magneta fee vault is updated.
    event FeeVaultSet(address indexed previous, address indexed current);

    /// @notice Execute an operation on this chain.
    /// @dev Callable by any user. The fee is paid in msg.value (native) or pulled
    ///      in USDC by the relevant module, per that module's contract.
    /// @param op      Operation to run
    /// @param params  ABI-encoded payload defined by the target module
    /// @return result ABI-encoded module output (e.g. lp address, pool id, tx hash)
    function executeOperation(OpType op, bytes calldata params)
        external
        payable
        returns (bytes memory result);

    /// @notice Register or replace the module that handles a given OpType.
    /// @dev Owner-only. Setting module = address(0) disables the op on this chain.
    function setModule(OpType op, address module) external;

    /// @notice Set the address that collects the Magneta markup (USDC vault).
    function setFeeVault(address vault) external;

    /// @notice Lookup the module currently registered for an operation.
    function moduleFor(OpType op) external view returns (address);

    /// @notice Address of the USDC vault that accumulates Magneta fees on this chain.
    function feeVault() external view returns (address);
}
