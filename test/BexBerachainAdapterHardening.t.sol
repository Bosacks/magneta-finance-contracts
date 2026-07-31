// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/adapters/BexBerachainAdapter.sol";
import "../contracts/mocks/MockBex.sol";
import "../contracts/mocks/MockWETH.sol";
import "../contracts/tokens/MockERC20.sol";
import "../contracts/mocks/MockFeeOnTransferToken.sol";

/// @title BexBerachainAdapterHardening
/// @notice Forge tests for the 4 findings fixed in BexBerachainAdapter.sol
///         (2026-07-31): read-only Vault reentrancy (HIGH, verified),
///         F-7 unvalidated `setPair` (HIGH, report 18), F-8 zero minBPTOut
///         (MEDIUM, report 18), and fee-on-transfer accounting (economic
///         module). Each test is written to FAIL against the pre-fix
///         behaviour and PASS against the fixed contract — see the comment
///         on each test for the specific pre-fix failure mode.
///
///         The existing hardhat suite (test/BexBerachainAdapter.test.ts)
///         covers the adapter's original happy paths; this file is scoped
///         to the 4 remediated findings only, run via `forge test` per this
///         task's verification requirement.
contract BexBerachainAdapterHardeningTest is Test {
    BexBerachainAdapter adapter;
    MockBexVault vault;
    MockBexWeightedPoolFactory poolFactory;
    MockWETH weth;
    MockERC20 token;

    address user = makeAddr("user");
    address other = makeAddr("other");

    uint256 constant TOKEN_AMOUNT = 1000 ether;
    uint256 constant ETH_AMOUNT = 10 ether;
    uint256 DEADLINE;

    function setUp() public {
        DEADLINE = block.timestamp + 3600;

        vault = new MockBexVault();
        poolFactory = new MockBexWeightedPoolFactory(address(vault));
        weth = new MockWETH();
        token = new MockERC20("Test", "TST", 18, 1_000_000 ether);

        adapter = new BexBerachainAdapter(address(vault), address(poolFactory), address(weth));

        token.transfer(user, 500_000 ether);
        vm.deal(user, 1000 ether);
    }

    // ─── Fix 1: read-only Vault reentrancy guard ───────────────────────────

    /// @dev Pre-fix: `_getReservesSorted` called `vault.getPoolTokens`
    ///      directly with no guard, so this call would SUCCEED even while
    ///      `simulateVaultReentrancy` signals the Vault is mid-operation for
    ///      someone else. Post-fix: `VaultReentrancyLib.ensureNotInVaultContext`
    ///      is called first and reverts.
    function test_AddLiquidityRevertsWhenVaultIsReentrant() public {
        vm.startPrank(user);
        token.approve(address(adapter), type(uint256).max);
        // INIT join — establishes the pool, doesn't touch _getReservesSorted.
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        vm.stopPrank();

        // Simulate: Vault is mid-operation for an unrelated caller.
        vault.setSimulateVaultReentrancy(true);

        vm.startPrank(user);
        token.approve(address(adapter), type(uint256).max);
        vm.expectRevert(bytes("BexAdapter: vault reentrancy detected"));
        // Non-init join — this one DOES call _getReservesSorted.
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        vm.stopPrank();
    }

    /// A Vault that reverts for a reason OTHER than reentrancy must not be
    /// mistaken for one. The guard first shipped testing `revertData.length
    /// == 0`, which flags any revert-with-data — a paused Vault, a new error
    /// code — and would have frozen the adapter for a condition that has
    /// nothing to do with reentrancy. Balancer's own library compares the
    /// error's identity (BAL#400) for exactly this reason; this test pins
    /// that distinction.
    function test_UnrelatedVaultErrorIsNotTreatedAsReentrancy() public {
        vm.startPrank(user);
        token.approve(address(adapter), type(uint256).max);
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        vm.stopPrank();

        vault.setSimulateVaultOtherError(true);

        vm.startPrank(user);
        token.approve(address(adapter), type(uint256).max);
        // Must go through: the probe reverted, but not with BAL#400.
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        vm.stopPrank();
    }

    /// @dev Same mechanism as above, exercised via `removeLiquidity`'s
    ///      `balancesBefore` read.
    function test_RemoveLiquidityRevertsWhenVaultIsReentrant() public {
        vm.startPrank(user);
        token.approve(address(adapter), type(uint256).max);
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        address pool = adapter.getPair(address(token), address(weth));
        MockBexPool(pool).approve(address(adapter), type(uint256).max);
        vm.stopPrank();

        vault.setSimulateVaultReentrancy(true);

        uint256 bpt = MockBexPool(pool).balanceOf(user);
        vm.prank(user);
        vm.expectRevert(bytes("BexAdapter: vault reentrancy detected"));
        adapter.removeLiquidity(address(token), address(weth), bpt, 0, 0, user, DEADLINE);
    }

    /// @dev Sanity: the guard must not false-positive on the normal
    ///      (non-reentrant) path — otherwise the fix would just trade one
    ///      bug for another (permanent DoS).
    function test_AddLiquidityStillWorksWhenVaultIsIdle() public {
        vm.startPrank(user);
        token.approve(address(adapter), type(uint256).max);
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        // Second (non-init, ratio-computing) join — exercises the guarded
        // read path while the vault is genuinely idle.
        token.approve(address(adapter), type(uint256).max);
        (, , uint256 liquidity) = adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        vm.stopPrank();
        assertGt(liquidity, 0);
    }

    // ─── Fix 2: F-7 setPair validation ──────────────────────────────────

    /// @dev Pre-fix: `setPair` accepted ANY non-zero pool address with no
    ///      relationship to tokenA/tokenB. Registers a pool that actually
    ///      holds a DIFFERENT token pair and asserts it is now rejected.
    function test_SetPairRevertsWhenPoolTokensDontMatch() public {
        MockERC20 tokenC = new MockERC20("C", "C", 18, 1000 ether);
        MockERC20 tokenD = new MockERC20("D", "D", 18, 1000 ether);

        address mismatchedPool = _createAndRegisterPool(address(tokenC), address(tokenD));

        vm.expectRevert(bytes("BexAdapter: pool token mismatch"));
        adapter.setPair(address(token), address(weth), mismatchedPool);
    }

    /// @dev Pre-fix: `setPair` never called into the Vault at all, so a pool
    ///      the Vault has never seen (no `getPoolTokens` entry) would still
    ///      be accepted. Post-fix it must revert.
    function test_SetPairRevertsWhenPoolUnknownToVault() public {
        // Created via the factory (has a valid getPoolId()) but never
        // joined, so the mock Vault never recorded its token list.
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = address(token) < address(weth)
            ? (address(token), address(weth))
            : (address(weth), address(token));
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        address[] memory rateProviders = new address[](2);
        address neverJoinedPool = poolFactory.create(
            "L", "L", tokens, weights, rateProviders, 3e15, address(this), bytes32(0)
        );

        vm.expectRevert(bytes("BexAdapter: pool not 2-asset"));
        adapter.setPair(address(token), address(weth), neverJoinedPool);
    }

    /// @dev Sanity: a pool that DOES hold exactly {tokenA, tokenB} is still
    ///      accepted (the fix must not reject legitimate registrations).
    function test_SetPairSucceedsWhenPoolTokensMatch() public {
        address pool = _createAndRegisterPool(address(token), address(weth));

        adapter.setPair(address(token), address(weth), pool);

        assertEq(adapter.getPair(address(token), address(weth)), pool);
        assertEq(adapter.getPair(address(weth), address(token)), pool);
    }

    // ─── Fix 3: F-8 minBPTOut enforcement ───────────────────────────────

    /// @dev Pre-fix: `addLiquidityETH` hardcoded `minBPTOut = 0` and had no
    ///      caller-supplied floor at all, so the Vault could return
    ///      arbitrarily little BPT without reverting. The mock Vault mints a
    ///      FIXED `BPT_PER_JOIN` (1000e18) per join regardless of amounts —
    ///      standing in for "manipulated ratio -> starved BPT". Requesting a
    ///      `minLiquidity` above that fixed mint must revert post-fix.
    function test_AddLiquidityRevertsWhenReceivedBptBelowMinLiquidity() public {
        vm.startPrank(user);
        token.approve(address(adapter), type(uint256).max);
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );

        token.approve(address(adapter), type(uint256).max);
        vm.expectRevert(BexBerachainAdapter.InsufficientOutput.selector);
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, /* minLiquidity */ 2000 ether, user, DEADLINE
        );
        vm.stopPrank();
    }

    /// @dev Sanity: a minLiquidity at or below what the pool actually mints
    ///      still succeeds.
    function test_AddLiquiditySucceedsWhenMinLiquidityMet() public {
        vm.startPrank(user);
        token.approve(address(adapter), type(uint256).max);
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );

        token.approve(address(adapter), type(uint256).max);
        (, , uint256 liquidity) = adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(token), TOKEN_AMOUNT, 0, 0, /* minLiquidity */ 1000 ether, user, DEADLINE
        );
        vm.stopPrank();
        assertEq(liquidity, 1000 ether);
    }

    // ─── Fix 4: fee-on-transfer accounting ──────────────────────────────

    /// @dev Pre-fix: `addLiquidityETH` transferred `amountToken` then
    ///      approved/joined with that SAME nominal figure. For a
    ///      fee-on-transfer token the adapter actually holds LESS than that
    ///      after the pull, so the Vault's `transferFrom(adapter, ...,
    ///      maxAmountsIn[i])` inside `joinPool` reverts on insufficient
    ///      balance — the whole call fails for any fee-on-transfer token.
    ///      Post-fix, the adapter measures the real delta and joins with
    ///      that, so the call succeeds and returns the POST-FEE amount.
    function test_AddLiquidityETHSucceedsWithFeeOnTransferToken() public {
        uint256 feeBps = 500; // 5%
        MockFeeOnTransferToken feeToken = new MockFeeOnTransferToken("Fee", "FEE", 1_000_000 ether, feeBps);
        feeToken.transfer(user, 500_000 ether);

        vm.startPrank(user);
        feeToken.approve(address(adapter), type(uint256).max);
        (uint256 amountToken, , ) = adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(feeToken), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        vm.stopPrank();

        // Adapter must report what it ACTUALLY received (post-fee), not the
        // nominal amount requested.
        uint256 expectedReceived = TOKEN_AMOUNT - (TOKEN_AMOUNT * feeBps) / 10_000;
        assertEq(amountToken, expectedReceived);
        assertLt(amountToken, TOKEN_AMOUNT);

        // Balance-neutral: adapter holds no residual fee-on-transfer token.
        assertEq(feeToken.balanceOf(address(adapter)), 0);
    }

    /// @dev Same measured-pull fix, exercised through the swap path.
    function test_SwapExactTokensForTokensSucceedsWithFeeOnTransferToken() public {
        uint256 feeBps = 500; // 5%
        MockFeeOnTransferToken feeToken = new MockFeeOnTransferToken("Fee", "FEE", 1_000_000 ether, feeBps);
        feeToken.transfer(user, 500_000 ether);

        // Seed a (feeToken, WETH) pool via addLiquidityETH so the pair exists.
        vm.startPrank(user);
        feeToken.approve(address(adapter), type(uint256).max);
        adapter.addLiquidityETH{value: ETH_AMOUNT}(
            address(feeToken), TOKEN_AMOUNT, 0, 0, 0, user, DEADLINE
        );
        vm.stopPrank();

        // Fund the vault so it can pay out the WETH leg of the swap.
        weth.deposit{value: 200 ether}();
        weth.transfer(address(vault), 200 ether);

        uint256 swapAmount = 100 ether;
        vm.startPrank(user);
        feeToken.approve(address(adapter), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(weth);
        uint256[] memory amounts = adapter.swapExactTokensForTokens(
            swapAmount, 0, path, other, DEADLINE
        );
        vm.stopPrank();

        uint256 expectedIn = swapAmount - (swapAmount * feeBps) / 10_000;
        assertEq(amounts[0], expectedIn);
        assertEq(feeToken.balanceOf(address(adapter)), 0);
    }

    // ─── helpers ────────────────────────────────────────────────────────

    /// @dev Create a weighted pool for (tokenX, tokenY) via the factory and
    ///      register its token list with the mock Vault by performing a
    ///      real (if trivial) joinPool — mirrors how MockBexVault only
    ///      learns a pool's token list on first join, same as the real
    ///      Balancer V2 Vault registering assets at pool init.
    function _createAndRegisterPool(address tokenX, address tokenY) internal returns (address pool) {
        (address t0, address t1) = tokenX < tokenY ? (tokenX, tokenY) : (tokenY, tokenX);
        address[] memory tokens = new address[](2);
        tokens[0] = t0;
        tokens[1] = t1;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        address[] memory rateProviders = new address[](2);
        pool = poolFactory.create("L", "L", tokens, weights, rateProviders, 3e15, address(this), bytes32(0));

        bytes32 poolId = MockBexPool(pool).getPoolId();

        MockERC20(t0).mint(address(this), 1 ether);
        MockERC20(t1).mint(address(this), 1 ether);
        MockERC20(t0).approve(address(vault), 1 ether);
        MockERC20(t1).approve(address(vault), 1 ether);

        address[] memory assets = new address[](2);
        assets[0] = t0;
        assets[1] = t1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;

        MockBexVault.JoinPoolRequest memory request = MockBexVault.JoinPoolRequest({
            assets: assets,
            maxAmountsIn: amounts,
            userData: "",
            fromInternalBalance: false
        });
        vault.joinPool(poolId, address(this), address(this), request);
    }
}
