// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMagnetaGateway
/// @notice Per-chain facade that dispatches cross-chain operations to pluggable modules.
///         One gateway is deployed per chain. All sites (tokens/dex/scope) call this
///         through the chain-service SDK. Can be invoked directly (same-chain ops) or
///         via a LayerZero message (cross-chain ops from another gateway).
interface IMagnetaGateway {
    /// @notice Operation catalogue. Each OpType is handled by exactly one module.
    /// @dev    APPEND ONLY — the numeric value of each entry is part of the
    ///         cross-chain payload encoding and must not shift. New ops go at
    ///         the end of the enum.
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
        SWAP_OUT,
        // Token creation (multi-chain via Gateway.sendFanOut). Sub-op
        // (Standard | AutoLiquidity) selected by the first byte of the
        // params payload — see TokenCreationModule.TemplateKind.
        CREATE_TOKEN,
        // Atomic LP ops (V1.1). One module — LPAtomicModule — handles both,
        // delegating to MagnetaLpAtomicHelper on the destination chain.
        // POOL_FEE_COMPOUND: same-router remove + re-add at current ratio.
        // MIGRATE_LP:        cross-router remove (src) + add (dst), single chain.
        POOL_FEE_COMPOUND,
        MIGRATE_LP
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

    /// @notice Emitted when the attested DVN quorum is updated by the owner.
    /// @dev    The attested value is the *floor* the protocol Safe certifies
    ///         the gateway's actual LZ DVN configuration to be at; modules
    ///         require it to be ≥ 2 in their constructors (Kelp-DAO-class
    ///         single-validator-risk mitigation).
    event RequiredDVNCountSet(uint8 indexed previous, uint8 indexed current);

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

    /// @notice Attested floor for the LZ DVN quorum of this gateway's receive
    ///         library. Set by the protocol Safe after verifying the actual
    ///         LayerZero ULN configuration off-chain. Modules consuming this
    ///         gateway MUST require this to be ≥ 2 in their constructors —
    ///         the value is the on-chain anchor for the Kelp-DAO-class
    ///         single-validator-risk mitigation.
    function requiredDVNCount() external view returns (uint8);

    /// @notice Set the attested DVN quorum floor. Owner-only.
    /// @dev    Re-setting this DOES NOT touch the actual LayerZero config —
    ///         it only updates the on-chain attestation that downstream
    ///         modules check. Operators must re-verify the LZ ULN config
    ///         off-chain and update this whenever the real config changes.
    ///         A planned downgrade also requires re-deploying any module
    ///         whose constructor would now fail the ≥ 2 check.
    function setRequiredDVNCount(uint8 newCount) external;

    // ───────────────────── cross-chain ─────────────────────

    /// @notice Send a cross-chain op to a sibling gateway via LayerZero.
    function sendCrossChainOp(
        uint32 dstEid,
        OpType op,
        bytes calldata moduleParams,
        bytes calldata lzOptions
    ) external payable returns (bytes32 guid);

    /// @notice Fan-out: broadcast an op to multiple chains in one tx.
    function sendFanOut(
        uint32[] calldata dstEids,
        OpType op,
        bytes[] calldata moduleParamsPerChain,
        bytes calldata lzOptions
    ) external payable returns (bytes32[] memory guids);

    /// @notice Estimate LayerZero fee for a single cross-chain op.
    function quoteCrossChainFee(
        uint32 dstEid,
        OpType op,
        bytes calldata moduleParams,
        bytes calldata lzOptions,
        bool payInLzToken
    ) external view returns (uint256 nativeFee, uint256 lzTokenFee);

    /// @notice Estimate total LayerZero fees for a fan-out.
    function quoteFanOutFee(
        uint32[] calldata dstEids,
        OpType op,
        bytes[] calldata moduleParamsPerChain,
        bytes calldata lzOptions,
        bool payInLzToken
    ) external view returns (uint256 totalNativeFee, uint256 totalLzTokenFee);

    // ───────────────────── cross-chain value ops ─────────────────────

    /// @notice Send a cross-chain value op: bridge USDC via CCTP + dispatch on destination.
    function sendCrossChainValueOp(
        uint32 dstEid,
        OpType op,
        bytes calldata moduleParams,
        uint256 usdcAmount,
        bytes calldata lzOptions
    ) external payable returns (bytes32 guid);

    /// @notice Fan-out value op: bridge USDC via CCTP + send LZ messages to N chains.
    function sendFanOutValueOp(
        uint32[] calldata dstEids,
        OpType op,
        bytes[] calldata moduleParamsPerChain,
        uint256[] calldata usdcAmountsPerChain,
        bytes calldata lzOptions
    ) external payable returns (bytes32[] memory guids);

    /// @notice Fulfill a pending value op after CCTP tokens arrive on this chain.
    function fulfillValueOp(bytes32 guid) external;
}
