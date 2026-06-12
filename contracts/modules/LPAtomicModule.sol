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
 * Sentinelle considerations:
 *   - nonReentrant on execute().
 *   - SafeERC20 for the LP pull / helper approval.
 *   - Module never receives ETH (LP ops use ERC20-only paths via the helper).
 *     The dispatch from gateway forwards no msg.value for these ops.
 *   - No Ownable inheritance: the module has no admin functions, so an owner
 *     role would be unused dead-code surface (removed per SC01 review).
 */
contract LPAtomicModule is IModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable gateway;
    address public immutable helper;

    error NotGateway();
    error UnsupportedOp();
    error ZeroAddress();

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
     * Deployment invariant (Sentinelle 2026-06-12 SC01:2026 follow-up):
     *
     *   The wired gateway MUST be configured with a ≥ 2-of-N LayerZero DVN
     *   quorum BEFORE this module is registered for any OpType. This module
     *   does not call into the gateway to verify the DVN count at deploy
     *   time because IMagnetaGateway does not yet expose `requiredDVNCount()`
     *   — the deployment script `scripts/deploy/deployLPAtomicModule.ts`
     *   MUST instead reverify the gateway's DVN config off-chain and revert
     *   if count < 2. Failure to do so reintroduces the Kelp-DAO-class
     *   single-validator risk that this comment exists to deter.
     *
     *   When `requiredDVNCount()` lands on the gateway interface, replace
     *   the off-chain check with an on-chain `require(IMagnetaGateway(
     *   _gateway).requiredDVNCount() >= 2, "MagnetaLPAtomic: DVN quorum")`
     *   in this constructor and remove this paragraph.
     */
    constructor(address _gateway, address _helper) {
        if (_gateway == address(0) || _helper == address(0)) revert ZeroAddress();
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
        IMagnetaGateway.OpType op = IMagnetaGateway.OpType(uint8(params[0]));
        bytes calldata inner = params[1:];

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

        emit LPCompounded(ctx.caller, p.pair, p.router, p.lpAmount);
        return abi.encode(ctx.caller, p.pair, p.lpAmount);
    }

    function _migrate(Context calldata ctx, bytes calldata raw)
        internal
        returns (bytes memory)
    {
        MigrateParams memory p = abi.decode(raw, (MigrateParams));

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

        emit LPMigrated(ctx.caller, p.srcPair, p.srcRouter, p.dstRouter, p.lpAmount);
        return abi.encode(ctx.caller, p.srcPair, p.dstRouter, p.lpAmount);
    }
}
