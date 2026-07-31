// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaBundler.sol";
import "../contracts/mocks/MockV2Router.sol";
import "../contracts/mocks/MockWETH.sol";
import "../contracts/tokens/MockERC20.sol";

/// @notice Regression tests for the Sentinelle audit-13 remediation of
///         MagnetaBundler — F15 (stale router approvals after a successful
///         swap leg) and F16 (rescueETH missing reentrancy protection).
contract MagnetaBundlerHardeningTest is Test {
    MagnetaBundler bundler;
    MockV2Router router;
    MockWETH weth;
    MockERC20 tokenA;
    MockERC20 buyToken;

    address user = makeAddr("user");
    address recipient1 = makeAddr("recipient1");

    function setUp() public {
        weth = new MockWETH();
        router = new MockV2Router(address(weth));
        bundler = new MagnetaBundler(address(router), address(0));

        tokenA = new MockERC20("TokenA", "TKA", 18, 0);
        buyToken = new MockERC20("BuyToken", "BUY", 18, 0);

        // MockV2Router is a dumb 1:1 mock (not a real AMM): fund it with the
        // token/native balances it needs to pay out every leg exercised below.
        tokenA.mint(address(router), 1_000 ether);
        buyToken.mint(address(router), 1_000 ether);
        vm.deal(address(router), 1_000 ether);

        tokenA.mint(user, 100 ether);
        vm.prank(user);
        tokenA.approve(address(bundler), type(uint256).max);

        vm.deal(user, 100 ether);
    }

    /// F15: bundleSell must clear the router allowance on the SUCCESSFUL leg
    /// too — before the fix it only reset the allowance inside the `catch`
    /// branch, leaving a standing approval after every successful sell.
    function test_BundleSell_ClearsAllowanceOnSuccess() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;

        vm.prank(user);
        bundler.bundleSell(tokens, amounts, mins, block.timestamp + 1000);

        assertEq(
            tokenA.allowance(address(bundler), address(router)),
            0,
            "F15: bundleSell left a standing router allowance after a successful sell"
        );
    }

    /// F15: atomicVolumeBrush's sell leg forceApproves the router but never
    /// reset it after a successful call.
    function test_AtomicVolumeBrush_ClearsAllowanceAfterSellLeg() public {
        vm.prank(user);
        bundler.atomicVolumeBrush{value: 1 ether}(address(tokenA), 1 ether, 0, 0, block.timestamp + 1000);

        assertEq(
            tokenA.allowance(address(bundler), address(router)),
            0,
            "F15: atomicVolumeBrush left a standing router allowance after the sell leg"
        );
    }

    /// F15: sellAndBundleBuy's sell leg has the same gap — the buy-side legs
    /// use msg.value (no approval needed) so only the sell-leg allowance was
    /// ever at risk of going stale.
    function test_SellAndBundleBuy_ClearsAllowanceAfterSellLeg() public {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient1;
        uint256[] memory buyAmounts = new uint256[](1);
        buyAmounts[0] = 1 ether;
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;

        vm.prank(user);
        bundler.sellAndBundleBuy(
            address(tokenA), 5 ether, 0,
            address(buyToken), mins, recipients, buyAmounts,
            block.timestamp + 1000
        );

        assertEq(
            tokenA.allowance(address(bundler), address(router)),
            0,
            "F15: sellAndBundleBuy left a standing router allowance after the sell leg"
        );
    }
}

/// @dev Owner-controlled contract that, on receiving native currency, tries to
///     reenter `rescueETH()`. Stands in for "the owner is a callback-capable
///     contract" from the F16 finding.
contract ReentrantRescueOwner {
    MagnetaBundler public bundler;
    bool public attack;

    function setBundler(address payable _bundler) external {
        bundler = MagnetaBundler(_bundler);
    }

    function setAttack(bool _attack) external {
        attack = _attack;
    }

    receive() external payable {
        if (attack) {
            // Disarm before reentering: rescueETH's own payout would otherwise
            // trigger this receive() again once the reentrancy guard is fixed
            // and the direct (non-reentrant) rescue is exercised elsewhere.
            attack = false;
            bundler.rescueETH();
        }
    }
}

