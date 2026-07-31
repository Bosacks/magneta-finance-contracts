// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "../interfaces/IModule.sol";
import "../interfaces/IMagnetaGateway.sol";
import "../interfaces/IMagnetaOFTFactories.sol";

/// @notice Minimal interface for the local-chain TokenOpsModule. We only
///         need the permissionless registration entrypoint.
interface ITokenOpsModuleRegistry {
    function registerByTokenOwner(address token) external;
}

/// @title TokenCreationModule
/// @notice Handles `OpType.CREATE_TOKEN` for the MagnetaGateway. Used to
///         spawn a Magneta OFT token on every chain reached by a `sendFanOut`
///         from the user's source chain — the destination Gateway routes
///         the LZ message here, the module decodes the payload, and forwards
///         to the relevant local factory.
///
/// @dev    Two templates are supported: Standard (paid create on source chain,
///         flexible token admin) and AutoLiquidity (free, 2% transfer tax to
///         treasury). The module holds two factory addresses, picks the right
///         one based on the sub-op encoded in the params payload.
///
///         The Magneta create fee is collected ON THE SOURCE CHAIN by the
///         Gateway (USDC, via `_collectCrossChainFee`). On every destination
///         the factories' `createForCreator` path waives the local native
///         fee — only the local gas cost remains, paid by LZ executor via
///         pre-funded `nativeForDst` in lzOptions.
contract TokenCreationModule is IModule, ReentrancyGuard, Ownable2Step {
    /// @notice Sub-op selector encoded in the first byte of `params`.
    enum TemplateKind {
        Standard,         // → IMagnetaOFTStandardFactory
        AutoLiquidity     // → IMagnetaOFTAutoLiquidityFactory
    }

    address public immutable gateway;

    /// @notice Local-chain factory for the Standard OFT template. Set at
    ///         deploy time per the chain where this module is deployed.
    ///         May be address(0) on chains where Standard isn't supported
    ///         (e.g. Cronos has no LZ V2 → no OFT factory at all).
    address public standardFactory;

    /// @notice Local-chain factory for the AutoLiquidity OFT template.
    address public autoLiquidityFactory;

    /// @notice Local-chain TokenOpsModule. Late-bound by owner because both
    ///         modules are deployed independently and we want to break the
    ///         coupling at construction time. When set, every successful
    ///         token creation triggers `tokenOpsModule.registerByTokenOwner`
    ///         so MINT/FREEZE/UPDATE/REVOKE work immediately on the dest
    ///         chain without an extra user signature. Sprint 9.5 wiring.
    address public tokenOpsModule;

    event TokenSpawned(
        address indexed token,
        address indexed creator,
        TemplateKind indexed kind,
        uint256 originChainId,
        string name,
        string symbol
    );
    event StandardFactoryUpdated(address indexed previous, address indexed current);
    event AutoLiquidityFactoryUpdated(address indexed previous, address indexed current);
    event TokenOpsModuleUpdated(address indexed previous, address indexed current);

    /// @notice Emitted every time `_maybeRegisterToken` is attempted, whether
    ///         it succeeds or not (F-28 — audit-13 remediation). Previously
    ///         every registration failure was swallowed by a bare `catch {}`
    ///         with no on-chain signal, while `TokenSpawned` was emitted as
    ///         though the token were fully wired to TokenOpsModule. Off-chain
    ///         monitoring can now alert on `success == false` and inspect
    ///         `revertData` instead of discovering the gap only when a user
    ///         tries to MINT/FREEZE/UPDATE and finds the token unregistered.
    /// @param  token       The freshly-created token that registration was
    ///                     attempted for.
    /// @param  success     Whether `registerByTokenOwner` returned normally.
    /// @param  revertData  Raw revert data on failure (selector + payload for
    ///                     custom errors / Error(string) / Panic(uint));
    ///                     empty on success.
    event TokenOpsRegistration(
        address indexed token,
        bool    indexed success,
        bytes           revertData
    );

    error OnlyGateway();
    error UnsupportedTemplate();
    error UnsupportedOp();
    error FactoryNotSet();
    error InvalidPayload();
    /// @notice F-23 — mirrors LPAtomicModule.EthNotAccepted. IModule mandates
    ///         `payable` but this module never forwards, refunds, or
    ///         recovers msg.value, so any nonzero amount would be trapped.
    error EthNotAccepted();
    /// @notice F-24 — defense-in-depth replay guard, mirrors the corrected
    ///         LPAtomicModule key (F-20).
    error AlreadyExecuted();
    error DVNQuorumTooLow(uint8 attested);

    /// @notice Minimum attested DVN quorum the gateway must surface for this
    ///         module to wire up. Mitigates Kelp-DAO-class single-validator
    ///         risk (chantier #3 — Sentinelle 2026-06-12 SC01:2026). Checked
    ///         at construction AND, since F-13, on every execute() dispatch
    ///         — see execute() for why the constructor-only check was
    ///         insufficient.
    uint8 public constant MIN_DVN_QUORUM = 2;

    /// @notice Per-message payload hash → consumed (F-24 — defense-in-depth
    ///         replay guard). F-22/F-31 (audit-13 re-scan-15): mirrors
    ///         LPAtomicModule's corrected key — `ctx.guid` alone when
    ///         non-zero (the LayerZero GUID of the authenticated message,
    ///         unique by LZ spec), falling back to the composite key
    ///         (origin chain + caller + template kind + inner params) only
    ///         for the local, non-bridged `executeOperation` path where
    ///         `ctx.guid == 0`. See execute() for details.
    mapping(bytes32 => bool) public executedPayloads;

    constructor(
        address _gateway,
        address _standardFactory,
        address _autoLiquidityFactory
    ) {
        require(_gateway != address(0), "TokenCreationModule: gateway 0");
        require(
            IMagnetaGateway(_gateway).requiredDVNCount() >= MIN_DVN_QUORUM,
            "TokenCreationModule: DVN quorum"
        );
        // Factories CAN be zero at deploy time — owner sets them post-wiring
        // to break the circular dependency: factory needs the module address
        // (via setCrossChainCreator) and the module needs the factory address.
        gateway = _gateway;
        standardFactory = _standardFactory;
        autoLiquidityFactory = _autoLiquidityFactory;
    }

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    // ─── Admin: late-bind factories ─────────────────────────────────────────

    /// @dev SSP_127138_376 — owner setters validate that the new address is
    ///      either zero (intentional disable) or a deployed contract. This
    ///      prevents accidental misconfiguration to an EOA, which would
    ///      silently break CREATE_TOKEN with no clear error. The owner is
    ///      Magneta's 2/2 Safe multisig, so this is a guard against operator
    ///      mistake rather than malice — proxy/timelock validation lands V1.1.
    function setStandardFactory(address f) external onlyOwner {
        require(f == address(0) || f.code.length > 0, "TokenCreation: not a contract");
        emit StandardFactoryUpdated(standardFactory, f);
        standardFactory = f;
    }

    function setAutoLiquidityFactory(address f) external onlyOwner {
        require(f == address(0) || f.code.length > 0, "TokenCreation: not a contract");
        emit AutoLiquidityFactoryUpdated(autoLiquidityFactory, f);
        autoLiquidityFactory = f;
    }

    function setTokenOpsModule(address m) external onlyOwner {
        require(m == address(0) || m.code.length > 0, "TokenCreation: not a contract");
        emit TokenOpsModuleUpdated(tokenOpsModule, m);
        tokenOpsModule = m;
    }

    /// @dev Best-effort registration of the freshly-deployed token with the
    ///      local TokenOpsModule. Wraps the call in try/catch so a misconfigured
    ///      TokenOpsModule (or a chain that intentionally has no ops module)
    ///      doesn't block token creation.
    /// @dev SSP_127138_50 — Solidity's try/catch has limitations: it can fail
    ///      to catch errors when calling an EOA or a contract without the
    ///      target function. We pre-check `ops.code.length > 0` to ensure
    ///      the address is at least a contract before attempting the call,
    ///      so a misconfigured `tokenOpsModule` (e.g. owner sets it to an
    ///      EOA by mistake) doesn't silently break CREATE_TOKEN.
    function _maybeRegisterToken(address token) internal {
        address ops = tokenOpsModule;
        if (ops == address(0)) return;
        if (ops.code.length == 0) return;          // EOA or self-destructed contract — skip
        try ITokenOpsModuleRegistry(ops).registerByTokenOwner(token) {
            // success — token now has tokenAdmin == token.owner() in TokenOps
            emit TokenOpsRegistration(token, true, "");
        } catch (bytes memory reason) {
            // already-registered, owner is zero, etc — non-fatal, but now
            // observable off-chain (F-28) instead of silently swallowed.
            // `catch (bytes memory)` as the sole clause catches every revert
            // shape (custom error, Error(string), Panic(uint)).
            emit TokenOpsRegistration(token, false, reason);
        }
    }

    // ─── Dispatch ───────────────────────────────────────────────────────────

    /// @inheritdoc IModule
    /// @dev `params` layout: `bytes1 templateKind || abi.encode(...kind-specific...)`
    function execute(Context calldata ctx, bytes calldata params)
        external
        payable
        override
        onlyGateway
        nonReentrant
        returns (bytes memory result)
    {
        // F-13: re-check the DVN quorum floor on EVERY dispatch, mirroring
        // LPAtomicModule. The constructor-only check meant a live module had
        // no way to notice the gateway later being reconfigured below
        // MIN_DVN_QUORUM; it would keep accepting execute() calls under a
        // weakened trust model. Failing closed here takes effect immediately
        // — no redeploy required to enforce a downgrade.
        uint8 attestedDvn = IMagnetaGateway(gateway).requiredDVNCount();
        if (attestedDvn < MIN_DVN_QUORUM) revert DVNQuorumTooLow(attestedDvn);

        // F-23: reject ETH. IModule mandates `payable` but this module never
        // forwards, refunds, or recovers msg.value — accepting it would trap
        // the funds forever. Mirrors LPAtomicModule's EthNotAccepted guard.
        if (msg.value != 0) revert EthNotAccepted();

        if (params.length == 0) revert InvalidPayload();

        TemplateKind kind = TemplateKind(uint8(params[0]));
        bytes calldata inner = params[1:];

        // F-24 / F-22 / F-31: module-level replay guard, defense-in-depth
        // against a twice-delivered authenticated CREATE_TOKEN payload
        // creating duplicate tokens. Preferred key is `ctx.guid` (the LZ
        // GUID of the authenticated message, unique by LZ spec) so two
        // genuinely distinct messages from the same origin chain with
        // byte-identical params now BOTH execute instead of the second
        // colliding; a replayed/duplicated GUID still reverts. Local direct
        // calls carry no GUID (ctx.guid == 0) and fall back to the composite
        // key mirroring LPAtomicModule (F-20): origin chain + caller +
        // template kind + inner params.
        bytes32 payloadHash = ctx.guid != bytes32(0)
            ? ctx.guid
            : keccak256(abi.encode(ctx.originChainId, ctx.caller, kind, inner));
        if (executedPayloads[payloadHash]) revert AlreadyExecuted();
        executedPayloads[payloadHash] = true;

        if (kind == TemplateKind.Standard) {
            return _createStandard(ctx, inner);
        } else if (kind == TemplateKind.AutoLiquidity) {
            return _createAutoLiquidity(ctx, inner);
        }
        revert UnsupportedTemplate();
    }

    // ─── Standard OFT ───────────────────────────────────────────────────────

    struct StandardParams {
        string name;
        string symbol;
        string tokenURI;
        uint256 totalSupply;
        bool revokeUpdate;
        bool revokeFreeze;
        bool revokeMint;
    }

    function _createStandard(Context calldata ctx, bytes calldata raw)
        internal
        returns (bytes memory)
    {
        if (standardFactory == address(0)) revert FactoryNotSet();
        StandardParams memory p = abi.decode(raw, (StandardParams));

        address token = IMagnetaOFTStandardFactory(standardFactory).createForCreator(
            ctx.caller,
            p.name,
            p.symbol,
            p.tokenURI,
            p.totalSupply,
            p.revokeUpdate,
            p.revokeFreeze,
            p.revokeMint
        );

        _maybeRegisterToken(token);

        emit TokenSpawned(
            token, ctx.caller, TemplateKind.Standard,
            ctx.originChainId, p.name, p.symbol
        );
        return abi.encode(token);
    }

    // ─── AutoLiquidity OFT ──────────────────────────────────────────────────

    struct AutoLiquidityParams {
        string name;
        string symbol;
        string tokenURI;
        uint256 totalSupply;
        uint256 liquidityToBurn;
    }

    function _createAutoLiquidity(Context calldata ctx, bytes calldata raw)
        internal
        returns (bytes memory)
    {
        if (autoLiquidityFactory == address(0)) revert FactoryNotSet();
        AutoLiquidityParams memory p = abi.decode(raw, (AutoLiquidityParams));

        address token = IMagnetaOFTAutoLiquidityFactory(autoLiquidityFactory).createForCreator(
            ctx.caller,
            p.name,
            p.symbol,
            p.tokenURI,
            p.totalSupply,
            p.liquidityToBurn
        );

        _maybeRegisterToken(token);

        emit TokenSpawned(
            token, ctx.caller, TemplateKind.AutoLiquidity,
            ctx.originChainId, p.name, p.symbol
        );
        return abi.encode(token);
    }

    // ─── Helpers for off-chain encoding (via web3 ABI) ──────────────────────

    /// @notice Returns the params payload for a Standard CREATE_TOKEN op.
    ///         Frontends/SDKs use this to build the `bytes params` argument
    ///         passed to `Gateway.sendFanOut(CREATE_TOKEN, ...)`.
    function encodeStandardParams(StandardParams calldata p)
        external
        pure
        returns (bytes memory)
    {
        return bytes.concat(bytes1(uint8(TemplateKind.Standard)), abi.encode(p));
    }

    /// @notice Returns the params payload for an AutoLiquidity CREATE_TOKEN op.
    function encodeAutoLiquidityParams(AutoLiquidityParams calldata p)
        external
        pure
        returns (bytes memory)
    {
        return bytes.concat(bytes1(uint8(TemplateKind.AutoLiquidity)), abi.encode(p));
    }
}
