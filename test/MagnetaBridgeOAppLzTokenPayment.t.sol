// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaBridgeOApp.sol";
import "../contracts/mocks/MockLayerZeroEndpoint.sol";
import "../contracts/tokens/MockERC20.sol";

/// @title MagnetaBridgeOAppLzTokenPayment
/// @notice Regression test for Sentinelle audit #13, finding F-10
///         (MEDIUM×HIGH): `bridgeTokens` used to quote LayerZero fees via
///         `_quote(..., payInLzToken)` — which can return a non-zero
///         `lzTokenFee` when `payInLzToken=true` — but ALWAYS called
///         `_lzSend` with `MessagingFee(msg.value, 0)`, silently discarding
///         the quoted LZ-token fee and paying 100% in native token
///         regardless of what the caller requested/was quoted. The chosen
///         remediation is to REJECT `payInLzToken=true` outright (LZ-token
///         payment is not an implemented product path) rather than ship a
///         payment mode whose behavior diverges from its own quote.
contract MagnetaBridgeOAppLzTokenPaymentTest is Test {
    uint32 constant EID_A = 40245; // Base
    uint32 constant EID_B = 40231; // Arbitrum

    address owner = address(this);
    address alice = address(0xA11CE);
    address feeRecipient = address(0xFEE);

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

        // Wire a valid outgoing route: token supported+bridgeable to EID_B,
        // with a canonical remote-token mapping configured (F22 guard).
        bridgeA.setSupportedToken(EID_B, address(token), true);
        bridgeA.setBridgeableToken(EID_B, address(token), true);
        bridgeA.setRemoteToken(EID_B, address(token), address(token));

        // A peer must be set or _quote()/_lzSend() would revert with NoPeer
        // before ever reaching our new guard in a would-be-successful call;
        // for the negative (payInLzToken=true) test this isn't strictly
        // required since the new require() reverts first, but the positive
        // control (payInLzToken=false) needs it to actually succeed.
        bridgeA.setPeer(EID_B, bytes32(uint256(uint160(address(0xB0B1D9E)))));

        token.transfer(alice, 10_000 ether);
        vm.prank(alice);
        token.approve(address(bridgeA), type(uint256).max);
        vm.deal(alice, 10 ether);
    }

    /// @dev Core regression: payInLzToken=true must revert, and must revert
    ///      BEFORE any state changes (token pull, fee transfer, LZ send) —
    ///      i.e. the guard is the very first thing bridgeTokens does.
    function test_RevertsWhenPayInLzTokenTrue() public {
        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(bytes("MagnetaBridgeOApp: LZ token payment not supported"));
        bridgeA.bridgeTokens{value: 1 ether}(
            address(token),
            100 ether,
            EID_B,
            alice,
            bytes(""),
            true // payInLzToken
        );

        // No tokens were pulled from alice — the revert happened before any
        // transfer, not mid-way through a partially-applied LZ-token charge.
        assertEq(token.balanceOf(alice), aliceBalBefore);
    }

    /// @dev Positive control: the ordinary native-fee path is unaffected by
    ///      the new guard — payInLzToken=false still bridges successfully.
    function test_SucceedsWhenPayInLzTokenFalse() public {
        uint256 amount = 100 ether;

        vm.prank(alice);
        bridgeA.bridgeTokens{value: 1 ether}(
            address(token),
            amount,
            EID_B,
            alice,
            bytes(""),
            false // payInLzToken
        );

        // 0.1% default fee for a non-Ethereum route; the rest was sent
        // cross-chain (held by the bridge as the "transferred" amount).
        uint256 expectedFee = (amount * 10) / 10_000;
        assertEq(token.balanceOf(feeRecipient), expectedFee);
    }

    /// @dev `estimateBridgeFee` is a read-only quoting helper and is
    ///      intentionally NOT restricted by the F-10 fix — it still accepts
    ///      payInLzToken=true so a caller/UI can see a real quote reflecting
    ///      that `bridgeTokens` will reject that mode, without the estimate
    ///      call itself reverting.
    function test_EstimateBridgeFeeStillAcceptsPayInLzTokenTrue() public view {
        (uint256 nativeFee, ) = bridgeA.estimateBridgeFee(EID_B, bytes(""), true);
        assertGt(nativeFee, 0);
    }
}