/// @notice F16: rescueETH must be nonReentrant. Before the fix, an owner that
///         is a callback-capable contract could reenter rescueETH() from the
///         recipient side of disperseEther and pull out ETH earmarked for a
///         LATER recipient in the same batch, before it is ever paid or
///         credited to pendingWithdrawals.
contract MagnetaBundlerRescueReentrancyTest is Test {
    MagnetaBundler bundler;
    MockV2Router router;
    MockWETH weth;
    ReentrantRescueOwner attacker;
    address victim = makeAddr("victim");
    address sender = makeAddr("sender");

    function setUp() public {
        weth = new MockWETH();
        router = new MockV2Router(address(weth));
        attacker = new ReentrantRescueOwner();

        // The attacker contract deploys (and therefore owns) the bundler —
        // Ownable's constructor sets the owner to msg.sender directly, no
        // two-step acceptance needed for the INITIAL owner.
        vm.prank(address(attacker));
        bundler = new MagnetaBundler(address(router), address(0));
        attacker.setBundler(payable(address(bundler)));

        vm.deal(sender, 10 ether);
    }

    function test_RescueETH_CannotReenterFromDisperseEtherPush() public {
        attacker.setAttack(true);

        address[] memory recipients = new address[](2);
        recipients[0] = address(attacker);
        recipients[1] = victim;
        uint256[] memory values = new uint256[](2);
        values[0] = 1 ether;
        values[1] = 1 ether;

        vm.prank(sender);
        bundler.disperseEther{value: 2 ether}(recipients, values);

        // With the fix: the attacker's reentrant rescueETH() call reverts
        // (ReentrancyGuard), which makes the attacker's own receive() revert,
        // which makes the attacker's OWN disperse leg fail too — disperseEther
        // just skips it and folds the value into the sender's refund. The
        // victim's leg is untouched and pays out in full.
        //
        // Without the fix: the reentrant rescueETH() succeeds mid-batch,
        // draining the ETH still earmarked for the victim's (unprocessed)
        // leg straight to the attacker — the victim ends up with 0 and the
        // attacker walks away with both legs.
        assertEq(victim.balance, 1 ether, "F16: victim did not receive their full disperse leg");
        assertEq(address(attacker).balance, 0, "F16: attacker drained ETH via reentrant rescueETH");
    }
}

