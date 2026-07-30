// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IModule.sol";
import "../interfaces/IMagnetaGateway.sol";

/// Subset of MagnetaRouterRegistry the module reads at runtime to enforce
/// the router allowlist (chantier #2 — Sentinelle 2026-06-12 SC04 HIGH).
interface IMagnetaRouterRegistry {
    function isRouterAllowed(address router) external view returns (bool);
}

/// Minimal UniV2 pair view used to read the pair's constituent tokens so the
/// module can verify canonicity against the router's factory (F-19 — Sentinelle
/// rescan-15). `pair.factory()` alone is spoofable: any arbitrary contract can
/// implement a `factory()` getter that returns the allowlisted factory address
/// without ever having actually been created by it. Reading token0()/token1()
/// and asking the factory itself for the canonical pair closes that gap.
interface IUniV2PairView {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// Minimal UniV2 router view used to fetch the factory.
interface IUniV2RouterFactoryView {
    function factory() external view returns (address);
}

/// Minimal UniV2 factory view used to verify a pair was actually created by
/// the router's factory (F-19 fix).
interface IUniV2FactoryPairView {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// Subset of MagnetaLpAtomicHelper that this module needs. The full helper
/// lives in the Tokens repo (contracts/solidity/contracts/MagnetaLpAtomicHelper.sol)
/// and is deployed once per chain. This module is the gateway-side facade.
interface IMagnetaLpAtomicHelper {
    function compoundPositionFor(
        address pair,
        address router,
        uint256 lpAmount,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        address recipient
    ) external;

