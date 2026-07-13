// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MagnetaLpAtomicHelper
 * @notice V1.1 atomic versions of two existing Liquidity Manage flows that
 *         today are sequential 4-tx wizards in the Tokens UI:
 *
 *           1. compoundPosition  ↔ Pool Fee Collection / LP Rebalance
 *              (remove from a UniV2 pair, immediately re-add at the same
 *              ratio, return the new LP to the user)
 *
 *           2. migratePosition   ↔ Migrate Liquidity
 *              (remove from DEX A's pair, immediately re-add on DEX B's
 *              router, return the new LP to the user)
 *
 *         Both functions collapse the wizard into a single user signature.
 *         The helper holds NO persistent state — every external call refunds
 *         any token / native dust to msg.sender before returning, so a
 *         compromise of the helper does not put existing balances at risk.
 *
 * Trust model:
 *   - User approves the helper for the LP token (one-time, per-pair).
 *   - Inside each call the helper approves the router on-the-fly for the
 *     exact removed amounts, then revokes by calling approve(router, 0)
 *     at the end. No standing approvals from the helper to any router.
 *   - The helper never holds an ETH/ERC20 balance across calls: every
 *     successful path ends with the user holding the new LP plus any dust.
 *
 * Why a standalone contract (not a UniV2-router fork):
 *   Forking the router doubles the audit surface and is overkill — the
 *   atomic compound / migrate flow needs only a handful of router calls
 *   sequenced safely. This helper is ~250 lines and any well-known
 *   UniV2 router can be passed in at call time.
 *
 * Security notes for the next reviewer:
 *   - nonReentrant on every external entry point (covers token transfer
 *     hooks on tax / fee-on-transfer tokens — for which addLiquidity may
 *     fail anyway; we surface the revert cleanly).
 *   - SafeERC20 throughout (USDT-style non-bool-returning approvals).
 *   - No selfdestruct / delegatecall / arbitrary calls.
 *   - ERC20-only scope. Pairs where one side is WETH still work because
 *     the helper treats WETH as a regular ERC20 (user wraps/unwraps
 *     outside this contract). No ETH receive() or ETH-paired router
 *     variants are intentionally included in this version (was the SC06
 *     finding from the 2026-06-12 Sentinelle scan — NatSpec was previously
 *     misleading on this point).
 *   - addLiquidity slippage protection: the user supplies amountAMin /
 *     amountBMin per call. Passing 0/0 reverts to the pre-2026-06-12
 *     behaviour and exposes the user to a sandwich on the re-add step
 *     (SC04 from the same audit). The frontend should default these to
 *     ~99 % of the removed amounts so the second leg fails closed when
 *     a sandwich would push pool reserves out of band.
 */