/// @notice Regression coverage for the Sentinelle rescan-15 remediation of
///         MagnetaBundler:
///           F-26 — removePauser(account) did not clear {pauseGuardian} when
///                  `account` was the canonical guardian, leaving monitoring
///                  reading an address that can no longer call pause().
///           F-25 — bundleBuy / bundleSell / sellAndBundleBuy / disperseEther
///                  accepted unbounded arrays, risking an unbounded gas
///                  estimate / out-of-gas failure mode for the caller.
contract MagnetaBundlerRescanFindingsTest is Test {
    MagnetaBundler bundler;
    MockV2Router router;
    MockWETH weth;

    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address user = makeAddr("user");

    function setUp() public {
        weth = new MockWETH();
        router = new MockV2Router(address(weth));
        vm.prank(owner);
        bundler = new MagnetaBundler(address(router), address(0));

        vm.deal(user, 1000 ether);
    }

    // ─── F-26 ─────────────────────────────────────────────────────────────

    /// The literal scenario the finding describes: removePauser is called
    /// with the address that is currently the canonical pauseGuardian.
    /// Before the fix, {pauseGuardian} kept pointing at an address that
    /// isPauser now maps to false — off-chain monitoring reading
    /// pauseGuardian() would believe that address can still pause() when it
    /// no longer can.
    function test_F26_RemovePauser_ClearsCanonicalGuardian() public {
        vm.startPrank(owner);
        bundler.setPauseGuardian(guardian);
        assertEq(bundler.pauseGuardian(), guardian, "setup: guardian not set");
        assertTrue(bundler.isPauser(guardian), "setup: guardian not a pauser");

        bundler.removePauser(guardian);
        vm.stopPrank();

        assertEq(bundler.pauseGuardian(), address(0), "F-26: pauseGuardian not cleared after removing the guardian");
        assertFalse(bundler.isPauser(guardian), "guardian should no longer be a pauser");
    }

    /// Non-regression: removing a pauser that is NOT the canonical guardian
    /// must leave {pauseGuardian} untouched.
    function test_F26_RemovePauser_UnrelatedPauserDoesNotClearGuardian() public {
        address otherPauser = makeAddr("otherPauser");
        vm.startPrank(owner);
        bundler.setPauseGuardian(guardian);
        bundler.addPauser(otherPauser);

        bundler.removePauser(otherPauser);
        vm.stopPrank();

        assertEq(bundler.pauseGuardian(), guardian, "unrelated removePauser must not clear the canonical guardian");
        assertFalse(bundler.isPauser(otherPauser));
        assertTrue(bundler.isPauser(guardian));
    }

    // ─── F-25 ─────────────────────────────────────────────────────────────

    function _addrArray(uint256 n, uint256 seed) internal pure returns (address[] memory arr) {
        arr = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            arr[i] = address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1));
        }
    }

    function _uintArray(uint256 n, uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](n);
        for (uint256 i = 0; i < n; i++) arr[i] = v;
    }

    function test_F25_MaxBatchConstant() public view {
        assertEq(bundler.MAX_BATCH(), 50);
    }

    function test_F25_BundleBuy_RevertsAboveMaxBatch() public {
        uint256 n = bundler.MAX_BATCH() + 1;
        address[] memory recipients = _addrArray(n, 1);
        uint256[] memory ethAmounts = _uintArray(n, 0.01 ether);
        uint256[] memory mins = _uintArray(n, 0);

        vm.prank(user);
        vm.expectRevert(bytes("MagnetaBundler: batch too large"));
        bundler.bundleBuy{value: n * 0.01 ether}(makeAddr("token"), mins, recipients, ethAmounts, block.timestamp + 1000);
    }

    function test_F25_BundleSell_RevertsAboveMaxBatch() public {
        uint256 n = bundler.MAX_BATCH() + 1;
        address[] memory tokens = _addrArray(n, 2);
        uint256[] memory amounts = _uintArray(n, 1 ether);
        uint256[] memory mins = _uintArray(n, 0);

        vm.prank(user);
        vm.expectRevert(bytes("MagnetaBundler: batch too large"));
        bundler.bundleSell(tokens, amounts, mins, block.timestamp + 1000);
    }

    function test_F25_SellAndBundleBuy_RevertsAboveMaxBatch() public {
        uint256 n = bundler.MAX_BATCH() + 1;
        address[] memory recipients = _addrArray(n, 3);
        uint256[] memory buyAmounts = _uintArray(n, 0.01 ether);
        uint256[] memory mins = _uintArray(n, 0);

        vm.prank(user);
        vm.expectRevert(bytes("MagnetaBundler: batch too large"));
        bundler.sellAndBundleBuy(
            makeAddr("sellToken"), 1 ether, 0, makeAddr("buyToken"), mins, recipients, buyAmounts, block.timestamp + 1000
        );
    }

    function test_F25_DisperseEther_RevertsAboveMaxBatch() public {
        uint256 n = bundler.MAX_BATCH() + 1;
        address[] memory recipients = _addrArray(n, 4);
        uint256[] memory values = _uintArray(n, 0.01 ether);

        vm.prank(user);
        vm.expectRevert(bytes("MagnetaBundler: batch too large"));
        bundler.disperseEther{value: n * 0.01 ether}(recipients, values);
    }

    /// Boundary: exactly MAX_BATCH recipients must still be accepted (no
    /// over-tightening). disperseEther is the cheapest op to exercise at the
    /// boundary — no router/token wiring needed.
    function test_F25_DisperseEther_ExactlyMaxBatchSucceeds() public {
        uint256 n = bundler.MAX_BATCH();
        address[] memory recipients = _addrArray(n, 5);
        uint256[] memory values = _uintArray(n, 0.001 ether);

        vm.prank(user);
        bundler.disperseEther{value: n * 0.001 ether}(recipients, values);

        assertEq(recipients[0].balance, 0.001 ether);
        assertEq(recipients[n - 1].balance, 0.001 ether);
    }
}
