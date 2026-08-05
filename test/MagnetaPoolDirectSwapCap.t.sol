// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MagnetaPool} from "../contracts/core/MagnetaPool.sol";
import {MagnetaSwap} from "../contracts/core/MagnetaSwap.sol";
import {MockERC20} from "../contracts/tokens/MockERC20.sol";

/// @title MagnetaPool — the price-impact cap cannot be dodged by calling the pool directly
/// @notice MagnetaSwap's cap (see MagnetaSwapSlippageCap.t.sol) only binds callers
///         who go through the router. `MagnetaPool.swap` is `external` with no
///         caller restriction, so a sandwicher could simply call the pool and skip
///         both the cap AND the router's service fee. These tests pin the fix:
///         the cap is enforced inside the pool, so every caller is subject to it.
///
///   RUN: forge test --match-contract MagnetaPoolDirectSwapCap \
///          --skip 'contracts/imports/*' --skip 'contracts/uniswap/*' \
///          --skip '*UniV2*' --skip '*MagnetaV2*' -vv
contract MagnetaPoolDirectSwapCap is Test {
    MagnetaPool internal pool;
    MagnetaSwap internal swap;
    MockERC20   internal tokenA;
    MockERC20   internal tokenB;

    uint256 internal poolId;
    address internal constant ATTACKER = address(0xBAD);
    uint256 constant LIQ = 1_000_000e18;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18, 1e30);
        tokenB = new MockERC20("Token B", "TKB", 18, 1e30);

        pool = new MagnetaPool(address(this));
        poolId = pool.createPool(address(tokenA), address(tokenB), 30);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(poolId, LIQ, LIQ, 0, 0, address(0xB0B));

        swap = new MagnetaSwap(address(0xFEE), address(pool));
        swap.setWhitelistedToken(address(tokenA), true);
        swap.setWhitelistedToken(address(tokenB), true);

        tokenA.transfer(ATTACKER, 500_000e18);
    }

    /// Direct pool call, bypassing the router entirely.
    function _directSwap(uint256 amountIn) internal returns (uint256) {
        vm.startPrank(ATTACKER);
        tokenA.approve(address(pool), amountIn);
        uint256 out = pool.swap(poolId, address(tokenA), amountIn, 0, ATTACKER, block.timestamp);
        vm.stopPrank();
        return out;
    }

    // ── The hole this fix closes ──────────────────────────────────────────
    // Router capped at 3%, pool cap left at its default 0: the outsized
    // front-run the router rejects still lands when aimed at the pool.
    function test_routerCapAlone_isBypassedByDirectPoolCall() public {
        swap.setMaxPriceImpactBps(300);
        // Disable the pool cap explicitly to recreate the pre-fix world: only
        // the router capped. (Fresh deploys are armed at 10% since 2026-08-04,
        // so this hole is no longer reachable by accident.)
        pool.setMaxPriceImpactBps(0);

        // Same trade through the router: rejected.
        vm.startPrank(ATTACKER);
        tokenA.approve(address(swap), 400_000e18);
        vm.expectRevert("MagnetaSwap: price impact too high");
        swap.swap(address(tokenA), address(tokenB), 400_000e18, 0, ATTACKER, block.timestamp);
        vm.stopPrank();

        // Straight at the pool: goes through. This is the bypass.
        uint256 out = _directSwap(400_000e18);
        assertGt(out, 0, "direct pool swap should still succeed while the pool cap is off");
    }

    // ── The fix ───────────────────────────────────────────────────────────
    function test_poolCap_blocksDirectFrontRun() public {
        pool.setMaxPriceImpactBps(300); // 3%

        vm.startPrank(ATTACKER);
        tokenA.approve(address(pool), 400_000e18);
        vm.expectRevert("MagnetaPool: price impact too high");
        pool.swap(poolId, address(tokenA), 400_000e18, 0, ATTACKER, block.timestamp);
        vm.stopPrank();
    }

    function test_poolCap_allowsNormalSwap() public {
        pool.setMaxPriceImpactBps(300);
        // 1% of the reserve — a normal trade must stay unaffected.
        uint256 out = _directSwap(10_000e18);
        assertGt(out, 0, "ordinary swap must still work under the cap");
    }

    /// The cap binds on the reserve BEFORE the swap, so a trade sitting exactly
    /// at the limit passes and one just past it reverts. Solve impact =
    /// in/(res+in) for 300 bps. Order matters: the over-cap case is checked
    /// FIRST, because a successful at-cap swap moves the reserve and the same
    /// amountIn would no longer be over the limit against the new one — the
    /// first draft of this test failed for exactly that reason.
    function test_poolCap_boundaryIsExact() public {
        pool.setMaxPriceImpactBps(300);
        uint256 atCap = (LIQ * 300) / (10_000 - 300); // impact == 300 bps exactly

        vm.startPrank(ATTACKER);
        uint256 over = atCap + 1e21;
        tokenA.approve(address(pool), over);
        vm.expectRevert("MagnetaPool: price impact too high");
        pool.swap(poolId, address(tokenA), over, 0, ATTACKER, block.timestamp);
        vm.stopPrank();

        uint256 out = _directSwap(atCap);
        assertGt(out, 0, "a swap exactly at the cap must pass");
    }

    function test_setter_rejectsCapAbove100Percent() public {
        vm.expectRevert("MagnetaPool: cap above 100%");
        pool.setMaxPriceImpactBps(10_001);
    }

    function test_setter_isOwnerOnly() public {
        vm.prank(ATTACKER);
        vm.expectRevert();
        pool.setMaxPriceImpactBps(300);
    }

    /// A fresh pool is ARMED at 10%: the fix must not depend on anyone
    /// remembering a post-deploy call. The owner keeps the escape hatch.
    function test_capIsArmedOnDeploy() public {
        assertEq(pool.maxPriceImpactBps(), 1_000, "fresh deploy should be armed at 10%");
        vm.startPrank(ATTACKER);
        tokenA.approve(address(pool), 400_000e18);
        vm.expectRevert("MagnetaPool: price impact too high");
        pool.swap(poolId, address(tokenA), 400_000e18, 0, ATTACKER, block.timestamp);
        vm.stopPrank();
    }

    function test_ownerCanDisable() public {
        pool.setMaxPriceImpactBps(0);
        uint256 out = _directSwap(400_000e18);
        assertGt(out, 0, "with the cap explicitly off, behaviour is unchanged");
    }
}