contract MagnetaLpAtomicHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Per-call deadlines must beat this floor — guards against legacy frontends
    /// that pass `0` and would let pending mempool calls execute weeks later.
    uint256 private constant MIN_DEADLINE_BUFFER = 60;

    /// Reverted when the supplied deadline is at or within
    /// MIN_DEADLINE_BUFFER seconds of the current block, including
    /// already-expired deadlines. (Sentinelle 2026-06-12 follow-up:
    /// name was previously `DeadlinePassed` which misled integrators
    /// parsing revert reasons; semantics clarified after re-scan.)
    error DeadlineTooClose();
    error LpAmountZero();
    error NewLpZero();
    error ZeroAddress();
    /// @dev Reserved for the `For`-variant zero-recipient check. Mirrors
    ///      the other custom-error pattern so off-chain decoders see a
    ///      single uniform revert-reason vocabulary (no require-strings).
    error ZeroRecipient();

    event Compounded(
        address indexed user,
        address indexed pair,
        address indexed router,
        uint256 burnedLp,
        uint256 newLp,
        uint256 amount0Used,
        uint256 amount1Used
    );

    event Migrated(
        address indexed user,
        address indexed srcPair,
        address indexed srcRouter,
        address          dstRouter,
        uint256          burnedLp,
        uint256          newLp,
        uint256          amount0Used,
        uint256          amount1Used
    );

    /**
     * @notice Remove `lpAmount` from `(token0, token1)` on `router` and
     *         immediately re-add at the freshly-computed ratio. The new LP
     *         goes to msg.sender; any token dust the router didn't consume
     *         is returned to msg.sender too.
     *
     * @param  pair      UniV2 pair address — its (token0, token1) are read
     *                   on-chain so the caller doesn't have to know.
     * @param  router    UniV2 router (e.g. QuickSwap, BaseSwap, Sushi).
     * @param  lpAmount  Amount of `pair` LP to compound.
     * @param  deadline  Unix timestamp after which the call reverts. Must
     *                   be at least block.timestamp + 60.
     */
    /**
     * @param amountAMin / amountBMin  Slippage floor on the addLiquidity
     *                                 step (SC04 fix). Frontend should pass
     *                                 ~99 % of the expected removed amount
     *                                 for each side. Passing 0 disables
     *                                 protection (legacy, NOT RECOMMENDED).
     */
    function compoundPosition(
        address pair,
        address router,
        uint256 lpAmount,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) external nonReentrant {
        _compoundPositionFor(pair, router, lpAmount, amountAMin, amountBMin, deadline, msg.sender);
    }

    /**
     * @notice Same as compoundPosition but sends the resulting LP + dust to
     *         an explicit `recipient`. Intended for module/integrator use
     *         (e.g. LPAtomicModule wired into the Magneta Gateway) where the
     *         caller is the module and the original user is `recipient`.
     *         The LP pulled at step 1 still comes from msg.sender; allowance
     *         must be in place on msg.sender → this helper.
     */
    function compoundPositionFor(
        address pair,
        address router,
        uint256 lpAmount,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        address recipient
    ) external nonReentrant {
        if (recipient == address(0)) revert ZeroRecipient();
        _compoundPositionFor(pair, router, lpAmount, amountAMin, amountBMin, deadline, recipient);
    }

    function _compoundPositionFor(
        address pair,
        address router,
        uint256 lpAmount,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        address recipient
    ) private {
        if (pair == address(0) || router == address(0)) revert ZeroAddress();
        if (lpAmount == 0) revert LpAmountZero();
        if (deadline <= block.timestamp + MIN_DEADLINE_BUFFER) revert DeadlineTooClose();

        (address token0, address token1) = _pairTokens(pair);

        // 1. Pull the LP and authorize the router to burn it.
        IERC20(pair).safeTransferFrom(msg.sender, address(this), lpAmount);
        IERC20(pair).forceApprove(router, lpAmount);

        // 2. Remove liquidity; underlying tokens land on the helper.
        (uint256 amount0, uint256 amount1) = IUniswapV2Router02(router).removeLiquidity(
            token0,
            token1,
            lpAmount,
            0, // amountAMin — slippage on the burn itself; UniV2 burns at exact reserves
            0,
            address(this),
            deadline
        );

        // 3. Approve the router for the just-received amounts, then re-add.
        //    amountAMin/amountBMin defend the re-add against a sandwich that
        //    pushes the pool ratio between remove and add (SC04 fix).
        IERC20(token0).forceApprove(router, amount0);
        IERC20(token1).forceApprove(router, amount1);
        (uint256 used0, uint256 used1, uint256 newLp) = IUniswapV2Router02(router).addLiquidity(
            token0,
            token1,
            amount0,
            amount1,
            amountAMin,
            amountBMin,
            recipient, // LP goes straight to the recipient
            deadline
        );
        if (newLp == 0) revert NewLpZero();

        // 4. Refund any dust the router didn't consume + revoke standing approvals.
        if (amount0 > used0) IERC20(token0).safeTransfer(recipient, amount0 - used0);
        if (amount1 > used1) IERC20(token1).safeTransfer(recipient, amount1 - used1);
        IERC20(token0).forceApprove(router, 0);
        IERC20(token1).forceApprove(router, 0);

        emit Compounded(recipient, pair, router, lpAmount, newLp, used0, used1);
    }

    /**
     * @notice Atomically move LP from `srcRouter`'s pair to `dstRouter`. The
     *         pair contract addresses on the two DEXes are different (their
     *         factories differ), but token0 / token1 stay identical — this
     *         function does removeLiquidity on the source pair then
     *         addLiquidity on the destination router for the same token
     *         pair, sending the new LP to msg.sender.
     *
     *         Slippage risk: between the src `removeLiquidity` and the dst
     *         `addLiquidity` the destination pool's ratio may differ slightly
     *         from the source's, so the user might end up with slightly more
     *         of one token and slightly less LP than a perfect 1:1 move. Any
     *         leftover token dust is refunded.
     *
     * @param  srcPair    UniV2 pair on the source DEX.
     * @param  srcRouter  UniV2 router for the source DEX.
     * @param  dstRouter  UniV2 router for the destination DEX. The function
     *                   does NOT verify the dst pair exists — UniV2's
     *                   addLiquidity auto-creates it if absent.
     * @param  lpAmount   Amount of source LP to migrate.
     * @param  deadline   Unix deadline; must be > block.timestamp + 60.
     */
    /// @param amountAMin / amountBMin  Slippage floor on dstRouter.addLiquidity
    ///                                 (SC04 fix). Frontend should pass ~99 %
    ///                                 of the expected removed amount.
    function migratePosition(
        address srcPair,
        address srcRouter,
        address dstRouter,
        uint256 lpAmount,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) external nonReentrant {
        _migratePositionFor(srcPair, srcRouter, dstRouter, lpAmount, amountAMin, amountBMin, deadline, msg.sender);
    }

    /// @notice Migrate variant that sends the dst LP + dust to `recipient`.
    ///         Same trust model as compoundPositionFor.
    function migratePositionFor(
        address srcPair,
        address srcRouter,
        address dstRouter,
        uint256 lpAmount,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        address recipient
    ) external nonReentrant {
        if (recipient == address(0)) revert ZeroRecipient();
        _migratePositionFor(srcPair, srcRouter, dstRouter, lpAmount, amountAMin, amountBMin, deadline, recipient);
    }

    function _migratePositionFor(
        address srcPair,
        address srcRouter,
        address dstRouter,
        uint256 lpAmount,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        address recipient
    ) private {
        if (srcPair == address(0) || srcRouter == address(0) || dstRouter == address(0)) revert ZeroAddress();
        if (lpAmount == 0) revert LpAmountZero();
        if (deadline <= block.timestamp + MIN_DEADLINE_BUFFER) revert DeadlineTooClose();

        (address token0, address token1) = _pairTokens(srcPair);

        // 1. Pull LP, approve src router, remove liquidity.
        IERC20(srcPair).safeTransferFrom(msg.sender, address(this), lpAmount);
        IERC20(srcPair).forceApprove(srcRouter, lpAmount);
        (uint256 amount0, uint256 amount1) = IUniswapV2Router02(srcRouter).removeLiquidity(
            token0,
            token1,
            lpAmount,
            0,
            0,
            address(this),
            deadline
        );

        // 2. Approve dst router and add on the destination pool.
        //    Slippage floor protects against sandwich on the dst-pool add
        //    (SC04 fix). dst pool may not pre-exist; UniV2 auto-creates it.
        IERC20(token0).forceApprove(dstRouter, amount0);
        IERC20(token1).forceApprove(dstRouter, amount1);
        (uint256 used0, uint256 used1, uint256 newLp) = IUniswapV2Router02(dstRouter).addLiquidity(
            token0,
            token1,
            amount0,
            amount1,
            amountAMin,
            amountBMin,
            recipient,
            deadline
        );
        if (newLp == 0) revert NewLpZero();

        // 3. Refund dust + revoke standing approvals.
        if (amount0 > used0) IERC20(token0).safeTransfer(recipient, amount0 - used0);
        if (amount1 > used1) IERC20(token1).safeTransfer(recipient, amount1 - used1);
        IERC20(token0).forceApprove(dstRouter, 0);
        IERC20(token1).forceApprove(dstRouter, 0);

        emit Migrated(recipient, srcPair, srcRouter, dstRouter, lpAmount, newLp, used0, used1);
    }

    // ────────────────────────────────────────────────────────────────────
    // Internals
    // ────────────────────────────────────────────────────────────────────

    function _pairTokens(address pair) private view returns (address t0, address t1) {
        t0 = IUniswapV2Pair(pair).token0();
        t1 = IUniswapV2Pair(pair).token1();
    }
}

// ────────────────────────────────────────────────────────────────────────
// Minimal interfaces for the UniV2 ecosystem. Avoid pulling in a full
// dependency tree — the helper only needs these 5 selectors total.
// ────────────────────────────────────────────────────────────────────────

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV2Router02 {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}
