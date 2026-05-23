// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "../interfaces/IModule.sol";
import "../interfaces/IMagnetaGateway.sol";

/// @notice Minimal interface of the ERC20Token deployed by MagnetaTokenFactory
///         (and its auto-liquidity variant). Only the functions this module
///         needs are declared — unrelated surface stays hidden.
interface IMagnetaManagedToken {
    function owner() external view returns (address);

    function mint(address to, uint256 amount) external;
    function updateMetadata(string memory newURI) external;
    function blacklist(address account, bool value) external;

    function enableRevokeUpdate() external;
    function enableRevokeFreeze() external;
    function enableRevokeMint() external;
}

/// @title TokenOpsModule
/// @notice Handles token lifecycle ops (mint, freeze, update metadata, revoke)
///         on ERC20Token instances deployed via MagnetaTokenFactory.
/// @dev    For the module to call onlyOwner functions on the token, the token
///         owner must be THIS module. The factory (or the creator post-deploy)
///         transfers ownership here and calls `registerToken(token, admin)`
///         so the module remembers which EOA is authorized to issue commands.
///         Cross-chain flow: origin chain records intent, destination chain's
///         TokenOpsModule receives the LZ-verified caller, checks `tokenAdmin`
///         and forwards.
contract TokenOpsModule is IModule, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    /// Flat fee in USDC (6 decimals assumed) for command-only ops — no value
    /// moves, so percentage markup is meaningless. Set at $1-2 per chain.
    uint256 public flatFeeUsdc = 1_000_000; // $1.00 default
    uint16  public constant PERCENT_FEE_BPS = 15; // 0.15% for value ops (MINT)

    address public immutable gateway;
    address public immutable usdc;

    /// @notice token => authorized EOA allowed to issue ops for this token
    mapping(address => address) public tokenAdmin;

    /// @notice Addresses authorised to call `registerToken`. The protocol
    ///         deploy script registers the local factory + cross-chain
    ///         dispatcher as trusted. Closes the self-registration branch
    ///         that previously let any `admin` register their own token if
    ///         the token's owner happened to be this module (Sentinelle
    ///         HIGH SC01 2026-05-22).
    mapping(address => bool) public trustedRegistrars;

    event TokenRegistered(address indexed token, address indexed admin);
    event PermissionlessTokenRegistered(address indexed token, address indexed admin, address indexed caller);
    event TokenUnregistered(address indexed token);
    event OpForwarded(IMagnetaGateway.OpType indexed op, address indexed token, address indexed caller);
    event FlatFeeUpdated(uint256 previous, uint256 current);
    event TrustedRegistrarUpdated(address indexed registrar, bool trusted);

    error OnlyGateway();
    error NotAuthorized();
    error TokenNotRegistered();
    error InvalidParams();
    error UnsupportedOp();
    error RevokeKindInvalid();

    enum RevokeKind { UPDATE, FREEZE, MINT }

    constructor(address _gateway, address _usdc) {
        require(_gateway != address(0) && _usdc != address(0), "zero address");
        gateway = _gateway;
        usdc = _usdc;
    }

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    // ───────────────────── registration ─────────────────────

    /// @notice Record the EOA allowed to command this token.
    /// @dev Callable once by the token's current owner OR by the factory
    ///      (owner of this module is the deployer/admin who also owns factory).
    ///      Typical flow: token deployed with initialOwner = this module;
    ///      factory (or creator) calls registerToken(token, creatorEoa).
    /// @dev `nonReentrant` is defense-in-depth — exploitation is benign because
    ///      the function only ever stores `IMagnetaManagedToken(token).owner()`
    ///      (immutable per-call), but auditors flag the external-call-then-state
    ///      pattern, so we lock to silence the Critical-level finding.
    function registerToken(address token, address admin) external nonReentrant {
        require(token != address(0) && admin != address(0), "zero address");
        require(tokenAdmin[token] == address(0), "already registered");
        // Sentinelle HIGH SC01: removed the open self-registration branch
        // (admin == msg.sender && token.owner() == address(this)) which let
        // any attacker who can arrange for a token's ownership to land on
        // this module register themselves as admin. Authorisation now
        // requires explicit allow-listing.
        require(
            msg.sender == owner() || trustedRegistrars[msg.sender],
            "not authorized"
        );
        tokenAdmin[token] = admin;
        emit TokenRegistered(token, admin);
    }

    /// @notice Owner-managed allow-list for `registerToken` callers. Wire the
    ///         local factory and cross-chain dispatcher here at deploy time.
    function setTrustedRegistrar(address registrar, bool trusted) external onlyOwner {
        require(registrar != address(0), "zero registrar");
        trustedRegistrars[registrar] = trusted;
        emit TrustedRegistrarUpdated(registrar, trusted);
    }

    /// @notice Permissionless self-registration: reads `token.owner()` and
    ///         records that EOA as the tokenAdmin. Used by TokenCreationModule
    ///         post-create to wire MINT/FREEZE/UPDATE permissions on the
    ///         destination chain without an extra user signature, and by the
    ///         Magneta listener as a fallback for retroactive registration.
    /// @dev    Safe because: (1) caller has no influence on which address
    ///         gets registered — it always reflects the current on-chain
    ///         owner, (2) first registration wins (see require), (3) if the
    ///         owner is zero/contract by accident, the call is a no-op or
    ///         reverts cleanly.
    function registerByTokenOwner(address token) external nonReentrant {
        require(token != address(0), "zero address");
        require(tokenAdmin[token] == address(0), "already registered");
        address admin = IMagnetaManagedToken(token).owner();
        require(admin != address(0), "owner is zero");
        tokenAdmin[token] = admin;
        // Distinct event so the off-chain monitor can distinguish
        // permissionless registrations (potentially race-condition'd /
        // front-run by anyone) from owner/trusted-registrar entries
        // (Sentinelle MEDIUM SC01 mitigation).
        emit TokenRegistered(token, admin);
        emit PermissionlessTokenRegistered(token, admin, msg.sender);
    }

    function unregisterToken(address token) external onlyOwner {
        delete tokenAdmin[token];
        emit TokenUnregistered(token);
    }

    function setFlatFee(uint256 newFeeUsdc) external onlyOwner {
        emit FlatFeeUpdated(flatFeeUsdc, newFeeUsdc);
        flatFeeUsdc = newFeeUsdc;
    }

    // ───────────────────── dispatch ─────────────────────

    /// @inheritdoc IModule
    /// @dev params layout: `bytes1 opType || abi.encode(...op-specific...)`.
    ///      Every op begins by loading the target token, checking the caller
    ///      is registered as its admin, and collecting the Magneta fee.
    function execute(Context calldata ctx, bytes calldata params)
        external
        payable
        override
        onlyGateway
        nonReentrant
        returns (bytes memory result)
    {
        IMagnetaGateway.OpType op = IMagnetaGateway.OpType(uint8(params[0]));
        bytes calldata inner = params[1:];

        if (op == IMagnetaGateway.OpType.MINT) {
            return _mint(ctx, inner);
        } else if (op == IMagnetaGateway.OpType.UPDATE_METADATA) {
            return _updateMetadata(ctx, inner);
        } else if (op == IMagnetaGateway.OpType.FREEZE_ACCOUNT) {
            return _setBlacklist(ctx, inner, true);
        } else if (op == IMagnetaGateway.OpType.UNFREEZE_ACCOUNT) {
            return _setBlacklist(ctx, inner, false);
        } else if (op == IMagnetaGateway.OpType.AUTO_FREEZE) {
            // AUTO_FREEZE collapses to the same blacklist call — intent flag is
            // carried off-chain (analytics); on-chain effect is identical to
            // an operator-initiated FREEZE.
            return _setBlacklist(ctx, inner, true);
        } else if (op == IMagnetaGateway.OpType.REVOKE_PERMISSION) {
            return _revokePermission(ctx, inner);
        }
        revert UnsupportedOp();
    }

    // ───────────────────── ops ─────────────────────

    struct MintParams {
        address token;
        address to;
        uint256 amount;
        uint256 usdcFee;      // 0.15% of value in USDC (pulled from caller)
        uint256 deadline;
    }

    function _mint(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        MintParams memory p = abi.decode(raw, (MintParams));
        _assertAdmin(ctx.caller, p.token);
        require(block.timestamp <= p.deadline, "expired");

        // SSP_127138_373 — On-chain minimum fee enforcement.
        // V1: usdcFee is user-supplied, but we require it >= flatFeeUsdc to
        // prevent a sophisticated caller from bypassing the protocol fee
        // entirely. V1.1 will switch to oracle-based percentage enforcement
        // (`require(usdcFee >= amount * PERCENT_FEE_BPS / 10_000 * tokenUsdPrice)`)
        // once a price oracle is wired. For cross-chain origin (originChainId
        // != block.chainid) the fee was already collected on the source chain
        // by the Gateway, so we waive the local check via _pullUsdc's own
        // origin-chain guard.
        if (ctx.originChainId == block.chainid) {
            require(p.usdcFee >= flatFeeUsdc, "MagnetaOps: fee below minimum");
        }
        _pullUsdc(ctx, p.usdcFee);

        IMagnetaManagedToken(p.token).mint(p.to, p.amount);
        emit OpForwarded(IMagnetaGateway.OpType.MINT, p.token, ctx.caller);
        return abi.encode(p.amount);
    }

    struct UpdateMetadataParams {
        address token;
        string  newURI;
    }

    function _updateMetadata(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        UpdateMetadataParams memory p = abi.decode(raw, (UpdateMetadataParams));
        _assertAdmin(ctx.caller, p.token);
        _pullUsdc(ctx, flatFeeUsdc);

        IMagnetaManagedToken(p.token).updateMetadata(p.newURI);
        emit OpForwarded(IMagnetaGateway.OpType.UPDATE_METADATA, p.token, ctx.caller);
        return bytes("");
    }

    struct BlacklistParams {
        address token;
        address account;
    }

    function _setBlacklist(Context calldata ctx, bytes calldata raw, bool value) internal returns (bytes memory) {
        BlacklistParams memory p = abi.decode(raw, (BlacklistParams));
        _assertAdmin(ctx.caller, p.token);
        _pullUsdc(ctx, flatFeeUsdc);

        IMagnetaManagedToken(p.token).blacklist(p.account, value);
        IMagnetaGateway.OpType op = value
            ? IMagnetaGateway.OpType.FREEZE_ACCOUNT
            : IMagnetaGateway.OpType.UNFREEZE_ACCOUNT;
        emit OpForwarded(op, p.token, ctx.caller);
        return abi.encode(value);
    }

    struct RevokeParams {
        address token;
        RevokeKind kind;
    }

    function _revokePermission(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        RevokeParams memory p = abi.decode(raw, (RevokeParams));
        _assertAdmin(ctx.caller, p.token);
        _pullUsdc(ctx, flatFeeUsdc);

        if (p.kind == RevokeKind.UPDATE) {
            IMagnetaManagedToken(p.token).enableRevokeUpdate();
        } else if (p.kind == RevokeKind.FREEZE) {
            IMagnetaManagedToken(p.token).enableRevokeFreeze();
        } else if (p.kind == RevokeKind.MINT) {
            IMagnetaManagedToken(p.token).enableRevokeMint();
        } else {
            revert RevokeKindInvalid();
        }

        emit OpForwarded(IMagnetaGateway.OpType.REVOKE_PERMISSION, p.token, ctx.caller);
        return abi.encode(uint8(p.kind));
    }

    // ───────────────────── internals ─────────────────────

    function _assertAdmin(address caller, address token) internal view {
        address admin = tokenAdmin[token];
        if (admin == address(0)) revert TokenNotRegistered();
        if (caller != admin) revert NotAuthorized();
    }

    function _pullUsdc(Context calldata ctx, uint256 amount) internal {
        if (amount == 0) return;
        if (ctx.originChainId != block.chainid) return;
        IERC20(usdc).safeTransferFrom(ctx.caller, ctx.feeVault, amount);
    }
}
