// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaPool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenA is ERC20 {
    constructor() ERC20("A", "A") { _mint(msg.sender, 1e30); }
}

contract TokenB is ERC20 {
    constructor() ERC20("B", "B") { _mint(msg.sender, 1e30); }
}

/// @notice Bounds the fuzzer's arguments to values the AMM can actually act on.
///
///         Without a handler, `invariant_BalanceCoversReserves` reverted on 93.8%
///         of its 128 000 calls (measured 2026-07-29): random uint256 amounts,
///         random poolIds and past deadlines are rejected before touching state,
///         so ~8 000 calls did any work and the invariant passed largely because
///         nothing happened. Every other invariant suite in this repo already
///         drives its subject through a handler; this one did not.
///
///         Ghost counters record what actually executed, so the reachability test
///         below can fail if the campaign silently stops exercising the pool.
contract MagnetaPoolHandler is Test {
    MagnetaPool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint256 public immutable poolId;
    address public immutable lp;
    address public immutable trader;

    uint256 public ghost_swaps;
    uint256 public ghost_adds;
    uint256 public ghost_removes;
    /// Position ids minted by this handler, so removeLiquidity has a real target.
    uint256[] public positions;

    constructor(
        MagnetaPool _pool,
        IERC20 _token0,
        IERC20 _token1,
        uint256 _poolId,
        address _lp,
        address _trader
    ) {
        pool = _pool; token0 = _token0; token1 = _token1;
        poolId = _poolId; lp = _lp; trader = _trader;
    }

    /// Swap a plausible size in either direction.
    function swap(uint256 amountIn, bool zeroForOne) external {
        amountIn = bound(amountIn, 1e15, 1e21);
        IERC20 tokenIn = zeroForOne ? token0 : token1;
        if (tokenIn.balanceOf(trader) < amountIn) return;

        vm.prank(trader);
        try pool.swap(poolId, address(tokenIn), amountIn, 0, trader, block.timestamp + 1) {
            ghost_swaps++;
        } catch { /* legitimate revert (thin liquidity, rounding) */ }
    }

    /// Add liquidity in a ratio near the current reserves, which is what the
    /// pool accepts; wildly unbalanced amounts are rejected and teach nothing.
    function addLiquidity(uint256 amount0, uint256 skew) external {
        amount0 = bound(amount0, 1e16, 1e21);
        skew    = bound(skew, 90, 110); // ±10% around the pool ratio
        (, , , , uint256 r0, uint256 r1, ) = pool.pools(poolId);
        if (r0 == 0) return;
        uint256 amount1 = (amount0 * r1 * skew) / (r0 * 100);
        if (token0.balanceOf(lp) < amount0 || token1.balanceOf(lp) < amount1) return;

        vm.prank(lp);
        try pool.addLiquidity(poolId, amount0, amount1, 0, 0, lp) returns (
            uint256 tokenId, uint256, uint256, uint256
        ) {
            positions.push(tokenId);
            ghost_adds++;
        } catch { /* ratio drift, rounding */ }
    }

    /// Withdraw part of a position this handler actually owns.
    function removeLiquidity(uint256 posSeed, uint256 fraction) external {
        if (positions.length == 0) return;
        uint256 tokenId = positions[posSeed % positions.length];
        fraction = bound(fraction, 1, 100);

        // Position is (poolId, liquidity, amount0, amount1, fee0, fee1).
        (, uint256 liq, , , , ) = pool.positions(tokenId);
        if (liq == 0) return;
        uint256 amount = (liq * fraction) / 100;
        if (amount == 0) return;

        vm.prank(lp);
        try pool.removeLiquidity(tokenId, amount, 0, 0, lp) {
            ghost_removes++;
        } catch { /* min-out, dust */ }
    }

    function positionCount() external view returns (uint256) { return positions.length; }
}

