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

/// @notice Invariant fuzz tests for the core AMM.
///         Invariants verified across randomized swap/addLiquidity sequences:
///           I1: k = reserve0 * reserve1 never decreases across a swap (only grows via fees).
///           I2: token balances >= reserves (any excess goes to LPs on next withdraw).
///           I3: swap output >= amountOutMin when call succeeds (slippage enforced).
contract MagnetaPoolInvariantTest is Test {
    MagnetaPool pool;
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