    function migratePositionFor(
        address srcPair,
        address srcRouter,
        address dstRouter,
        uint256 lpAmount,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        address recipient
    ) external;
}

/**
 * @title LPAtomicModule
 * @notice Gateway-side module that exposes two V1.1 atomic LP ops via the
 *         MagnetaGateway dispatch path:
 *
 *           POOL_FEE_COMPOUND  →  delegate to helper.compoundPositionFor
 *           MIGRATE_LP         →  delegate to helper.migratePositionFor
 *
 *         When invoked locally the user gets a single tx instead of the V1
 *         4-tx wizard. When invoked from a sibling chain via LayerZero, the
 *         user signs a single tx on the source chain and the LP work happens
 *         atomically on the destination chain (where the LP actually lives).
 *
 * Trust model:
 *   - Only the Gateway can call execute() (onlyGateway).
 *   - The Gateway proves the user is `ctx.caller`; we forward LP back to that
 *     address via helper.{compound,migrate}PositionFor.
 *   - The helper holds NO standing approvals or balances; this module never
 *     holds funds either.
 *   - LP approval flow: users MUST approve THIS MODULE (LPAtomicModule) for
 *     their LP tokens. The module then approves the helper internally and
 *     revokes the approval at the end of each operation. Frontend should
 *     only ever surface the module address as the approval spender — never
 *     the helper directly. (SC09 fix: prior comment block was self-contra-
 *     dictory on this point.)
 *
 * Cross-chain authentication (SC01 architectural acknowledgement):
 *   This module trusts the gateway as the sole authentication boundary for
 *   any cross-chain dispatch — that's the standard MagnetaGateway module
 *   pattern (CREATE_LP, MINT, FREEZE_ACCOUNT, etc. all use it). The actual
 *   message-authentication strength lives ONE LAYER UP: the gateway's
 *   configured LayerZero DVN set. Protocol policy is to enforce a 2-of-N
 *   DVN quorum at the gateway level (Sprint B 2-DVN work in
 *   magneta-finance-tokens). This module deliberately does NOT add a
 *   module-level signature check on top — that would split the trust
 *   anchor and complicate key rotation. Operators MUST verify the gateway
 *   they wire here uses a ≥ 2-DVN config before flipping users on.
 *
 *   The gateway address is intentionally IMMUTABLE: changing it would be
 *   equivalent to redeploying the module, and a mutable gateway pointer
 *   would itself become an upgrade key that needs governance. The protocol
 *   Safe + timelock policies on the GATEWAY admin are the right place for
 *   that control; documented in infra_safe_multisig.md.
 *
 * Defense-in-depth (Sentinelle 2026-06-12 deep-scan response — addresses
 * 8 of 11 raised findings; 3 are architectural and addressed separately):
 *
 *   - nonReentrant on execute().
 *   - SafeERC20 for the LP pull / helper approval.
 *   - ETH rejected at the entry point (`if (msg.value != 0) revert`). The
 *     IModule interface mandates `payable` so we can't drop it, but we
 *     refuse any nonzero msg.value to prevent the SC10 "permanent ETH lock"
 *     scenario.
 *   - Empty `params` rejected before reading `params[0]` (SC10 OOB panic).
 *   - Module-level replay protection via per-execution payload hash mapping
 *     (SC02). A repeated identical call from a compromised gateway path
 *     reverts on the second attempt. F-22/F-31 (audit-13 re-scan-15):
 *     IModule.Context now carries `guid`, the LayerZero GUID of the
 *     authenticated message (bytes32(0) for local direct calls). When
 *     `ctx.guid != 0` the replay key is `ctx.guid` alone — every
 *     authenticated message is unique by LZ spec, so two genuinely distinct
 *     bridged messages with byte-identical op+params (same origin chain,
 *     same caller) now BOTH execute instead of the second reverting
 *     AlreadyExecuted; a replayed/duplicated GUID still reverts. This
 *     closes the residual limitation previously documented here (two
 *     distinct same-origin-chain messages with identical params used to
 *     collide because only originChainId, not a per-message identifier,
 *     was available to key on).
 *     When `ctx.guid == 0` (the local, non-bridged `executeOperation` path
 *     — there is no cross-chain message to key on) the module falls back
 *     to the pre-existing composite key: originChainId, caller, op, and the
 *     full inner params blob — including the user-supplied deadline so
 *     the same user can legitimately re-compound with a fresh deadline.
 *     originChainId was added to that composite key by F-13/F-20 (audit-13
 *     remediation) so two distinct authenticated cross-chain messages from
 *     the same caller carrying byte-identical op+params but originating on
 *     DIFFERENT chains don't collide on this local-fallback path either.
 *   - `block.timestamp <= deadline` enforced at the module before any token
 *     movement (SC04). Helper enforces a deadline buffer separately, but
 *     the module fails closed on expired deadlines BEFORE pulling the LP.
 *   - Non-zero `lpAmount` enforced (SC04).
 *   - Non-zero pair/router addresses enforced (SC04).
 *   - Non-zero `amountAMin` / `amountBMin` enforced (SC07 sandwich). Helper
 *     accepts zero for backward-compat with the single-chain UI; the
 *     module-side path additionally REJECTS zero to fail closed.
 *   - Post-helper residual LP balance check (SC06). If the helper
 *     misbehaves and leaves dust in the module, we refund it to ctx.caller
 *     before emitting success. No emergency-recovery admin function: the
 *     refund is automatic.
 *   - No Ownable inheritance: the module has no admin functions; allowlists
 *     for routers / pairs (SC04 HIGH) would re-introduce a governance role
 *     that we'd want behind a multisig + timelock, which is a bigger
 *     architectural decision deferred to V2. The current mitigation is
 *     defense-in-depth (the input checks above) plus the deployment policy
 *     of only wiring this module on chains where the frontend's
 *     KNOWN_V2_ROUTERS list covers the user-facing surface.
 *
 * Architectural concerns NOT mitigated at this layer:
 *
 *   SC01 CRITICAL (gateway sole trust boundary): Adding module-level EIP-712
 *   user-intent verification was considered, but would duplicate the
 *   authentication the gateway already performs for the single-chain case
 *   and is insufficient for the cross-chain case (where the user signs on
 *   the source chain — the signature would need to travel in the LZ
 *   payload, an architecture change for ALL Magneta modules, not just this
 *   one). The honest answer is that a compromised gateway is treated as
 *   game-over across the protocol; defense is at the gateway layer.
 *
 *   SC01 HIGH (DVN quorum off-chain): RESOLVED — F-13 (audit-13 remediation).
 *   IMagnetaGateway now exposes `requiredDVNCount()` and this module reads
 *   it not only at construction but on EVERY execute() dispatch (see the
 *   guard at the top of execute()). A constructor-only check meant that a
 *   gateway later reconfigured below the 2-DVN floor would leave an already
 *   -deployed module silently accepting calls under a weaker trust model;
 *   the per-dispatch recheck closes that gap without requiring a redeploy
 *   to detect the downgrade — the module now fails closed instead.
 *
 *   SC04 HIGH (no router/pair allowlist): RESOLVED in chantier #2 — the
 *   module now consumes a MagnetaRouterRegistry (Safe-governed, ideally
 *   behind a Timelock) at every execute(). Compound and migrate ops both
 *   require the router to be on the allowlist; pairs are verified against
 *   the router's own factory via `factory.getPair(token0, token1) == pair`
 *   (F-19 hardening — Sentinelle rescan-15: the original
 *   `pair.factory() == router.factory()` check trusted the pair's
 *   self-reported factory, which an arbitrary contract can spoof without
 *   ever having been created by that factory). An attacker who supplies an
 *   arbitrary router reverts on `RouterNotAllowed` before any token
 *   movement; an attacker who supplies a spoofed pair reverts on
 *   `PairFactoryMismatch`.
 */
contract LPAtomicModule is IModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable gateway;
    address public immutable helper;
    /// @notice Router allowlist consulted at execution time. Chantier #2 —
    ///         eliminates the SC04 HIGH "arbitrary router accepted" risk.
    address public immutable registry;