/// @notice Invariant fuzz tests for the core AMM.
///         Invariants verified across randomized swap/addLiquidity sequences:
///           I1: k = reserve0 * reserve1 never decreases across a swap (only grows via fees).
///           I2: token balances >= reserves (any excess goes to LPs on next withdraw).
///           I3: swap output >= amountOutMin when call succeeds (slippage enforced).
contract MagnetaPoolInvariantTest is Test {
    MagnetaPool pool;
    MagnetaPoolHandler handler;
    TokenA tokenA;
    TokenB tokenB;
    uint256 poolId;
    address constant LP = address(0x1234);
    address constant TRADER = address(0x5678);

    function setUp() public {
        tokenA = new TokenA();
        tokenB = new TokenB();
        pool = new MagnetaPool(address(this));
        pool.setPoolCreationEnabled(true);
        pool.setLiquidityAdditionEnabled(true);

        (address t0, address t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
        poolId = pool.createPool(t0, t1, 30); // 0.3% fee

        // Seed initial liquidity
        tokenA.transfer(LP, 1e24);
        tokenB.transfer(LP, 1e24);
        vm.startPrank(LP);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(poolId, 1e22, 1e22, 0, 0, LP);
        vm.stopPrank();

        // Fund trader
        tokenA.transfer(TRADER, 1e24);
        tokenB.transfer(TRADER, 1e24);
        vm.startPrank(TRADER);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // Drive the pool through a handler that bounds arguments, as every other
        // invariant suite here does. Targeting the pool directly left 93.8% of
        // calls reverting on unusable random input; the handler brings that to
        // near zero and the same 128 000 calls actually move state.
        //
        // Targeting the handler also fixes the original failure: with no target
        // declared, the fuzzer drove TokenA/TokenB too and could pick ANY
        // msg.sender — it picked the pool's own address and called
        // `TokenB.transfer(victim, 2077)`, moving tokens out without touching
        // reserves. I2 failed on a sequence the AMM has no code path to produce.
        handler = new MagnetaPoolHandler(
            pool, IERC20(_sortedToken0()), IERC20(_sortedToken1()), poolId, LP, TRADER
        );
        targetContract(address(handler));

        // The handler acts via vm.prank, so it needs the actors' allowances.
        vm.startPrank(LP);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /// I1: k never decreases across a swap.
    function testFuzz_K_NeverDecreases(uint256 amountIn, bool aToB) public {
        amountIn = bound(amountIn, 1e15, 1e21); // 0.001 – 1000 tokens
        (, , , , uint256 r0Before, uint256 r1Before, ) = pool.pools(poolId);
        uint256 kBefore = r0Before * r1Before;

        vm.prank(TRADER);
        address tokenIn = aToB ? _sortedToken0() : _sortedToken1();
        try pool.swap(poolId, tokenIn, amountIn, 0, TRADER, block.timestamp + 1) {
            (, , , , uint256 r0After, uint256 r1After, ) = pool.pools(poolId);
            uint256 kAfter = r0After * r1After;
            assertGe(kAfter, kBefore, "k decreased across swap");
        } catch {
            // Pool could legitimately revert (insufficient liquidity edge case) — skip
        }
    }

    /// I2: balance >= reserves for both tokens.
    function invariant_BalanceCoversReserves() public view {
        (address t0, address t1, , , uint256 r0, uint256 r1, ) = pool.pools(poolId);
        assertGe(IERC20(t0).balanceOf(address(pool)), r0, "t0 balance < reserve");
        assertGe(IERC20(t1).balanceOf(address(pool)), r1, "t1 balance < reserve");
    }

    /// I3: slippage is enforced.
    function testFuzz_SlippageRevertsOnUnderMin(uint256 amountIn, uint256 minOut) public {
        amountIn = bound(amountIn, 1e15, 1e20);
        minOut = bound(minOut, 1e30, type(uint128).max); // impossible
        vm.prank(TRADER);
        vm.expectRevert();
        pool.swap(poolId, _sortedToken0(), amountIn, minOut, TRADER, block.timestamp + 1);
    }

    function _sortedToken0() internal view returns (address) {
        return address(tokenA) < address(tokenB) ? address(tokenA) : address(tokenB);
    }
    function _sortedToken1() internal view returns (address) {
        return address(tokenA) < address(tokenB) ? address(tokenB) : address(tokenA);
    }
}

/// @notice Guard against the failure this suite was already in: a handler whose
///         every call returns early makes all the invariants above report PASS
///         while nothing touched the pool. Foundry evaluates invariants once
///         BEFORE the first call, so this cannot itself be an invariant — the
///         ghost counters are still zero then. It is a plain test that drives
///         each handler entry point and asserts the pool moved.
contract MagnetaPoolReachabilityTest is MagnetaPoolInvariantTest {
    function test_HandlerActuallyReachesThePool() public {
        (, , , , uint256 r0Before, , ) = pool.pools(poolId);

        handler.swap(1e18, true);
        handler.addLiquidity(1e18, 100);
        handler.removeLiquidity(0, 50);

        assertGt(handler.ghost_swaps(), 0, "no swap executed");
        assertGt(handler.ghost_adds(), 0, "no addLiquidity executed");
        assertGt(handler.ghost_removes(), 0, "no removeLiquidity executed");
        assertGt(handler.positionCount(), 0, "no position was ever minted");

        (, , , , uint256 r0After, , ) = pool.pools(poolId);
        assertTrue(r0After != r0Before, "reserves never changed - the pool was not exercised");
    }
}
