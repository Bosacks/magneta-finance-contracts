// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MagnetaPool} from "../contracts/core/MagnetaPool.sol";
import {MagnetaSwap} from "../contracts/core/MagnetaSwap.sol";
import {MockERC20} from "../contracts/tokens/MockERC20.sol";

/// @title MagnetaSwap — price-impact cap blocks the naive sandwich
/// @notice Proves the opt-in `maxPriceImpactBps` guard: with it enabled, the
///         outsized front-run a sandwich needs REVERTS, so the attack can't be
///         set up — while ordinary small swaps still go through. Default (cap=0)
///         is unchanged, shown by the baseline test.
///
///   RUN: forge test --match-contract MagnetaSwapSlippageCap \
///          --skip 'contracts/imports/*' --skip 'contracts/uniswap/*' \
///          --skip '*UniV2*' --skip '*MagnetaV2*' -vv
contract MagnetaSwapSlippageCap is Test {
    MagnetaPool internal pool;
    MagnetaSwap internal swap;
    MockERC20   internal tokenA;
    MockERC20   internal tokenB;

    address internal constant ATTACKER = address(0xBAD);
    uint256 constant LIQ = 1_000_000e18;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18, 1e30);
        tokenB = new MockERC20("Token B", "TKB", 18, 1e30);

        pool = new MagnetaPool(address(this));
        uint256 poolId = pool.createPool(address(tokenA), address(tokenB), 30);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(poolId, LIQ, LIQ, 0, 0, address(0xB0B));

        swap = new MagnetaSwap(address(0xFEE), address(pool));
        swap.setWhitelistedToken(address(tokenA), true);
        swap.setWhitelistedToken(address(tokenB), true);

        tokenA.transfer(ATTACKER, 500_000e18);
    }

    function _frontRun(uint256 amountIn) internal returns (uint256) {
        vm.startPrank(ATTACKER);
        tokenA.approve(address(swap), amountIn);
        uint256 out = swap.swap(address(tokenA), address(tokenB), amountIn, 0, ATTACKER, block.timestamp);
        vm.stopPrank();
        return out;
    }

    // Baseline: cap disabled (default) → the big front-run goes through.
    function test_noCap_frontRunSucceeds() public {
        assertEq(swap.maxPriceImpactBps(), 0, "cap should default to disabled");
        uint256 out = _frontRun(200_000e18); // ~17% impact on 1M reserves
        assertGt(out, 0, "front-run should succeed with no cap");
    }

    // Cap ON (3%) → the same sandwich-sized front-run REVERTS.
    function test_cap_blocksSandwichFrontRun() public {
        swap.setMaxPriceImpactBps(300); // 3%
        vm.startPrank(ATTACKER);
        tokenA.approve(address(swap), 200_000e18);
        vm.expectRevert(bytes("MagnetaSwap: price impact too high"));
        swap.swap(address(tokenA), address(tokenB), 200_000e18, 0, ATTACKER, block.timestamp);
        vm.stopPrank();
    }

    // Cap ON (3%) → an ordinary small swap (~0.1% impact) still works.
    function test_cap_allowsNormalSwap() public {
        swap.setMaxPriceImpactBps(300);
        uint256 out = _frontRun(1_000e18); // ~0.1% impact
        assertGt(out, 0, "normal swap should pass under the cap");
    }
}
