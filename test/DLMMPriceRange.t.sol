// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/libraries/BinHelper.sol";
import "../contracts/core/MagnetaDLMM.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TT is ERC20 {
    constructor() ERC20("T", "T") { _mint(msg.sender, 1e30); }
    function mintTo(address to, uint256 a) external { _mint(to, a); }
}

/// Free-scan 2026-07-31, findings C-1 / H-1 on the DLMM price curve.
///
/// `createDLMMPool` is permissionless on ~20 deployed MagnetaFactory
/// instances and `initialActiveId` was never validated anywhere. Far enough
/// below BASE_ID, BinHelper's repeated floor division reaches EXACTLY zero;
/// a zero price makes swap() consume the whole input, return nothing, and
/// still satisfy `amountOut >= minAmountOut`.
contract DLMMPriceRangeTest is Test {
    // Verified independently (integer simulation of the exact loop):
    //   binStep 100 bps -> price hits 0 at step 3760
    //   binStep 300 bps -> step 1302
    //   binStep 500 bps -> step  799   (and overflows upward at step 2599)
    uint24 constant BASE = 8_388_608;

    function _wrap(uint24 id, uint16 step) external pure returns (uint256) {
        return BinHelper.getPriceFromId(id, step);
    }

    // ── C-1: the price must never be zero — it must revert ────────────────
    function test_C1_downwardPriceNeverReturnsZero() public {
        uint16 step = 100;
        // Just inside the representable range: a real, non-zero price.
        uint256 p = this._wrap(BASE - 3700, step);
        assertGt(p, 0, "price must stay positive inside the range");

        // Past the underflow point the old code returned 0 silently.
        vm.expectRevert(
            abi.encodeWithSelector(BinHelper.PriceUnderflow.selector, BASE - 3800, step)
        );
        this._wrap(BASE - 3800, step);
    }

    function test_C1_underflowRevertsForEveryAllowedBinStep() public {
        // Every binStep the factory accepts and that can reach zero.
        uint16[3] memory steps = [uint16(100), 300, 500];
        uint24[3] memory zeroAt = [uint24(3760), 1302, 799];
        for (uint256 i = 0; i < 3; ++i) {
            vm.expectRevert();
            this._wrap(BASE - zeroAt[i], steps[i]);
        }
    }

    // ── the clamp itself was a bug: distinct bins shared one price ────────
    function test_clampReplacedByRevert_priceStaysStrictlyMonotonic() public {
        uint16 step = 10; // never underflows within MAX_STEPS
        uint256 a = this._wrap(BASE - 4000, step);
        uint256 b = this._wrap(BASE - 4001, step);
        assertLt(b, a, "each step down must be strictly cheaper");

        // Beyond MAX_STEPS the old code clamped (same price for every id);
        // it now refuses instead of lying.
        vm.expectRevert(abi.encodeWithSelector(BinHelper.BinTooFar.selector, uint24(4097)));
        this._wrap(BASE - 4097, step);
    }

    // ── H-1: upward overflow is a revert, never a wrapped price ───────────
    function test_H1_upwardOverflowReverts() public {
        vm.expectRevert(); // arithmetic panic 0x11
        this._wrap(BASE + 2600, 500);
    }

    // ── the payoff: a poisoned pool can no longer be constructed ──────────
    function test_C1_poolWithZeroPriceBinCannotBeCreated() public {
        TT x = new TT();
        TT y = new TT();
        // binStep 100, activeId in the dead zone -> construction must revert.
        vm.expectRevert();
        new MagnetaDLMM(
            address(x), address(y), 100, 30, 10,
            BASE - 3800, address(this), address(this)
        );
    }

    function test_healthyPoolStillDeploysAndPrices() public {
        TT x = new TT();
        TT y = new TT();
        MagnetaDLMM pool = new MagnetaDLMM(
            address(x), address(y), 100, 30, 10,
            BASE, address(this), address(this)
        );
        assertEq(pool.getBinPrice(BASE), 1e18, "price at BASE_ID is 1.0");
        assertGt(pool.getBinPrice(BASE - 100), 0);
    }
}