    /// @notice Per-execution payload hash → consumed (SC02 replay protection).
    mapping(bytes32 => bool) public executedPayloads;

    error NotGateway();
    error UnsupportedOp();
    error ZeroAddress();
    error EthNotAccepted();
    error EmptyParams();
    error DeadlineExpired();
    error LpAmountZero();
    error MinAmountZero();
    error AlreadyExecuted();
    error LpResidual(uint256 amount);
    error DVNQuorumTooLow(uint8 attested);
    error RouterNotAllowed(address router);
    error PairFactoryMismatch(address pair, address router);

    /// @notice Minimum attested DVN quorum the gateway must surface for this
    ///         module to wire up. 2-of-N is the Kelp-DAO-class single-
    ///         validator-risk mitigation floor.
    uint8 public constant MIN_DVN_QUORUM = 2;

    /// @notice Emitted on successful compound. Off-chain monitoring tools can
    ///         subscribe instead of replaying every gateway tx. (SC08 fix)
    event LPCompounded(
        address indexed caller,
        address indexed pair,
        address indexed router,
        uint256          lpAmount
    );

    /// @notice Emitted on successful migrate. Parameter ordering mirrors
    ///         MigrateParams (srcPair → srcRouter → dstRouter); subgraphs
    ///         decoding by position will not silently swap routers
    ///         (Sentinelle 2026-06-12 follow-up — SC08:2026 LOW).
    ///         srcPair stays indexed; we drop dstRouter from the indexed
    ///         slot because migrations are predominantly filtered by source
    ///         pool, not destination router.
    event LPMigrated(
        address indexed caller,
        address indexed srcPair,
        address          srcRouter,
        address          dstRouter,
        uint256          lpAmount
    );

    modifier onlyGateway() {
        if (msg.sender != gateway) revert NotGateway();
        _;
    }

    /**
     * @param _gateway  MagnetaGateway on the chain this module serves.
     * @param _helper   MagnetaLpAtomicHelper on the same chain.
     * @param _registry MagnetaRouterRegistry on the same chain. Mandatory.
     *
     * Reverts:
     *  - `DVNQuorumTooLow` if the gateway's attested DVN floor < MIN_DVN_QUORUM
     *    (chantier #3). This is a deploy-time sanity check only — execute()
     *    independently re-checks the same floor on every call (F-13), so a
     *    later downgrade of the gateway's attested quorum is caught live
     *    without needing to redeploy this module.
     *  - `ZeroAddress` if any constructor arg is zero (no fallback to "no
     *    allowlist" — that would defeat chantier #2).
     */
    constructor(address _gateway, address _helper, address _registry) {
        if (_gateway == address(0) || _helper == address(0) || _registry == address(0)) {
            revert ZeroAddress();
        }
        uint8 attested = IMagnetaGateway(_gateway).requiredDVNCount();
        if (attested < MIN_DVN_QUORUM) revert DVNQuorumTooLow(attested);
        gateway  = _gateway;
        helper   = _helper;
        registry = _registry;
    }

    // ─── Param structs ──────────────────────────────────────────────────

    struct CompoundParams {
        address pair;
        address router;
        uint256 lpAmount;
        /// @dev addLiquidity slippage floor — SC04 fix. Frontend should pass
        ///      ~99 % of the reserves-derived expected amounts.
        uint256 amountAMin;
        uint256 amountBMin;
        uint256 deadline;
    }

    struct MigrateParams {
        address srcPair;
        address srcRouter;
        address dstRouter;
        uint256 lpAmount;
        uint256 amountAMin;
        uint256 amountBMin;
        uint256 deadline;
    }

