// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaLending.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract MockToken is ERC20 {
    uint8 private _dec;
    constructor(string memory name, string memory symbol, uint8 dec) ERC20(name, symbol) {
        _dec = dec;
        _mint(msg.sender, 1_000_000 * 10 ** dec);
    }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockPriceFeed {
    int256 public price;
    constructor(int256 _price) { price = _price; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
    function setPrice(int256 _price) external { price = _price; }
}

/// @dev Flash loan receiver that repays correctly
contract GoodFlashReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata
    ) external returns (bool) {
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 repay = amounts[i] + premiums[i];
            IERC20(assets[i]).transfer(msg.sender, repay);
        }
        return true;
    }
}

/// @dev Flash loan receiver that does NOT repay
contract BadFlashReceiver {
    function executeOperation(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        address,
        bytes calldata
    ) external pure returns (bool) {
        return true; // returns true but never repays
    }
}

// ─── Test Suite ───────────────────────────────────────────────────────────────

contract MagnetaLendingTest is Test {
    MagnetaLending lending;
    MockToken usdc;
    MockToken weth;
    MockPriceFeed usdcFeed;
    MockPriceFeed wethFeed;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address liquidator = makeAddr("liquidator");

    uint256 constant USDC_PRICE = 1e8;       // $1.00 (8 decimals, Chainlink format)
    uint256 constant WETH_PRICE = 2000e8;    // $2000.00

    function setUp() public {
        lending  = new MagnetaLending();
        usdc     = new MockToken("USD Coin", "USDC", 6);
        weth     = new MockToken("Wrapped ETH", "WETH", 18);
        usdcFeed = new MockPriceFeed(int256(USDC_PRICE));
        wethFeed = new MockPriceFeed(int256(WETH_PRICE));

        // Init reserves
        lending.initReserve(address(usdc), 8000, 8500); // 80% LTV, 85% liq threshold
        lending.initReserve(address(weth), 7500, 8000); // 75% LTV, 80% liq threshold

        // Set price feeds
        lending.setPriceFeed(address(usdc), address(usdcFeed));
        lending.setPriceFeed(address(weth), address(wethFeed));

        // Fund users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(liquidator, 100_000e6);
        weth.mint(alice, 100e18);
        weth.mint(bob, 100e18);
    }

    // ── initReserve ───────────────────────────────────────────────────────────

    function test_initReserve_onlyOwner() public {
        MockToken tok = new MockToken("T", "T", 18);
        vm.prank(alice);
        vm.expectRevert();
        lending.initReserve(address(tok), 7000, 8000);
    }

    function test_initReserve_cannotInitTwice() public {
        vm.expectRevert("Reserve already active");
        lending.initReserve(address(usdc), 8000, 8500);
    }

    // ── setPriceFeed ──────────────────────────────────────────────────────────

    function test_setPriceFeed_zeroAsset_reverts() public {
        vm.expectRevert("Invalid asset");
        lending.setPriceFeed(address(0), address(usdcFeed));
    }

    function test_setPriceFeed_zeroFeed_reverts() public {
        vm.expectRevert("Invalid feed");
        lending.setPriceFeed(address(usdc), address(0));
    }

    // ── deposit ───────────────────────────────────────────────────────────────

    function test_deposit_basic() public {
        uint256 amount = 1000e6;
        vm.startPrank(alice);
        usdc.approve(address(lending), amount);
        lending.deposit(address(usdc), amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(lending)), amount);
        assertGt(lending.getUserCollateral(alice, address(usdc)), 0);
    }

    function test_deposit_zeroAmount_reverts() public {
        vm.prank(alice);
        vm.expectRevert("Amount must be > 0");
        lending.deposit(address(usdc), 0);
    }

    function test_deposit_inactiveReserve_reverts() public {
        MockToken tok = new MockToken("T", "T", 18);
        vm.prank(alice);
        vm.expectRevert("Reserve not active");
        lending.deposit(address(tok), 1e18);
    }

    function testFuzz_deposit_shares(uint256 amount) public {
        amount = bound(amount, 1e6, 50_000e6);
        vm.startPrank(alice);
        usdc.approve(address(lending), amount);
        lending.deposit(address(usdc), amount);
        vm.stopPrank();

        uint256 collateral = lending.getUserCollateral(alice, address(usdc));
        assertApproxEqAbs(collateral, amount, 1); // shares round-trip ≈ amount at index=1
    }

    // ── withdraw ──────────────────────────────────────────────────────────────

    function test_withdraw_full() public {
        uint256 amount = 1000e6;
        vm.startPrank(alice);
        usdc.approve(address(lending), amount);
        lending.deposit(address(usdc), amount);

        uint256 balBefore = usdc.balanceOf(alice);
        lending.withdraw(address(usdc), amount);
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(alice), balBefore + amount, 1);
        assertEq(lending.getUserCollateral(alice, address(usdc)), 0);
    }

    function test_withdraw_moreThanDeposited_reverts() public {
        uint256 amount = 1000e6;
        vm.startPrank(alice);
        usdc.approve(address(lending), amount);
        lending.deposit(address(usdc), amount);

        vm.expectRevert("Insufficient balance");
        lending.withdraw(address(usdc), amount + 1);
        vm.stopPrank();
    }

    function test_withdraw_withDebt_healthFactorCheck() public {
        // Alice deposits WETH as collateral, borrows USDC
        uint256 wethDeposit = 1e18; // 1 WETH = $2000
        uint256 usdcBorrow  = 1000e6; // $1000 borrowed (50% LTV)

        // Seed lending with USDC liquidity
        vm.startPrank(bob);
        usdc.approve(address(lending), 50_000e6);
        lending.deposit(address(usdc), 50_000e6);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(lending), wethDeposit);
        lending.deposit(address(weth), wethDeposit);
        lending.borrow(address(usdc), usdcBorrow);

        // Try to withdraw all WETH → health factor would drop below 1
        vm.expectRevert("Health factor too low after withdrawal");
        lending.withdraw(address(weth), wethDeposit);
        vm.stopPrank();
    }

    // ── borrow ────────────────────────────────────────────────────────────────

    function test_borrow_basic() public {
        // Bob supplies USDC liquidity
        vm.startPrank(bob);
        usdc.approve(address(lending), 50_000e6);
        lending.deposit(address(usdc), 50_000e6);
        vm.stopPrank();

        // Alice deposits WETH and borrows USDC
        uint256 wethDeposit = 1e18; // $2000 collateral
        uint256 usdcBorrow  = 1000e6; // $1000 borrow (50% LTV, limit is 75%)

        vm.startPrank(alice);
        weth.approve(address(lending), wethDeposit);
        lending.deposit(address(weth), wethDeposit);
        lending.borrow(address(usdc), usdcBorrow);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 100_000e6 + usdcBorrow);
        assertGt(lending.getUserBorrow(alice, address(usdc)), 0);
    }

    function test_borrow_exceedsLTV_reverts() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 50_000e6);
        lending.deposit(address(usdc), 50_000e6);
        vm.stopPrank();

        uint256 wethDeposit = 1e18; // $2000 collateral
        // 75% LTV = max $1500, try to borrow $1800
        uint256 usdcBorrow = 1800e6;

        vm.startPrank(alice);
        weth.approve(address(lending), wethDeposit);
        lending.deposit(address(weth), wethDeposit);
        vm.expectRevert("Health factor too low to borrow");
        lending.borrow(address(usdc), usdcBorrow);
        vm.stopPrank();
    }

    // ── repay ─────────────────────────────────────────────────────────────────

    function test_repay_partial() public {
        _setupBorrow(alice, 1e18, 500e6);

        vm.startPrank(alice);
        usdc.approve(address(lending), 250e6);
        lending.repay(address(usdc), 250e6);
        vm.stopPrank();

        uint256 debt = lending.getUserBorrow(alice, address(usdc));
        assertApproxEqAbs(debt, 250e6, 1e4); // small rounding tolerance
    }

    function test_repay_full_via_maxUint() public {
        _setupBorrow(alice, 1e18, 500e6);

        uint256 debt = lending.getUserBorrow(alice, address(usdc));

        vm.startPrank(alice);
        usdc.approve(address(lending), debt);
        lending.repay(address(usdc), type(uint256).max);
        vm.stopPrank();

        assertEq(lending.getUserBorrow(alice, address(usdc)), 0);
    }

    function test_repay_moreThanDebt_reverts() public {
        _setupBorrow(alice, 1e18, 500e6);

        vm.startPrank(alice);
        usdc.approve(address(lending), 10_000e6);
        vm.expectRevert("Repay amount exceeds debt");
        lending.repay(address(usdc), 10_000e6);
        vm.stopPrank();
    }

    // ── flashLoan ─────────────────────────────────────────────────────────────

    function test_flashLoan_successfulRepayment() public {
        // Seed lending with USDC
        vm.startPrank(bob);
        usdc.approve(address(lending), 10_000e6);
        lending.deposit(address(usdc), 10_000e6);
        vm.stopPrank();

        GoodFlashReceiver receiver = new GoodFlashReceiver();
        usdc.mint(address(receiver), 1000e6); // fund receiver with enough for premium

        address[] memory assets  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes   = new uint256[](1);
        assets[0]  = address(usdc);
        amounts[0] = 1000e6;

        uint256 balBefore = usdc.balanceOf(address(lending));
        lending.flashLoan(address(receiver), assets, amounts, modes, address(0), "", 0);
        uint256 balAfter = usdc.balanceOf(address(lending));

        assertGt(balAfter, balBefore); // balance increased by fee
    }

    function test_flashLoan_notRepaid_reverts() public {
        vm.startPrank(bob);
        usdc.approve(address(lending), 10_000e6);
        lending.deposit(address(usdc), 10_000e6);
        vm.stopPrank();

        BadFlashReceiver receiver = new BadFlashReceiver();

        address[] memory assets  = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory modes   = new uint256[](1);
        assets[0]  = address(usdc);
        amounts[0] = 1000e6;

        vm.expectRevert("Flash loan not repaid");
        lending.flashLoan(address(receiver), assets, amounts, modes, address(0), "", 0);
    }

    function test_flashLoan_arrayMismatch_reverts() public {
        address[] memory assets  = new address[](1);
        uint256[] memory amounts = new uint256[](2); // mismatch

        vm.expectRevert("Array length mismatch");
        lending.flashLoan(address(0x1), assets, amounts, new uint256[](2), address(0), "", 0);
    }

    // ── liquidate ─────────────────────────────────────────────────────────────

    function test_liquidate_healthyUser_reverts() public {
        _setupBorrow(alice, 1e18, 500e6); // safe borrow

        vm.startPrank(liquidator);
        usdc.approve(address(lending), 500e6);
        vm.expectRevert("User is healthy");
        lending.liquidate(alice, address(usdc), address(weth), 500e6);
        vm.stopPrank();
    }

    function test_liquidate_unhealthyUser_succeeds() public {
        // Alice deposits 1 WETH ($2000), borrows $1400 USDC (70% LTV, limit 75% → still healthy)
        _setupBorrow(alice, 1e18, 1400e6);

        // WETH price crashes to $1000 → health factor drops below 1
        wethFeed.setPrice(1000e8);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.startPrank(liquidator);
        usdc.approve(address(lending), 500e6);
        lending.liquidate(alice, address(usdc), address(weth), 500e6);
        vm.stopPrank();

        assertGt(weth.balanceOf(liquidator), liquidatorWethBefore);
    }

    // ── pause ─────────────────────────────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        lending.pause();
        vm.startPrank(alice);
        usdc.approve(address(lending), 1000e6);
        vm.expectRevert("Pausable: paused");
        lending.deposit(address(usdc), 1000e6);
        vm.stopPrank();
    }

    function test_unpause_allowsDeposit() public {
        lending.pause();
        lending.unpause();

        vm.startPrank(alice);
        usdc.approve(address(lending), 1000e6);
        lending.deposit(address(usdc), 1000e6);
        vm.stopPrank();

        assertGt(lending.getUserCollateral(alice, address(usdc)), 0);
    }

    // ── interest accrual ──────────────────────────────────────────────────────

    function test_interestAccrues_overTime() public {
        _setupBorrow(alice, 1e18, 500e6);

        uint256 debtBefore = lending.getUserBorrow(alice, address(usdc));

        // Warp 30 days
        vm.warp(block.timestamp + 30 days);

        // Trigger reserve update via a 1-unit repay (getUserBorrow is a view; index
        // only updates on state-changing calls that invoke _updateReserve internally)
        vm.prank(alice);
        lending.repay(address(usdc), 1);

        uint256 debtAfter = lending.getUserBorrow(alice, address(usdc));
        // debt after repaying 1 wei = original + accrued_interest - 1; interest >> 1
        assertGt(debtAfter, debtBefore - 1, "Debt should increase with interest");
    }

    // ── ownable2step ──────────────────────────────────────────────────────────

    function test_ownable2step_transferRequiresAccept() public {
        lending.transferOwnership(alice);
        assertEq(lending.owner(), address(this)); // not transferred yet

        vm.prank(alice);
        lending.acceptOwnership();
        assertEq(lending.owner(), alice);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    function _setupBorrow(address user, uint256 wethAmount, uint256 usdcAmount) internal {
        // Bob provides USDC liquidity
        vm.startPrank(bob);
        usdc.approve(address(lending), 50_000e6);
        lending.deposit(address(usdc), 50_000e6);
        vm.stopPrank();

        // User deposits WETH and borrows USDC
        vm.startPrank(user);
        weth.approve(address(lending), wethAmount);
        lending.deposit(address(weth), wethAmount);
        lending.borrow(address(usdc), usdcAmount);
        usdc.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }
}
