// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Audit #13 remediation coverage for MagnetaLending — one test per finding
// (F-2, F-3, F-7, F-8, F-9, F-11, F-18, F-19, F-22). Reuses the mocks
// (MockToken / MockPriceFeed / GoodFlashReceiver) already declared in
// MagnetaLending.t.sol instead of redefining them.

import "forge-std/Test.sol";
import "../contracts/core/MagnetaLending.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MagnetaLending.t.sol";

/// @dev Fee-on-transfer mock: every transfer() / transferFrom() burns `feeBps`
/// of the amount to a dead address, so the recipient always receives less
/// than the nominal amount. Used to exercise F-8.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps;
    uint8 private immutable _dec;

    constructor(string memory name, string memory symbol, uint8 dec, uint256 _feeBps) ERC20(name, symbol) {
        _dec = dec;
        feeBps = _feeBps;
        _mint(msg.sender, 1_000_000 * 10 ** dec);
    }

    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = (amount * feeBps) / 10_000;
        super._transfer(from, to, amount - fee);
        if (fee > 0) {
            super._transfer(from, address(0xdEaD), fee);
        }
    }
}

contract MagnetaLendingRemediationTest is Test {
    MagnetaLending lending;
    MockToken usdc;
    MockToken weth;
    MockPriceFeed usdcFeed;
    MockPriceFeed wethFeed;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");

    uint256 constant USDC_PRICE = 1e8;    // $1.00
    uint256 constant WETH_PRICE = 2000e8; // $2000.00

    function setUp() public {
        lending = new MagnetaLending();
        usdc = new MockToken("USD Coin", "USDC", 6);
        weth = new MockToken("Wrapped ETH", "WETH", 18);
        usdcFeed = new MockPriceFeed(int256(USDC_PRICE));
        wethFeed = new MockPriceFeed(int256(WETH_PRICE));

        // F-19: feeds must be configured before initReserve.
        lending.setPriceFeed(address(usdc), address(usdcFeed), address(0), 0.5e18, 2e18, 0);
        lending.setPriceFeed(address(weth), address(wethFeed), address(0), 100e18, 10_000e18, 0);
        lending.initReserve(address(usdc), 7500, 8000); // 75% LTV / 80% liq threshold
        lending.initReserve(address(weth), 7500, 8000); // 75% LTV / 80% liq threshold

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(liquidator, 1_000_000e6);
        weth.mint(alice, 1_000e18);
        weth.mint(bob, 1_000e18);
    }

    // ── F-2: interest-inclusive repay/withdraw must never underflow ────────────
    //
    // On the pre-remediation contract, totalSupplied/totalBorrowed were
    // nominal (principal-only) accumulators. `reserve.totalBorrowed -=
    // principalRepaid` capped the subtraction, so full-debt repayment after
    // interest accrual quietly desynced totalBorrowed from reality — but the
    // real bug was on the supply side: `reserve.totalSupplied -= amount` in
    // withdraw() had no such cap, and a supplier withdrawing their
    // interest-inclusive balance (which is *larger* than the nominal
    // totalSupplied once interest has accrued) would underflow and revert,
    // permanently bricking the reserve for the last depositor(s) out (a bank
    // run that can never complete). This test reproduces exactly that
    // sequence against the remediated contract, where totals are derived
    // from shares × index instead of a separate nominal counter — so it
    // must now succeed end-to-end.
    function test_F2_interestInclusiveRepayThenFullWithdraw_noUnderflow() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 100_000e6);
        lending.deposit(address(usdc), 100_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(lending), 10e18);
        lending.deposit(address(weth), 10e18);   // $20,000 collateral
        lending.borrow(address(usdc), 5_000e6);  // well within 75% LTV
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // getUserBorrow is a view over the stored borrowIndex; force an update
        // (any state-changing call on the reserve routes through
        // _updateReserve) with a no-op zero-amount repay before reading it.
        vm.prank(alice);
        lending.repay(address(usdc), 0);

        uint256 debt = lending.getUserBorrow(alice, address(usdc));
        assertGt(debt, 5_000e6, "interest must have accrued on the debt");

        usdc.mint(alice, debt); // top up so alice can cover principal + interest
        vm.startPrank(alice);
        usdc.approve(address(lending), type(uint256).max);
        lending.repay(address(usdc), type(uint256).max); // full interest-inclusive repay
        vm.stopPrank();
        assertEq(lending.getUserBorrow(alice, address(usdc)), 0);

        uint256 bobBalance = lending.getUserCollateral(bob, address(usdc));
        assertGt(bobBalance, 100_000e6, "supplier must have earned interest");

        // The underflow this reproduces would revert right here.
        vm.prank(bob);
        lending.withdraw(address(usdc), bobBalance);
        assertEq(lending.getUserCollateral(bob, address(usdc)), 0);
    }

    // ── F-3: borrow power uses ltv, liquidation uses liquidationThreshold ──────

    function test_F3_borrowCappedAtLtv_liquidatableOnlyPastThreshold() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000_000e6);
        lending.deposit(address(usdc), 1_000_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(lending), 1e18);
        lending.deposit(address(weth), 1e18); // $2000 collateral, ltv 7500 / threshold 8000

        // 76% of $2000 = $1520 > 75% LTV cap → revert.
        vm.expectRevert("Borrow exceeds LTV limit");
        lending.borrow(address(usdc), 1_520e6);

        // Exactly the 75% LTV cap succeeds.
        lending.borrow(address(usdc), 1_500e6);
        vm.stopPrank();

        (, , , , uint256 hf) = lending.calculateUserAccountData(alice);
        assertGe(hf, 1e18, "a position sized to avgLtv must be healthy since ltv <= threshold");

        // Not liquidatable yet: 75% debt/collateral is below the 80% threshold.
        vm.startPrank(liquidator);
        usdc.approve(address(lending), 500e6);
        vm.expectRevert("User is healthy");
        lending.liquidate(alice, address(usdc), address(weth), 500e6);
        vm.stopPrank();

        // Crash WETH $2000 -> $1800: debt/collateral = 1500/1800 = 83.3% > 80% threshold.
        wethFeed.setPrice(1800e8);

        vm.startPrank(liquidator);
        lending.liquidate(alice, address(usdc), address(weth), 500e6); // now liquidatable
        vm.stopPrank();
    }

    // ── F-7: internal cash accounting can't be inflated by a raw donation ──────

    function test_F7_donationDoesNotIncreaseAvailableCash() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000e6);
        lending.deposit(address(usdc), 1_000e6);
        vm.stopPrank();

        // Direct ERC20 donation, bypassing deposit() entirely.
        usdc.mint(address(this), 1_000_000e6);
        usdc.transfer(address(lending), 1_000_000e6);

        vm.startPrank(alice);
        weth.approve(address(lending), 100e18);
        lending.deposit(address(weth), 100e18); // $200,000 collateral — LTV is not the limiter here

        // availableCash is still only 1000 USDC despite the huge donated balanceOf.
        vm.expectRevert("Insufficient liquidity");
        lending.borrow(address(usdc), 1_001e6);

        // Borrowing within the real availableCash still works.
        lending.borrow(address(usdc), 1_000e6);
        vm.stopPrank();
    }

    // ── F-8: fee-on-transfer tokens credit/reduce based on what arrived ────────

    function test_F8_feeOnTransfer_depositCreditsReceivedAmount() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken("FeeUSD", "fUSD", 6, 1_000); // 10% fee
        lending.setPriceFeed(address(feeToken), address(usdcFeed), address(0), 0.5e18, 2e18, 0);
        lending.initReserve(address(feeToken), 7500, 8000);

        feeToken.mint(alice, 1_000e6);
        vm.startPrank(alice);
        feeToken.approve(address(lending), 1_000e6);
        lending.deposit(address(feeToken), 1_000e6); // nominal 1000, 10% fee -> ~900 received
        vm.stopPrank();

        uint256 credited = lending.getUserCollateral(alice, address(feeToken));
        assertApproxEqAbs(credited, 900e6, 1);
        assertLt(credited, 1_000e6, "shares must reflect what arrived, not the nominal amount");
    }

    function test_F8_feeOnTransfer_repayReducesDebtByReceivedAmount() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken("FeeUSD", "fUSD", 6, 1_000); // 10% fee
        lending.setPriceFeed(address(feeToken), address(usdcFeed), address(0), 0.5e18, 2e18, 0);
        lending.initReserve(address(feeToken), 8000, 8500);

        feeToken.mint(bob, 10_000e6);
        vm.startPrank(bob);
        feeToken.approve(address(lending), 10_000e6);
        lending.deposit(address(feeToken), 10_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(lending), 1e18);
        lending.deposit(address(weth), 1e18);
        lending.borrow(address(feeToken), 500e6);
        vm.stopPrank();

        uint256 debtBefore = lending.getUserBorrow(alice, address(feeToken));

        feeToken.mint(alice, 500e6);
        vm.startPrank(alice);
        feeToken.approve(address(lending), 500e6);
        lending.repay(address(feeToken), 500e6); // only ~450 actually arrives
        vm.stopPrank();

        uint256 debtAfter = lending.getUserBorrow(alice, address(feeToken));
        assertApproxEqAbs(debtBefore - debtAfter, 450e6, 2);
        assertLt(debtBefore - debtAfter, 500e6, "debt must drop by what arrived, not the nominal repay amount");
    }

    function test_F8_feeOnTransfer_liquidateUsesReceivedAmount() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken("FeeUSD", "fUSD", 6, 1_000); // 10% fee
        lending.setPriceFeed(address(feeToken), address(usdcFeed), address(0), 0.5e18, 2e18, 0);
        lending.initReserve(address(feeToken), 8000, 8500);

        feeToken.mint(bob, 100_000e6);
        vm.startPrank(bob);
        feeToken.approve(address(lending), 100_000e6);
        lending.deposit(address(feeToken), 100_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(lending), 1e18);
        lending.deposit(address(weth), 1e18);
        lending.borrow(address(feeToken), 1_400e6); // 70% of $2000, within 75% LTV
        vm.stopPrank();

        wethFeed.setPrice(1000e8); // crash to make alice liquidatable

        uint256 debtBefore = lending.getUserBorrow(alice, address(feeToken));

        feeToken.mint(liquidator, 1_000e6);
        vm.startPrank(liquidator);
        feeToken.approve(address(lending), 500e6);
        lending.liquidate(alice, address(feeToken), address(weth), 500e6); // nominal 500, ~450 arrives
        vm.stopPrank();

        uint256 debtAfter = lending.getUserBorrow(alice, address(feeToken));
        assertApproxEqAbs(debtBefore - debtAfter, 450e6, 2);
        assertLt(debtBefore - debtAfter, 500e6, "seizure/repay must be sized on what arrived, not nominal");
    }

    // ── F-9: a stale/unused reserve's feed must not block other markets ────────

    function test_F9_staleUnusedReserveFeedDoesNotBlockOtherMarkets() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 100_000e6);
        lending.deposit(address(usdc), 100_000e6);
        vm.stopPrank();

        MockToken dead = new MockToken("Dead", "DEAD", 18);
        MockPriceFeed deadFeed = new MockPriceFeed(int256(10e8));
        lending.setPriceFeed(address(dead), address(deadFeed), address(0), 1e18, 1000e18, 0);
        lending.initReserve(address(dead), 5000, 6000);

        uint256 tsAtRegistration = block.timestamp;
        deadFeed.setUpdatedAt(tsAtRegistration);
        vm.warp(tsAtRegistration + 2 hours); // > PRICE_STALENESS_THRESHOLD (1h)

        vm.expectRevert("Stale price");
        lending.getAssetPrice(address(dead)); // sanity: the feed really is broken

        // Alice has zero exposure to `dead` — deposit/borrow must be unaffected.
        vm.startPrank(alice);
        weth.approve(address(lending), 1e18);
        lending.deposit(address(weth), 1e18);
        lending.borrow(address(usdc), 500e6);
        vm.stopPrank();

        (, , , , uint256 hf) = lending.calculateUserAccountData(alice);
        assertGt(hf, 0);

        // Crash WETH hard enough to be liquidatable, then confirm the stale
        // unrelated feed does not block liquidate() either.
        wethFeed.setPrice(400e8);

        vm.startPrank(liquidator);
        usdc.approve(address(lending), 300e6);
        lending.liquidate(alice, address(usdc), address(weth), 300e6);
        vm.stopPrank();
    }

    // ── F-11: flash-loan premium is accounted for (suppliers + protocol) ───────

    function test_F11_flashLoanCreditsSuppliersAndProtocolFees() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 100_000e6);
        lending.deposit(address(usdc), 100_000e6);
        vm.stopPrank();

        GoodFlashReceiver receiver = new GoodFlashReceiver();
        usdc.mint(address(receiver), 1_000e6);

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes = new uint256[](1);
        assets[0] = address(usdc);
        amounts[0] = 10_000e6;

        (
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 supplyIndexBefore,
            ,
            ,

        ) = lending.reserves(address(usdc));

        lending.flashLoan(address(receiver), assets, amounts, modes, address(0), "", 0);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 supplyIndexAfter,
            ,
            ,

        ) = lending.reserves(address(usdc));

        assertGt(supplyIndexAfter, supplyIndexBefore, "supplyIndex must grow from the flash-loan premium");

        uint256 premium = (amounts[0] * lending.FLASHLOAN_FEE_BPS()) / lending.BPS_DIVISOR();
        uint256 expectedProtocolCut = (premium * lending.RESERVE_FACTOR_BPS()) / lending.BPS_DIVISOR();
        assertEq(lending.protocolFees(address(usdc)), expectedProtocolCut);

        address treasury = makeAddr("treasury");
        lending.withdrawProtocolFees(address(usdc), treasury);
        assertEq(usdc.balanceOf(treasury), expectedProtocolCut);
        assertEq(lending.protocolFees(address(usdc)), 0);
    }

    /// The cash ledger must be CONSERVED across a flash loan: the principal
    /// left and came back, so availableCash must end at exactly
    /// (before + premium). The initial rewrite credited only the net balance
    /// gain (premium) while having debited the full principal — leaking
    /// `amount - premium` of internal cash per flash loan until borrow/
    /// withdraw DoS'd on "Insufficient liquidity" with the tokens still in
    /// the contract.
    function test_F11_flashLoanConservesAvailableCash() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 100_000e6);
        lending.deposit(address(usdc), 100_000e6);
        vm.stopPrank();

        GoodFlashReceiver receiver = new GoodFlashReceiver();
        usdc.mint(address(receiver), 1_000e6);

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes = new uint256[](1);
        assets[0] = address(usdc);
        amounts[0] = 10_000e6;

        (, , , uint256 cashBefore, , , , , , ) = lending.reserves(address(usdc));

        lending.flashLoan(address(receiver), assets, amounts, modes, address(0), "", 0);

        (, , , uint256 cashAfter, , , , , , ) = lending.reserves(address(usdc));
        uint256 premium = (amounts[0] * lending.FLASHLOAN_FEE_BPS()) / lending.BPS_DIVISOR();
        assertEq(cashAfter, cashBefore + premium, "availableCash must be conserved (+premium) across a flash loan");

        // User-visible symptom of the leak: the sole supplier could no longer
        // exit in full even though every token is physically in the contract.
        uint256 bobBalance = lending.getUserCollateral(bob, address(usdc));
        vm.prank(bob);
        lending.withdraw(address(usdc), bobBalance);
    }

    // ── F-18: duplicate assets in one flashLoan call must revert ───────────────

    function test_F18_flashLoan_duplicateAsset_reverts() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 100_000e6);
        lending.deposit(address(usdc), 100_000e6);
        vm.stopPrank();

        GoodFlashReceiver receiver = new GoodFlashReceiver();
        usdc.mint(address(receiver), 1_000e6);

        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        uint256[] memory modes = new uint256[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdc);
        amounts[0] = 1_000e6;
        amounts[1] = 1_000e6;

        vm.expectRevert(abi.encodeWithSelector(MagnetaLending.DuplicateFlashLoanAsset.selector, address(usdc)));
        lending.flashLoan(address(receiver), assets, amounts, modes, address(0), "", 0);
    }

    // ── F-19: initReserve guardrails + reserve governance ───────────────────────

    function test_F19_initReserve_invalidRiskParams_reverts() public {
        MockToken tok = new MockToken("T", "T", 18);
        MockPriceFeed feed = new MockPriceFeed(int256(1e8));
        lending.setPriceFeed(address(tok), address(feed), address(0), 0.5e18, 2e18, 0);

        vm.expectRevert("Invalid risk params");
        lending.initReserve(address(tok), 9000, 8000); // ltv > threshold

        vm.expectRevert("Invalid risk params");
        lending.initReserve(address(tok), 5000, 10_001); // threshold > BPS_DIVISOR

        vm.expectRevert("Invalid risk params");
        lending.initReserve(address(tok), 0, 8000); // ltv == 0
    }

    function test_F19_initReserve_noFeed_reverts() public {
        MockToken tok = new MockToken("T2", "T2", 18);
        vm.expectRevert("Price feed not set");
        lending.initReserve(address(tok), 7500, 8000);
    }

    function test_F19_setReserveActive_blocksDepositNotWithdraw() public {
        vm.startPrank(alice);
        usdc.approve(address(lending), 1_000e6);
        lending.deposit(address(usdc), 1_000e6);
        vm.stopPrank();

        lending.setReserveActive(address(usdc), false);

        vm.startPrank(alice);
        usdc.approve(address(lending), 100e6);
        vm.expectRevert("Reserve not active");
        lending.deposit(address(usdc), 100e6);

        // Exiting a disabled reserve must always be possible.
        lending.withdraw(address(usdc), 500e6);
        vm.stopPrank();
    }

    function test_F19_setReserveParams_updatesBoundsAndValidates() public {
        lending.setReserveParams(address(usdc), 6000, 7000);
        (
            ,
            ,
            ,
            ,
            uint256 ltv,
            uint256 threshold,
            ,
            ,
            ,

        ) = lending.reserves(address(usdc));
        assertEq(ltv, 6000);
        assertEq(threshold, 7000);

        vm.expectRevert("Invalid risk params");
        lending.setReserveParams(address(usdc), 8000, 7000); // ltv > threshold

        MockToken tok = new MockToken("Uninit", "UNI", 18);
        vm.expectRevert("Reserve not initialized");
        lending.setReserveParams(address(tok), 5000, 6000);
    }

    // ── F-22: rounding is protocol-favoring; dust that mints 0 shares reverts ──

    function test_F22_dustDepositAfterIndexGrowth_reverts() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 1_000_000e6);
        lending.deposit(address(usdc), 1_000_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(lending), 500e18);
        lending.deposit(address(weth), 500e18); // $1,000,000 collateral
        lending.borrow(address(usdc), 750_000e6); // 75% LTV, high utilization
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // Force an index update (any state-changing call routes through
        // _updateReserve); zero-amount so no approval is needed.
        vm.prank(alice);
        lending.repay(address(usdc), 0);

        usdc.mint(address(this), 1);
        usdc.approve(address(lending), 1);
        vm.expectRevert("Deposit amount too small");
        lending.deposit(address(usdc), 1);
    }
}