    /// @inheritdoc IModule
    function execute(Context calldata ctx, bytes calldata params)
        external
        payable
        override
        onlyGateway
        nonReentrant
        returns (bytes memory)
    {
        // F-13: re-check the DVN quorum floor on EVERY dispatch, not just at
        // construction. The constructor-only check left a live module unable
        // to notice a later downgrade of the gateway's attested DVN floor
        // below MIN_DVN_QUORUM — it would keep accepting execute() calls
        // under a weakened (single-validator-class) trust model. Failing
        // closed here means a downgrade takes effect immediately, with no
        // redeploy required to enforce it.
        uint8 attestedDvn = IMagnetaGateway(gateway).requiredDVNCount();
        if (attestedDvn < MIN_DVN_QUORUM) revert DVNQuorumTooLow(attestedDvn);

        // SC10: refuse ETH (interface requires `payable` so we can't drop it).
        if (msg.value != 0) revert EthNotAccepted();
        // SC10: prevent calldata OOB panic on empty params.
        if (params.length < 1) revert EmptyParams();

        IMagnetaGateway.OpType op = IMagnetaGateway.OpType(uint8(params[0]));
        bytes calldata inner = params[1:];

        // SC02 / F-20 / F-22 / F-31: module-level replay protection.
        // Preferred key is the message GUID (unique per authenticated
        // message by LZ spec) so two genuinely distinct bridged messages
        // with byte-identical op+params never collide. Local direct calls
        // carry no GUID (ctx.guid == 0) and fall back to the composite
        // (originChainId, caller, op, inner) key — the deadline lives
        // inside `inner` so legitimate local repeats with a fresh deadline
        // still pass; originChainId keeps that fallback key scoped per
        // origin chain (F-13/F-20).
        bytes32 payloadHash = ctx.guid != bytes32(0)
            ? ctx.guid
            : keccak256(abi.encode(ctx.originChainId, ctx.caller, op, inner));
        if (executedPayloads[payloadHash]) revert AlreadyExecuted();
        executedPayloads[payloadHash] = true;

        if (op == IMagnetaGateway.OpType.POOL_FEE_COMPOUND) {
            return _compound(ctx, inner);
        } else if (op == IMagnetaGateway.OpType.MIGRATE_LP) {
            return _migrate(ctx, inner);
        }
        revert UnsupportedOp();
    }

    function _compound(Context calldata ctx, bytes calldata raw)
        internal
        returns (bytes memory)
    {
        CompoundParams memory p = abi.decode(raw, (CompoundParams));
        // SC04: defensive validation BEFORE pulling LP.
        if (p.pair == address(0) || p.router == address(0)) revert ZeroAddress();
        if (p.lpAmount == 0) revert LpAmountZero();
        if (p.amountAMin == 0 || p.amountBMin == 0) revert MinAmountZero();
        if (block.timestamp > p.deadline) revert DeadlineExpired();
        // Chantier #2: enforce router allowlist + pair-factory binding.
        _checkRouterAndPair(p.router, p.pair);

        // 0. Snapshot pre-transfer balance so the SC06 residual refund only
        //    returns what THIS call's helper failed to consume — not any LP
        //    an attacker pre-donated to grief the next caller.
        uint256 balanceBefore = IERC20(p.pair).balanceOf(address(this));
        // 1. Pull LP from the user into this module.
        IERC20(p.pair).safeTransferFrom(ctx.caller, address(this), p.lpAmount);
        // 2. Approve helper to pull LP from us, then call helper. Helper sends
        //    the resulting new LP + token dust directly to ctx.caller.
        IERC20(p.pair).forceApprove(helper, p.lpAmount);
        IMagnetaLpAtomicHelper(helper).compoundPositionFor(
            p.pair,
            p.router,
            p.lpAmount,
            p.amountAMin,
            p.amountBMin,
            p.deadline,
            ctx.caller
        );
        // 3. Revoke the standing approval — module holds no funds, no allowance.
        IERC20(p.pair).forceApprove(helper, 0);
        // 4. SC06: refund only the delta vs balanceBefore. Closes the donation
        //    grief vector flagged in the 2026-06-12 re-scan (LOW 3.1 SC06).
        _refundDelta(p.pair, balanceBefore, ctx.caller);

        emit LPCompounded(ctx.caller, p.pair, p.router, p.lpAmount);
        return abi.encode(ctx.caller, p.pair, p.lpAmount);
    }

