// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/curve/MagnetaCurvePool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CurveToken is ERC20 {
    constructor(uint256 supply) ERC20("Curve", "CRV") { _mint(msg.sender, supply); }
}

/// @dev The pool only touches the router at construction (`WETH()`) and during
///      finalizeGraduation. Trading needs nothing else, so a stub keeps the
///      campaign on the curve maths instead of on a DEX mock.
contract RouterWethStub {
    address public immutable weth;
    constructor(address _weth) { weth = _weth; }
    function WETH() external view returns (address) { return weth; }
    function factory() external view returns (address) { return address(this); }
    function getPair(address, address) external pure returns (address) { return address(0); }
}

contract FeeSink { receive() external payable {} }

/// @dev A trader that holds tokens and can sell them back.
contract Trader {
    receive() external payable {}
    function approveTo(IERC20 t, address who) external { t.approve(who, type(uint256).max); }
    function doSell(MagnetaCurvePool p, uint256 amt) external returns (uint256) {
        return p.sell(amt, 0);
    }
}

contract CurveHandler is Test {
    MagnetaCurvePool public immutable pool;
    IERC20 public immutable token;
    Trader public immutable trader;
    address public immutable feeVault;

    uint256 public ghost_buys;
    uint256 public ghost_sells;
    /// Ghost: total native the handler ever paid into buy(). Fees leave the
    /// contract immediately, so this is not the pool balance — it is the input
    /// side of the fee accounting.
    uint256 public ghost_nativeIn;
    /// Ghost: a trade dropped k by MORE than one rounding step. Must stay 0.
    ///
    /// k is NOT strictly non-decreasing here, contrary to the Uniswap
    /// convention. quoteBuy computes `newR1 = (r0 * r1) / newR0` with integer
    /// division, so `tokensOut = r1 - newR1` rounds UP — in the buyer's favour,
    /// not the pool's. Measured on a 1 ETH buy: k fell by 3.63e18 out of 4e45,
    /// a relative 9e-28. The loss is bounded by one step of the divisor, i.e.
    /// by nativeReserve(), so that is what the invariant enforces: dust is
    /// tolerated, anything larger is a real leak.
    uint256 public ghost_kDroppedBeyondRounding;
    /// Ghost: largest single-trade k drop observed, so the bound is visible
    /// rather than merely asserted.
    uint256 public ghost_maxKDrop;
    /// Ghost: totalNativeBought went down. Must stay 0 — it is the monotonic
    /// graduation gate (F84); a sell lowers nativeRaised but must NOT lower it,
    /// otherwise the threshold could be crossed, un-crossed and re-crossed.
    uint256 public ghost_gateWentBackwards;
    /// Ghost: a trade succeeded after graduation. Must stay 0.
    uint256 public ghost_tradedAfterGraduation;

    uint256 private lastGate;

    constructor(MagnetaCurvePool _pool, IERC20 _token, Trader _trader, address _feeVault) {
        pool = _pool; token = _token; trader = _trader; feeVault = _feeVault;
    }

    function _k() internal view returns (uint256) {
        return pool.nativeReserve() * pool.tokenReserve();
    }

    function _postChecks(uint256 kBefore, bool wasGraduated, bool isBuy) internal {
        uint256 kAfter = _k();
        if (kAfter < kBefore) {
            uint256 drop = kBefore - kAfter;
            if (drop > ghost_maxKDrop) ghost_maxKDrop = drop;
            // The bound is ONE STEP OF THE DIVISOR, and the two directions do
            // not divide by the same thing: quoteBuy divides by newR0 (the
            // native reserve), quoteSell by newR1 (the token reserve, ~8e26
            // here). Bounding a sell by the native reserve was wrong and the
            // campaign said so immediately.
            uint256 bound = isBuy ? pool.nativeReserve() : pool.tokenReserve();
            if (drop > bound) ghost_kDroppedBeyondRounding += 1;
        }
        if (pool.totalNativeBought() < lastGate) ghost_gateWentBackwards += 1;
        lastGate = pool.totalNativeBought();
        if (wasGraduated) ghost_tradedAfterGraduation += 1;
    }

    function buy(uint256 nativeIn) external {
        nativeIn = bound(nativeIn, 1e12, 3 ether);
        uint256 kBefore = _k();
        bool wasGraduated = pool.graduated();

        vm.deal(address(this), nativeIn);
        try pool.buy{value: nativeIn}(0) returns (uint256 out) {
            ghost_buys += 1;
            ghost_nativeIn += nativeIn;
            // Park the tokens on the trader so sells have inventory.
            token.transfer(address(trader), out);
            _postChecks(kBefore, wasGraduated, true);
        } catch {
            // Legitimate refusals: graduated, or not enough tokens left.
        }
    }

    function sell(uint256 tokensIn) external {
        uint256 bal = token.balanceOf(address(trader));
        if (bal == 0) return;
        tokensIn = bound(tokensIn, 1, bal);
        uint256 kBefore = _k();
        bool wasGraduated = pool.graduated();

        try trader.doSell(pool, tokensIn) {
            ghost_sells += 1;
            _postChecks(kBefore, wasGraduated, false);
        } catch {
            // Legitimate refusal: the curve has not raised enough native yet.
        }
    }

    /// Anyone may close the curve once the gate is reached.
    function graduate() external {
        try pool.graduate() { } catch { }
    }

    receive() external payable {}
}

