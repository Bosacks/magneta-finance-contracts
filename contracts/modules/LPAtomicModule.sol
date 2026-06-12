// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IModule.sol";
import "../interfaces/IMagnetaGateway.sol";

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
 *     reverts on the second attempt. The hash mixes ctx.caller, op, and the
 *     full inner params blob — including the user-supplied deadline so the
 *     same user can legitimately re-compound with a fresh deadline.
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
 *   SC01 HIGH (DVN quorum off-chain): Same as the 2026-06-12 follow-up.
 *   Cannot enforce on-chain until IMagnetaGateway exposes a view; the
 *   deployment script invariant is the V1 control.
 *
 *   SC04 HIGH (no router/pair allowlist): Deferred to V2 with a multisig-
 *   governed registry. V1 trusts the frontend's curated KNOWN_V2_ROUTERS
 *   surface; an attacker bypassing the UI to call with a malicious router
 *   is bounded to losing the LP they themselves supplied (the module never
 *   approves anything except for the user-supplied router and only for the
 *   user-supplied amount).
 */
contract LPAtomicModule is IModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable gateway;
    address public immutable helper;

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
     *
     * Reverts with `DVNQuorumTooLow` if the gateway's attested DVN floor is
     * below MIN_DVN_QUORUM (= 2). The attestation is a Safe-managed value on
     * the gateway (see MagnetaGateway.setRequiredDVNCount); operators MUST
     * call setRequiredDVNCount(>= 2) on the gateway BEFORE deploying this
     * module. This is the on-chain anchor for the Kelp-DAO-class single-
     * validator-risk mitigation — replaces the prior off-chain deployment-
     * checklist invariant (Sentinelle 2026-06-12 SC01:2026 chantier #3).
     */
    constructor(address _gateway, address _helper) {
        if (_gateway == address(0) || _helper == address(0)) revert ZeroAddress();
        uint8 attested = IMagnetaGateway(_gateway).requiredDVNCount();
        if (attested < MIN_DVN_QUORUM) revert DVNQuorumTooLow(attested);
        gateway = _gateway;
        helper  = _helper;
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
        // SC10: refuse ETH (interface requires `payable` so we can't drop it).
        if (msg.value != 0) revert EthNotAccepted();
        // SC10: prevent calldata OOB panic on empty params.
        if (params.length < 1) revert EmptyParams();

        IMagnetaGateway.OpType op = IMagnetaGateway.OpType(uint8(params[0]));
        bytes calldata inner = params[1:];

        // SC02: module-level replay protection. Hashing the (caller, op, inner)
        // triple makes each user's calls scoped per (op, params); the deadline
        // is inside `inner` so legitimate repeats with a fresh deadline pass.
        bytes32 payloadHash = keccak256(abi.encode(ctx.caller, op, inner));
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
