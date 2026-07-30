// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaLending.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LendToken is ERC20 {
    constructor(string memory n) ERC20(n, n) { _mint(msg.sender, 1e30); }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev Chainlink-shaped feed with a settable price, so the campaign can move
///      the market underneath open positions — which is the only way a health
///      factor ever legitimately falls below 1.
contract LendFeed {
    int256 public price;
    constructor(int256 p) { price = p; }
    function decimals() external pure returns (uint8) { return 8; }
    function setPrice(int256 p) external { price = p; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

contract LendUser {}

contract LendHandler is Test {
    MagnetaLending public immutable pool;
    LendToken public immutable usdc;
    LendToken public immutable weth;
    LendFeed public immutable wethFeed;
    LendUser public immutable borrower;

    uint256 public ghost_deposits;
    uint256 public ghost_borrows;
    /// Ghost: an operation left the caller below the liquidation threshold and
    /// was still accepted. Must stay 0 — borrow and withdraw both assert it.
    uint256 public ghost_leftUnhealthy;
    /// Ghost: a liquidation of a HEALTHY position was accepted. Must stay 0 —
    /// that is seizing collateral from someone who owes nothing overdue.
    uint256 public ghost_healthyLiquidated;

    constructor(MagnetaLending _pool, LendToken _usdc, LendToken _weth, LendFeed _feed, LendUser _borrower) {
        pool = _pool; usdc = _usdc; weth = _weth; wethFeed = _feed; borrower = _borrower;
    }

    function _hf(address who) internal view returns (uint256 hf) {
        (, , , , hf) = pool.calculateUserAccountData(who);
    }

    function depositWeth(uint256 amount) external {
        amount = bound(amount, 1e15, 100e18);
        if (weth.balanceOf(address(this)) < amount) return;
        weth.approve(address(pool), amount);
        pool.deposit(address(weth), amount);
        ghost_deposits += 1;
    }

    function depositUsdc(uint256 amount) external {
        amount = bound(amount, 1e6, 1_000_000e6);
        if (usdc.balanceOf(address(this)) < amount) return;
        usdc.approve(address(pool), amount);
        pool.deposit(address(usdc), amount);
        ghost_deposits += 1;
    }

    function borrowUsdc(uint256 amount) external {
        amount = bound(amount, 1e6, 500_000e6);
        try pool.borrow(address(usdc), amount) {
            ghost_borrows += 1;
            // borrow() asserts HF >= 1e18 before paying out; if it accepted a
            // position that is already liquidatable, the guard did nothing.
            if (_hf(address(this)) < 1e18) ghost_leftUnhealthy += 1;
        } catch { }
    }

    function withdrawWeth(uint256 amount) external {
        amount = bound(amount, 1e15, 100e18);
        try pool.withdraw(address(weth), amount) {
            if (_hf(address(this)) < 1e18) ghost_leftUnhealthy += 1;
        } catch { }
    }

    function repayUsdc(uint256 amount) external {
        amount = bound(amount, 1e6, 500_000e6);
        if (usdc.balanceOf(address(this)) < amount) return;
        usdc.approve(address(pool), amount);
        try pool.repay(address(usdc), amount) { } catch { }
    }

    /// Move the market. The only legitimate route to an unhealthy position.
    function movePrice(uint256 p) external {
        wethFeed.setPrice(int256(bound(p, 200e8, 5_000e8)));
        try pool.refreshPrice(address(weth)) { } catch { }
    }

    /// Adversarial: liquidate a position that is NOT underwater.
    function liquidateHealthy(uint256 amount) external {
        uint256 hf = _hf(address(this));
        if (hf < 1e18) return;                 // genuinely liquidatable, skip
        amount = bound(amount, 1e6, 10_000e6);
        if (usdc.balanceOf(address(this)) < amount) return;
        usdc.approve(address(pool), amount);
        try pool.liquidate(address(this), address(usdc), address(weth), amount) {
            ghost_healthyLiquidated += 1;
        } catch {
            // expected
        }
    }
}

/// @notice Invariants for MagnetaLending — the contract that holds depositors'
///         funds and lends them out against collateral.
///
///         L-1  The pool never lends out more than it took in: for every
///              reserve, `balance + totalBorrowed >= totalSupplied`. Break this
///              and the last depositors cannot withdraw — a bank run.
///         L-2  No accepted borrow or withdraw leaves the caller below the
///              liquidation threshold. Both functions assert it; this checks
///              the assertion actually bites.
///         L-3  A healthy position can never be liquidated. Accepting one means
///              seizing collateral at a 5 % discount from someone who is not in
///              default.
contract LendingInvariantTest is Test {
    MagnetaLending pool;
    LendToken usdc;
    LendToken weth;
    LendFeed usdcFeed;
    LendFeed wethFeed;
    LendUser borrower;
    LendHandler handler;

    function setUp() public {
        pool = new MagnetaLending();
        usdc = new LendToken("USDC");
        weth = new LendToken("WETH");

        usdcFeed = new LendFeed(1e8);        // $1
        wethFeed = new LendFeed(2_000e8);    // $2000

        // F-19: initReserve now requires a price feed to already be configured.
        pool.setPriceFeed(address(usdc), address(usdcFeed), address(0), 0.5e18, 2e18, 0);
        pool.setPriceFeed(address(weth), address(wethFeed), address(0), 100e18, 10_000e18, 0);
        pool.initReserve(address(usdc), 8000, 8500);
        pool.initReserve(address(weth), 7500, 8000);

        borrower = new LendUser();
        handler  = new LendHandler(pool, usdc, weth, wethFeed, borrower);

        // Seed the handler so it can supply, and seed the pool with USDC
        // liquidity so borrows are not refused for want of funds — an
        // adversarial action that always fails on liquidity proves nothing
        // about the health-factor guard.
        usdc.mint(address(handler), 5_000_000e6);
        weth.mint(address(handler), 10_000e18);
        usdc.mint(address(this), 5_000_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(address(usdc), 2_000_000e6);

        targetContract(address(handler));
    }

    /// L-1
    function invariant_PoolNeverLendsOutMoreThanItHolds() public view {
        address[2] memory assets = [address(usdc), address(weth)];
        for (uint256 i = 0; i < assets.length; i++) {
            // Totals are now derived from shares × index (F-2) rather than a
            // nominal accumulator — read via the public views instead of the
            // reserves() tuple, whose layout changed.
            uint256 totalSupplied = pool.getTotalSupplied(assets[i]);
            uint256 totalBorrowed = pool.getTotalBorrowed(assets[i]);
            assertGe(
                IERC20(assets[i]).balanceOf(address(pool)) + totalBorrowed,
                totalSupplied,
                "reserve holds less than it owes depositors"
            );
        }
    }

    /// L-2
    function invariant_NoOperationLeavesTheCallerUnderwater() public view {
        assertEq(handler.ghost_leftUnhealthy(), 0, "a borrow or withdraw left the caller below HF 1");
    }

    /// L-3
    function invariant_HealthyPositionsAreNeverLiquidated() public view {
        assertEq(handler.ghost_healthyLiquidated(), 0, "a healthy position was liquidated");
    }
}

/// @notice Guards against a campaign that never reaches the pool.
contract LendingReachabilityTest is LendingInvariantTest {
    function test_DepositThenBorrowThenRepay() public {
        LendToken w = weth;
        w.mint(address(this), 10e18);
        w.approve(address(pool), type(uint256).max);

        // NOT wrapped in try/catch — a revert must fail this test.
        pool.deposit(address(w), 10e18);            // $20 000 collateral
        pool.borrow(address(usdc), 5_000e6);        // well within a 75 % LTV

        (, , , , uint256 hf) = pool.calculateUserAccountData(address(this));
        assertGe(hf, 1e18, "position is underwater right after a conservative borrow");

        usdc.approve(address(pool), type(uint256).max);
        pool.repay(address(usdc), 1_000e6);
    }
}