/// @notice Invariants for the bonding-curve pool — the launchpad contract that
///         holds user money directly while a token is still on its curve.
///
///         C-1  SOLVENCY. The pool's native balance always covers nativeRaised,
///              which is exactly what it owes to sellers. If this ever breaks,
///              the last sellers cannot be paid — a bank run on a launchpad.
///         C-2  The constant product never loses more than one rounding step
///              per trade. Integer division in quoteBuy rounds the output UP,
///              i.e. in the buyer's favour, so k is not strictly monotonic the
///              way Uniswap's is — it drifts down by dust (9e-28 relative on a
///              1 ETH buy). Bounding that drift by nativeReserve() still
///              catches any real value leak through the pricing maths.
///         C-3  tokensSold never exceeds the curve allocation, so tokenReserve()
///              cannot underflow and the curve cannot sell tokens it does not
///              hold.
///         C-4  totalNativeBought is monotonic (the F84 graduation gate) and no
///              trade is ever accepted after graduation.
///         C-5  Token conservation: what the pool still holds plus what it has
///              sold equals the allocation it started with.
contract CurvePoolInvariantTest is Test {
    MagnetaCurvePool pool;
    CurveToken token;
    RouterWethStub router;
    FeeSink feeVault;
    Trader trader;
    CurveHandler handler;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 constant ALLOCATION   =   800_000_000e18;
    uint256 constant V_NATIVE     = 5 ether;
    uint256 constant THRESHOLD    = 20 ether;

    function setUp() public {
        token    = new CurveToken(TOTAL_SUPPLY);
        router   = new RouterWethStub(makeAddr("weth"));
        feeVault = new FeeSink();
        trader   = new Trader();

        pool = new MagnetaCurvePool(
            address(token), address(router), address(feeVault),
            TOTAL_SUPPLY, ALLOCATION, V_NATIVE, THRESHOLD
        );

        // Seed the curve with its allocation, as the factory does.
        token.transfer(address(pool), ALLOCATION);

        handler = new CurveHandler(pool, IERC20(address(token)), trader, address(feeVault));
        trader.approveTo(IERC20(address(token)), address(pool));

        targetContract(address(handler));
    }

    /// C-1 — the property that matters most: sellers can always be paid.
    function invariant_PoolIsSolvent() public view {
        assertGe(
            address(pool).balance,
            pool.nativeRaised(),
            "curve pool holds less native than it owes to sellers"
        );
    }

    /// C-2
    function invariant_ConstantProductOnlyLosesRoundingDust() public view {
        assertEq(
            handler.ghost_kDroppedBeyondRounding(), 0,
            "k dropped by more than one rounding step - value is leaking out of the curve"
        );
    }

    /// C-3
    function invariant_TokensSoldWithinAllocation() public view {
        assertLe(pool.tokensSold(), pool.curveAllocation(), "curve sold more than its allocation");
    }

    /// C-4
    function invariant_GraduationGateIsMonotonic() public view {
        assertEq(handler.ghost_gateWentBackwards(), 0, "totalNativeBought decreased");
    }

    function invariant_NoTradeAfterGraduation() public view {
        assertEq(handler.ghost_tradedAfterGraduation(), 0, "a trade was accepted after graduation");
    }

    /// C-5
    function invariant_TokenConservation() public view {
        // Everything the pool ever released is exactly tokensSold; the rest is
        // still on the pool. Tokens sold back sit on the pool again, so the
        // identity holds in both directions.
        assertEq(
            token.balanceOf(address(pool)) + pool.tokensSold(),
            ALLOCATION,
            "token accounting drifted from the curve allocation"
        );
    }
}

/// @notice Guards against a campaign that reports PASS without ever trading.
contract CurveReachabilityTest is CurvePoolInvariantTest {
    function test_BuyThenSellRoundTrip() public {
        uint256 kBefore = pool.nativeReserve() * pool.tokenReserve();

        // NOT wrapped in try/catch — a revert must fail this test.
        vm.deal(address(this), 1 ether);
        uint256 out = pool.buy{value: 1 ether}(0);
        assertGt(out, 0, "buy returned no tokens");
        assertEq(pool.tokensSold(), out, "tokensSold not updated");

        // The 1% fee left the pool immediately.
        assertEq(address(feeVault).balance, 1 ether / 100, "fee not routed to the vault");
        // k drifts down by at most one rounding step — see C-2.
        uint256 kAfter = pool.nativeReserve() * pool.tokenReserve();
        if (kAfter < kBefore) {
            assertLe(kBefore - kAfter, pool.nativeReserve(), "k dropped beyond rounding dust");
        }

        // Sell part of it back.
        token.transfer(address(trader), out);
        uint256 before = address(trader).balance;
        trader.doSell(pool, out / 2);
        assertGt(address(trader).balance, before, "sell paid nothing");
        assertGe(address(pool).balance, pool.nativeRaised(), "pool insolvent after sell");
    }

    receive() external payable {}
}
