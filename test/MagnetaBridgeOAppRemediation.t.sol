// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaBridgeOApp.sol";
import "../contracts/mocks/MockLayerZeroEndpoint.sol";
import "../contracts/mocks/MockFeeOnTransferToken.sol";
import "../contracts/tokens/MockERC20.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title MagnetaBridgeOAppRemediation
/// @notice Regression tests for Sentinelle re-scan #15 (bridge) findings:
///         F-13 (surplus native fee refund — verified already-correct, no
///         code change), F-15 (fee-on-transfer liquidity accounting), F-21
///         (addBridgeLiquidity endpointId must be localEid), F-2 (outbound
///         bridgeTokens must credit bridgeLiquidity so a later inbound
///         delivery for the same funds can succeed), and F-30 (daily window
///         reset on re-arm).
contract MagnetaBridgeOAppRemediationTest is Test {
    uint32 constant EID_A = 40245; // this chain (Base, say)
    uint32 constant EID_B = 40231; // remote peer (Arbitrum, say)

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address feeRecipient = address(0xFEE);
    address remotePeer = address(0xB0B1D9E);

    MockLayerZeroEndpoint endpointA;
    MagnetaBridgeOApp bridgeA;
    MockERC20 token;

    function setUp() public {
        endpointA = new MockLayerZeroEndpoint(EID_A);

        bridgeA = new MagnetaBridgeOApp(
            address(endpointA),
            owner,
            feeRecipient,
            EID_A
        );

        token = new MockERC20("USD Mock", "USDC", 18, 1_000_000 ether);

        bridgeA.setSupportedToken(EID_B, address(token), true);
        bridgeA.setBridgeableToken(EID_B, address(token), true);
        bridgeA.setRemoteToken(EID_B, address(token), address(token));
        bridgeA.setPeer(EID_B, bytes32(uint256(uint160(remotePeer))));
        // Also mark the token supported on THIS chain's own localEid — needed
        // for the addBridgeLiquidity(EID_A, ...) tests below (F-21/F-15).
        bridgeA.setSupportedToken(EID_A, address(token), true);

        token.transfer(alice, 10_000 ether);
        vm.prank(alice);
        token.approve(address(bridgeA), type(uint256).max);
        vm.deal(alice, 10 ether);

        // Owner (this test contract) needs its own allowance for the
        // addBridgeLiquidity(...) tests below, which pull from msg.sender.
        token.approve(address(bridgeA), type(uint256).max);
    }

    // ─── F-13: surplus native fee is refunded to the payer ────────────────

    /// @dev bridgeTokens forwards the FULL msg.value into `_lzSend` as
    ///      `MessagingFee.nativeFee` rather than the quoted `fee_.nativeFee`.
    ///      Investigation (see the NatSpec on the `_lzSend` call site in
    ///      MagnetaBridgeOApp.sol) found this is REQUIRED, not a bug:
    ///      OAppSender._payNative hard-reverts unless msg.value ==
    ///      the passed nativeFee exactly, so passing the smaller quoted fee
    ///      while msg.value is larger (a caller padding for slack) would
    ///      revert every overpaid call. The endpoint's own send()
    ///      (both the real LayerZero EndpointV2 and this repo's
    ///      MockLayerZeroEndpoint) independently computes the true required
    ///      fee and refunds `supplied - required` to `_refundAddress`, which
    ///      is `payable(msg.sender)` here. This test proves that mechanism
    ///      actually returns the surplus to the payer — i.e. no code change
    ///      was needed to satisfy the "surplus reverts to sender" finding,
    ///      but the behavior is now locked in by a test.
    function test_SurplusNativeFeeIsRefundedToPayer() public {
        uint256 quoteFee = endpointA.QUOTE_NATIVE_FEE();
        uint256 overpay = 1 ether; // way more than the quoted fee
        assertGt(overpay, quoteFee);

        uint256 aliceEthBefore = alice.balance;

        vm.prank(alice);
        bridgeA.bridgeTokens{value: overpay}(
            address(token), 100 ether, EID_B, alice, bytes(""), false
        );

        uint256 aliceEthAfter = alice.balance;
        uint256 actuallySpent = aliceEthBefore - aliceEthAfter;

        // Alice should only have been charged the quoted native fee, not the
        // full amount she attached to the call — the surplus must come back.
        assertEq(actuallySpent, quoteFee, "surplus native fee was not refunded to the payer");
    }

    // ─── F-15: fee-on-transfer token — addBridgeLiquidity credits the ACTUAL
    //           received amount, not the nominal one ─────────────────────

    function test_AddBridgeLiquidity_CreditsActualReceivedAmount_ForFeeOnTransferToken() public {
        uint256 feeBps = 500; // 5%
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken("Deflationary", "DEFL", 1_000_000 ether, feeBps);

        bridgeA.setSupportedToken(EID_A, address(fot), true);
        fot.approve(address(bridgeA), type(uint256).max);

        uint256 nominal = 1_000 ether;
        uint256 expectedReceived = nominal - (nominal * feeBps) / 10000;

        bridgeA.addBridgeLiquidity(EID_A, address(fot), nominal);

        // Liquidity credited must equal what the contract ACTUALLY received
        // (the post-fee amount), never the nominal amount requested.
        assertEq(bridgeA.bridgeLiquidity(EID_A, address(fot)), expectedReceived);
        assertEq(fot.balanceOf(address(bridgeA)), expectedReceived);
    }

    function test_AddBridgeLiquidity_CreditsFullAmount_ForOrdinaryToken() public {
        // Positive control: an ordinary (non-FOT) token still credits the
        // full nominal amount — the balance-delta measurement is a no-op
        // when there's no transfer fee.
        bridgeA.addBridgeLiquidity(EID_A, address(token), 500 ether);
        assertEq(bridgeA.bridgeLiquidity(EID_A, address(token)), 500 ether);
    }

    // ─── F-21: addBridgeLiquidity endpointId must equal localEid ──────────

    function test_AddBridgeLiquidity_RevertsForNonLocalEndpointId() public {
        // EID_B is a valid, supported *destination* route, but is NOT this
        // chain's own localEid — _lzReceive would never read
        // bridgeLiquidity[EID_B][token], so accepting it here would strand
        // the deposit. Must revert.
        vm.expectRevert(bytes("MagnetaBridgeOApp: endpointId must be localEid"));
        bridgeA.addBridgeLiquidity(EID_B, address(token), 100 ether);
    }

    function test_AddBridgeLiquidity_SucceedsForLocalEndpointId() public {
        bridgeA.addBridgeLiquidity(EID_A, address(token), 100 ether);
        assertEq(bridgeA.bridgeLiquidity(EID_A, address(token)), 100 ether);
    }

    // ─── F-2: outbound bridgeTokens must credit bridgeLiquidity so a later
    //          inbound delivery for the same underlying funds can succeed ──

    /// @dev Full outbound → inbound cycle on the SAME chain instance (this
    ///      test harness has one bridge contract, simulating a chain
    ///      receiving both an outbound send FROM itself and, separately, an
    ///      inbound delivery INTO itself — exactly the scenario the finding
    ///      describes: after enough outbound volume, the physical token
    ///      balance the contract is holding should be enough to also back
    ///      inbound deliveries, but bridgeLiquidity was never credited).
    function test_OutboundBridgeThenInboundDelivery_Succeeds() public {
        uint256 amount = 1_000 ether;

        vm.prank(alice);
        bridgeA.bridgeTokens{value: 1 ether}(
            address(token), amount, EID_B, alice, bytes(""), false
        );

        // 0.1% default fee for a non-Ethereum route.
        uint256 fee = (amount * 10) / 10_000;
        uint256 amountAfterFee = amount - fee;

        // The net deposit must now be reflected in bridgeLiquidity[localEid][token].
        assertEq(bridgeA.bridgeLiquidity(EID_A, address(token)), amountAfterFee);

        // Simulate an inbound delivery (from EID_B, the configured peer) for
        // an amount within what's now tracked as available liquidity.
        Origin memory origin = Origin({
            srcEid: EID_B,
            sender: bytes32(uint256(uint160(remotePeer))),
            nonce: 1
        });
        bytes memory payload = abi.encode(address(token), bob, amountAfterFee);

        uint256 bobBalBefore = token.balanceOf(bob);

        endpointA.deliverMessage(address(bridgeA), origin, keccak256("guid-1"), payload);

        assertEq(token.balanceOf(bob), bobBalBefore + amountAfterFee);
        assertEq(bridgeA.bridgeLiquidity(EID_A, address(token)), 0);
    }

    /// @dev Without the F-2 fix, this exact delivery would have reverted
    ///      with "insufficient bridge liquidity" despite the tokens
    ///      physically sitting in the contract from Alice's prior send.
    function test_InboundDeliveryRevertsIfExceedsCreditedLiquidity() public {
        uint256 amount = 1_000 ether;
        vm.prank(alice);
        bridgeA.bridgeTokens{value: 1 ether}(
            address(token), amount, EID_B, alice, bytes(""), false
        );
        uint256 fee = (amount * 10) / 10_000;
        uint256 amountAfterFee = amount - fee;

        Origin memory origin = Origin({
            srcEid: EID_B,
            sender: bytes32(uint256(uint160(remotePeer))),
            nonce: 1
        });
        // Ask for one wei more than was credited.
        bytes memory payload = abi.encode(address(token), bob, amountAfterFee + 1);

        vm.expectRevert(bytes("MagnetaBridgeOApp: insufficient bridge liquidity"));
        endpointA.deliverMessage(address(bridgeA), origin, keccak256("guid-2"), payload);
    }

    // ─── F-30: daily window resets when setDailyLimit re-arms ─────────────

    function test_SetDailyLimit_ResetsWindow_OnZeroToNonZero() public {
        // Arm a limit and spend against it.
        bridgeA.setDailyLimit(address(token), 1_000 ether);
        vm.prank(alice);
        bridgeA.bridgeTokens{value: 1 ether}(address(token), 500 ether, EID_B, alice, bytes(""), false);
        assertGt(bridgeA.dailyVolume(address(token)), 0);
        uint256 windowStartAfterFirstSpend = bridgeA.dailyWindowStart(address(token));

        // Disarm the limit.
        bridgeA.setDailyLimit(address(token), 0);

        // Move forward a little (well within 24h, so a lazy reset in
        // bridgeTokens would NOT have fired on its own).
        vm.warp(block.timestamp + 1 hours);

        // Re-arm with a non-zero limit — this must reset dailyVolume/window,
        // not inherit the stale accumulated volume from before disarming.
        bridgeA.setDailyLimit(address(token), 2_000 ether);

        assertEq(bridgeA.dailyVolume(address(token)), 0, "dailyVolume must reset on re-arm");
        assertGt(
            bridgeA.dailyWindowStart(address(token)),
            windowStartAfterFirstSpend,
            "dailyWindowStart must reset on re-arm"
        );
        assertEq(bridgeA.dailyWindowStart(address(token)), block.timestamp);
    }

    function test_SetDailyLimit_ResetsWindow_OnValueChange() public {
        bridgeA.setDailyLimit(address(token), 1_000 ether);
        vm.prank(alice);
        bridgeA.bridgeTokens{value: 1 ether}(address(token), 500 ether, EID_B, alice, bytes(""), false);
        assertGt(bridgeA.dailyVolume(address(token)), 0);

        vm.warp(block.timestamp + 1 hours);

        // Changing the limit value (without ever going through zero) also
        // counts as re-arming per the finding's "0->non-zero OR value
        // change" wording.
        bridgeA.setDailyLimit(address(token), 5_000 ether);

        assertEq(bridgeA.dailyVolume(address(token)), 0);
        assertEq(bridgeA.dailyWindowStart(address(token)), block.timestamp);
    }

    function test_SetDailyLimit_NoResetWhenValueUnchanged() public {
        bridgeA.setDailyLimit(address(token), 1_000 ether);
        vm.prank(alice);
        bridgeA.bridgeTokens{value: 1 ether}(address(token), 500 ether, EID_B, alice, bytes(""), false);
        uint256 volBefore = bridgeA.dailyVolume(address(token));
        uint256 windowBefore = bridgeA.dailyWindowStart(address(token));
        assertGt(volBefore, 0);

        vm.warp(block.timestamp + 1 hours);

        // Setting the SAME value again is a no-op, not a re-arm — must NOT
        // reset accumulated volume/window.
        bridgeA.setDailyLimit(address(token), 1_000 ether);

        assertEq(bridgeA.dailyVolume(address(token)), volBefore);
        assertEq(bridgeA.dailyWindowStart(address(token)), windowBefore);
    }
}