    function _migrate(Context calldata ctx, bytes calldata raw)
        internal
        returns (bytes memory)
    {
        MigrateParams memory p = abi.decode(raw, (MigrateParams));
        if (p.srcPair == address(0) || p.srcRouter == address(0) || p.dstRouter == address(0)) {
            revert ZeroAddress();
        }
        if (p.lpAmount == 0) revert LpAmountZero();
        if (p.amountAMin == 0 || p.amountBMin == 0) revert MinAmountZero();
        if (block.timestamp > p.deadline) revert DeadlineExpired();
        // Chantier #2: enforce allowlist on BOTH ends of the migration.
        // src pair must come from src router's factory; dst pair will be
        // auto-created by dst router so dst router needs allowlist + factory
        // is implicit.
        _checkRouterAndPair(p.srcRouter, p.srcPair);
        if (!IMagnetaRouterRegistry(registry).isRouterAllowed(p.dstRouter)) {
            revert RouterNotAllowed(p.dstRouter);
        }

        uint256 balanceBefore = IERC20(p.srcPair).balanceOf(address(this));
        IERC20(p.srcPair).safeTransferFrom(ctx.caller, address(this), p.lpAmount);
        IERC20(p.srcPair).forceApprove(helper, p.lpAmount);
        IMagnetaLpAtomicHelper(helper).migratePositionFor(
            p.srcPair,
            p.srcRouter,
            p.dstRouter,
            p.lpAmount,
            p.amountAMin,
            p.amountBMin,
            p.deadline,
            ctx.caller
        );
        IERC20(p.srcPair).forceApprove(helper, 0);
        _refundDelta(p.srcPair, balanceBefore, ctx.caller);

        emit LPMigrated(ctx.caller, p.srcPair, p.srcRouter, p.dstRouter, p.lpAmount);
        return abi.encode(ctx.caller, p.srcPair, p.dstRouter, p.lpAmount);
    }

    /// @dev Chantier #2 — router/pair allowlist enforcement. Hardened by F-19
    ///      (Sentinelle rescan-15): `router` must be on the registry allowlist,
    ///      and `pair` must be the CANONICAL pair the router's factory itself
    ///      created for (token0, token1) — i.e.
    ///      `factory.getPair(token0, token1) == pair`. The prior check only
    ///      compared `pair.factory() == router.factory()`, which trusts
    ///      whatever `pair` claims its own factory to be; an attacker's
    ///      contract can implement `factory()` to return the allowlisted
    ///      factory address without ever having been created by it. Asking
    ///      the factory itself "what pair do you have for these two tokens"
    ///      is the only way to establish the pair was genuinely created by
    ///      that factory. Reverts with a specific custom error so off-chain
    ///      decoders can distinguish.
    function _checkRouterAndPair(address router, address pair) private view {
        if (!IMagnetaRouterRegistry(registry).isRouterAllowed(router)) {
            revert RouterNotAllowed(router);
        }
        address routerFactory = IUniV2RouterFactoryView(router).factory();
        address token0 = IUniV2PairView(pair).token0();
        address token1 = IUniV2PairView(pair).token1();
        address canonicalPair = IUniV2FactoryPairView(routerFactory).getPair(token0, token1);
        if (canonicalPair != pair) {
            revert PairFactoryMismatch(pair, router);
        }
    }

    /// @dev SC06 helper. Auto-refund any LP this call's helper failed to
    ///      consume back to the user. Subtracts `balanceBefore` so any LP
    ///      pre-donated to the module by a griefer is intentionally NOT
    ///      swept into the current caller's refund.
    ///
    /// @dev The `balanceOf(address(this))` read here is NOT a pricing /
    ///      share-rate input — it's a post-op dust accounting read used
    ///      only to compute a refund delta. The Venus 2026-03 zkSync
    ///      donation-attack pattern (where `balanceOf` was the divisor in
    ///      an exchange-rate calc) does not apply. Inline note added to
    ///      suppress future Sentinelle static-sentinel ACC-1 noise.
    function _refundDelta(address pair, uint256 balanceBefore, address to) private {
        uint256 balanceAfter = IERC20(pair).balanceOf(address(this));
        if (balanceAfter > balanceBefore) {
            IERC20(pair).safeTransfer(to, balanceAfter - balanceBefore);
        }
    }
}
