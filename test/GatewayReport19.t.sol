// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MagnetaGateway} from "../contracts/core/MagnetaGateway.sol";
import {IMagnetaGateway} from "../contracts/interfaces/IMagnetaGateway.sol";
import {IModule} from "../contracts/interfaces/IModule.sol";
import {MockERC20} from "../contracts/tokens/MockERC20.sol";
import {Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessagingParams, MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @dev Minimal LayerZero endpoint — enough for OApp construction, quoting and
///      sending. Mirrors the stub in GatewayHardening.t.sol.
contract LzEndpointStub19 {
    uint32 public constant EID = 30101;
    uint256 public nativeFee = 0.01 ether;

    function eid() external pure returns (uint32) { return EID; }
    function setDelegate(address) external {}
    function setConfig(address, address, bytes calldata) external {}
    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, 0);
    }
    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory) {
        return MessagingReceipt(
            keccak256(abi.encode(block.number, msg.value)), 1, MessagingFee(msg.value, 0)
        );
    }
    receive() external payable {}
}

contract CctpStub19 {
    function depositForBurn(uint256 amount, uint32, bytes32, address token)
        external returns (uint64)
    {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        return 1;
    }
}

/// @dev Pulls the FULL allowance the gateway granted — a normal, well-behaved
///      module. This is what makes one op's spend visible against the pooled
///      balance in the F-3 tests.
contract FullConsumerModule {
    IERC20 public immutable token;
    constructor(IERC20 _token) { token = _token; }
    function execute(IModule.Context calldata, bytes calldata) external payable returns (bytes memory) {
        uint256 allowed = token.allowance(msg.sender, address(this));
        if (allowed > 0) token.transferFrom(msg.sender, address(this), allowed);
        return "";
    }
}

/// @notice Report-19 findings against MagnetaGateway: F-3 (unattributed
///         fungible pool), F-15 (zero-amount record bricks setUsdc), F-16
///         (unknown payload version silently consumed), F-2 (DVN quorum
///         floor), F-18 (uncapped, non-clamping fee ceiling), F-13 (zero
///         value fee bills the command fee), F-17 (admin clear masquerades
///         as a fulfilment).
contract GatewayReport19Test is Test {
    MagnetaGateway gw;
    LzEndpointStub19 lz;
    CctpStub19 cctp;
    MockERC20 usdc;
    FullConsumerModule module;

    uint32 constant SRC_EID = 30184;   // Base
    uint32 constant DST_EID = 30110;   // Arbitrum
    address constant FEE_VAULT = address(0xFEE0);
    bytes32 constant SRC_PEER = bytes32(uint256(uint160(address(0xBEEF))));

    address alice = makeAddr("alice");   // caller of value op A
    address bob   = makeAddr("bob");     // caller of value op B

    bytes32 constant GUID_A = keccak256("report19-A");
    bytes32 constant GUID_B = keccak256("report19-B");

    uint256 constant LEG = 1_000e6;      // 1000 USDC per bridged leg

    function setUp() public {
        lz   = new LzEndpointStub19();
        usdc = new MockERC20("USD Coin", "USDC", 6, 0);
        cctp = new CctpStub19();

        gw = new MagnetaGateway(address(lz), address(this), FEE_VAULT);
        gw.setRequiredDVNCount(2);
        gw.setUsdc(address(usdc));
        gw.setPeer(SRC_EID, SRC_PEER);

        module = new FullConsumerModule(IERC20(address(usdc)));
        gw.setModule(IMagnetaGateway.OpType.CREATE_LP, address(module));
    }

    // ── helpers ───────────────────────────────────────────────────────────

    function _valuePayload(address caller, uint256 amount) internal view returns (bytes memory) {
        return abi.encode(
            uint8(1), IMagnetaGateway.OpType.CREATE_LP, caller, bytes(""), address(usdc), amount
        );
    }

    function _receive(bytes32 guid, bytes memory payload) internal {
        vm.prank(address(lz));
        gw.lzReceive(Origin({srcEid: SRC_EID, sender: SRC_PEER, nonce: 1}), guid, payload, address(0), "");
    }

    /// Queue two independent value ops of `LEG` each, from two different users.
    function _queueTwoOps() internal {
        _receive(GUID_A, _valuePayload(alice, LEG));
        _receive(GUID_B, _valuePayload(bob, LEG));
        assertEq(gw.totalEarmarked(), 2 * LEG, "both legs must be earmarked");
        assertEq(gw.pendingValueOpCount(), 2, "both ops must be pending");
    }

    // ══════════════════════════════════════════════════════════════════════
    // F-3 — bridged funds were an unattributed fungible pool
    // ══════════════════════════════════════════════════════════════════════

    /// Alice's and Bob's ops are each earmarked for 1000 USDC, but only ONE
    /// leg's worth ever lands (Bob's CCTP attestation is lost). Under the F38
    /// per-op check, Alice's op was fulfillable — spending the USDC that Circle
    /// minted for Bob — after which Bob's op reverted "tokens not arrived"
    /// although his funds had in fact arrived. The loss was socialised onto an
    /// innocent third party. The earmark invariant must now refuse to serve
    /// either op while the pool cannot cover both.
    function test_F3_OpCannotBeServedWithAnotherOpsBridgedFunds() public {
        _queueTwoOps();

        // Only one leg lands.
        usdc.mint(address(gw), LEG);

        // Alice's own bridgedAmount IS present — the old check passed on this
        // exact state. The earmark check is what refuses it.
        assertGe(usdc.balanceOf(address(gw)), LEG, "precondition: A's own amount is present");

        vm.expectRevert(
            abi.encodeWithSelector(MagnetaGateway.EarmarkUnderfunded.selector, LEG, 2 * LEG)
        );
        gw.fulfillValueOp(GUID_A);

        // Nothing was consumed, and Bob's earmark is intact.
        assertEq(usdc.balanceOf(address(gw)), LEG, "balance must be untouched");
        assertEq(gw.totalEarmarked(), 2 * LEG, "earmarks must be untouched");
        assertEq(gw.pendingValueOpCount(), 2, "no op may be dropped");
    }

    /// Both legs present: business as usual. The invariant must not block the
    /// healthy path.
    function test_F3_FullyFundedQueueStillFulfills() public {
        _queueTwoOps();
        usdc.mint(address(gw), 2 * LEG);

        gw.fulfillValueOp(GUID_A);
        assertEq(gw.totalEarmarked(), LEG, "A's earmark must be released");

        gw.fulfillValueOp(GUID_B);
        assertEq(gw.totalEarmarked(), 0, "B's earmark must be released");
        assertEq(gw.pendingValueOpCount(), 0, "queue must be empty");
        assertEq(usdc.balanceOf(address(module)), 2 * LEG, "module must have received both legs");
    }

    /// The liveness escape hatch F38 was missing. Bob's leg is lost forever;
    /// the operator tops the gateway up out of treasury, refunds Bob on-chain,
    /// and Alice's op — whose funds really did arrive — proceeds.
    function test_F3_AdminRefundUnblocksTheQueue() public {
        _queueTwoOps();
        usdc.mint(address(gw), LEG);             // only Alice's leg landed

        // Operator absorbs the bridge loss by topping the gateway up.
        usdc.mint(address(gw), LEG);

        gw.adminRefundPendingValueOp(GUID_B);

        assertEq(usdc.balanceOf(bob), LEG, "Bob must be made whole on-chain");
        assertEq(gw.totalEarmarked(), LEG, "only Alice's earmark must remain");
        assertEq(gw.pendingValueOpCount(), 1, "only Alice's op must remain");

        // Alice's op now goes through.
        gw.fulfillValueOp(GUID_A);
        assertEq(gw.totalEarmarked(), 0, "queue must settle");
        assertEq(usdc.balanceOf(address(module)), LEG, "Alice's leg must reach the module");
    }

    /// The refund is a real transfer, not an accounting gesture: if the gateway
    /// cannot pay, it reverts and the operator must fund it first. This is what
    /// stops the operator from clearing the queue at a user's expense.
    function test_F3_RefundRevertsWhenGatewayCannotPay() public {
        _queueTwoOps();
        // Nothing arrived at all.
        assertEq(usdc.balanceOf(address(gw)), 0, "precondition: gateway is empty");

        vm.expectRevert();
        gw.adminRefundPendingValueOp(GUID_B);

        assertEq(gw.pendingValueOpCount(), 2, "a failed refund must not drop the op");
        assertEq(gw.totalEarmarked(), 2 * LEG, "a failed refund must not release the earmark");
    }

    function test_F3_RefundIsOwnerGated() public {
        _queueTwoOps();
        usdc.mint(address(gw), 2 * LEG);

        vm.prank(alice);
        vm.expectRevert();
        gw.adminRefundPendingValueOp(GUID_B);
    }

    function test_F3_RefundEmitsItsOwnEvent() public {
        _receive(GUID_A, _valuePayload(alice, LEG));
        usdc.mint(address(gw), LEG);

        vm.recordLogs();
        gw.adminRefundPendingValueOp(GUID_A);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool refunded;
        bytes32 fulfilledSig = keccak256("ValueOpFulfilled(bytes32,uint8,address)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0) {
                if (logs[i].topics[0] == keccak256("ValueOpRefunded(bytes32,uint8,address,address,uint256)")) {
                    refunded = true;
                }
                assertTrue(logs[i].topics[0] != fulfilledSig, "a refund must not look like a fulfilment");
            }
        }
        assertTrue(refunded, "ValueOpRefunded must be emitted");
    }

    // ══════════════════════════════════════════════════════════════════════
    // F-15 — a zero-amount record used to brick setUsdc forever
    // ══════════════════════════════════════════════════════════════════════

    /// The version-1 path accepted bridgedAmount == 0 and counted it. Both
    /// exits tested `bridgedAmount > 0` for existence, so the record could
    /// never be removed — not even by the owner — and setUsdc, which refuses
    /// to rotate while pendingValueOpCount > 0, reverted for the life of the
    /// contract.
    function test_F15_ZeroAmountValueOpIsRefusedAtReceipt() public {
        vm.expectRevert(MagnetaGateway.ZeroBridgedAmount.selector);
        _receive(GUID_A, _valuePayload(alice, 0));

        assertEq(gw.pendingValueOpCount(), 0, "no phantom record may be counted");
        // Rolling back the revert also rolls back the GUID consumption, so a
        // corrected message may still be delivered.
        assertFalse(gw.processedGuid(GUID_A), "the GUID must stay replayable");
    }

    /// The end-to-end consequence: USDC rotation stays possible.
    function test_F15_SetUsdcSurvivesAZeroAmountAttempt() public {
        vm.expectRevert(MagnetaGateway.ZeroBridgedAmount.selector);
        _receive(GUID_A, _valuePayload(alice, 0));

        MockERC20 newUsdc = new MockERC20("USDC2", "USDC2", 6, 0);
        gw.setUsdc(address(newUsdc));    // used to revert forever
        assertEq(address(gw.usdc()), address(newUsdc), "rotation must succeed");
    }

    /// Existence is now `createdAt != 0`, so any structurally present record is
    /// erasable by the owner regardless of its amount.
    function test_F15_ExistenceMarkerIsCreatedAtNotAmount() public {
        _receive(GUID_A, _valuePayload(alice, LEG));

        (,,,,, uint256 createdAt) = gw.pendingValueOps(GUID_A);
        assertTrue(createdAt != 0, "createdAt must mark presence");

        gw.adminClearPendingValueOp(GUID_A);

        (,,,,, uint256 clearedAt) = gw.pendingValueOps(GUID_A);
        assertEq(clearedAt, 0, "clearing must reset the marker");

        vm.expectRevert(MagnetaGateway.NoPendingOp.selector);
        gw.adminClearPendingValueOp(GUID_A);
    }

    // ══════════════════════════════════════════════════════════════════════
    // F-16 — an unknown payload version was consumed in silence
    // ══════════════════════════════════════════════════════════════════════

    /// processedGuid is written BEFORE the version dispatch, and the if/else-if
    /// had no else. An authenticated version-2 payload therefore returned
    /// normally: the LayerZero message was burned for good, nothing executed,
    /// nothing recorded, no event. It must revert so the message stays
    /// replayable after an upgrade.
    function test_F16_UnknownPayloadVersionRevertsAndStaysReplayable() public {
        bytes memory v2 = abi.encode(
            uint8(2), IMagnetaGateway.OpType.CREATE_LP, alice, bytes(""), address(usdc), LEG
        );

        vm.expectRevert(
            abi.encodeWithSelector(MagnetaGateway.UnsupportedPayloadVersion.selector, uint8(2))
        );
        _receive(GUID_A, v2);

        assertFalse(gw.processedGuid(GUID_A), "the message must not be consumed");
        assertEq(gw.pendingValueOpCount(), 0, "nothing may be recorded");
    }

    function test_F16_KnownVersionsStillDispatch() public {
        // version 0 — command op, executes immediately
        _receive(GUID_A, abi.encode(uint8(0), IMagnetaGateway.OpType.CREATE_LP, alice, bytes("")));
        assertTrue(gw.processedGuid(GUID_A), "version 0 must be handled");

        // version 1 — value op, recorded as pending
        _receive(GUID_B, _valuePayload(bob, LEG));
        assertEq(gw.pendingValueOpCount(), 1, "version 1 must be handled");
    }

    // ══════════════════════════════════════════════════════════════════════
    // F-2 — the DVN quorum was a self-declared counter with no floor
    // ══════════════════════════════════════════════════════════════════════

    /// Six modules assert `requiredDVNCount() >= 2` as their single-validator
    /// mitigation. The setter accepted 0 and 1, letting the owner retract that
    /// attestation under every already-deployed module in one transaction.
    function test_F2_QuorumBelowTwoIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(MagnetaGateway.DvnQuorumBelowMinimum.selector, uint8(1)));
        gw.setRequiredDVNCount(1);

        vm.expectRevert(abi.encodeWithSelector(MagnetaGateway.DvnQuorumBelowMinimum.selector, uint8(0)));
        gw.setRequiredDVNCount(0);

        assertEq(gw.requiredDVNCount(), 2, "the attestation must survive the attempts");
    }

    function test_F2_QuorumAtOrAboveTheFloorIsAccepted() public {
        gw.setRequiredDVNCount(2);
        assertEq(gw.requiredDVNCount(), 2, "the floor itself must be settable");
        gw.setRequiredDVNCount(5);
        assertEq(gw.requiredDVNCount(), 5, "raising must stay possible");
        assertEq(gw.MIN_ATTESTED_DVN_COUNT(), 2, "floor constant");
    }

    // ══════════════════════════════════════════════════════════════════════
    // F-18 — the fee ceiling was uncapped and did not clamp
    // ══════════════════════════════════════════════════════════════════════

    /// An owner-settable bound with no bound of its own guards nothing: raise
    /// it, then charge it.
    function test_F18_FeeCeilingIsItselfCapped() public {
        uint256 cap = gw.MAX_OP_SERVICE_FEE_NATIVE_CAP();

        vm.expectRevert(
            abi.encodeWithSelector(MagnetaGateway.MaxOpServiceFeeAboveCap.selector, cap + 1)
        );
        gw.setMaxOpServiceFeeNative(cap + 1);

        vm.expectRevert(
            abi.encodeWithSelector(MagnetaGateway.MaxOpServiceFeeAboveCap.selector, type(uint256).max)
        );
        gw.setMaxOpServiceFeeNative(type(uint256).max);

        gw.setMaxOpServiceFeeNative(cap);        // the cap itself is reachable
        assertEq(gw.maxOpServiceFeeNative(), cap, "cap must be settable");
    }

    /// Lowering the ceiling used to leave higher fees live — the ceiling did
    /// not describe what a user could actually be charged.
    function test_F18_LoweringTheCeilingClampsConfiguredFees() public {
        gw.setMaxOpServiceFeeNative(1 ether);
        gw.setOpServiceFeeNative(IMagnetaGateway.OpType.CREATE_LP, 0.9 ether);
        gw.setOpServiceFeeNative(IMagnetaGateway.OpType.MINT, 0.05 ether);

        gw.setMaxOpServiceFeeNative(0.1 ether);

        assertEq(
            gw.opServiceFeeNative(IMagnetaGateway.OpType.CREATE_LP), 0.1 ether,
            "a fee above the new ceiling must be clamped"
        );
        assertEq(
            gw.opServiceFeeNative(IMagnetaGateway.OpType.MINT), 0.05 ether,
            "a fee already under the ceiling must be left alone"
        );
    }

    /// The clamp must cover EVERY op in the enum, not a hard-coded prefix.
    function test_F18_ClampCoversTheWholeOpTypeEnum() public {
        gw.setMaxOpServiceFeeNative(1 ether);

        uint256 n = uint256(type(IMagnetaGateway.OpType).max) + 1;
        for (uint256 i; i < n; ++i) {
            gw.setOpServiceFeeNative(IMagnetaGateway.OpType(i), 1 ether);
        }

        gw.setMaxOpServiceFeeNative(0);

        for (uint256 i; i < n; ++i) {
            assertEq(
                gw.opServiceFeeNative(IMagnetaGateway.OpType(i)), 0,
                "an op-type escaped the clamp"
            );
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // F-13 — zeroing the value fee billed the command fee instead
    // ══════════════════════════════════════════════════════════════════════

    /// `valueUsdc6d > 0 && bps > 0` folded the RATE into the MODE test, so a
    /// value op with the value fee set to zero fell through to the command
    /// branch and was charged `crossChainCommandFee * nDestinations`.
    function test_F13_ZeroValueFeeChargesNothingOnAValueOp() public {
        gw.setCctp(address(cctp), 0);
        gw.setEidCctpDomain(DST_EID, 3);
        gw.setPeer(DST_EID, bytes32(uint256(uint160(address(0xC0DE)))));

        gw.setCrossChainFees(1_000_000, 0);   // $1 command fee, value fee OFF

        uint256 amount = 5_000e6;
        usdc.mint(alice, amount);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        usdc.approve(address(gw), type(uint256).max);
        gw.sendCrossChainValueOp{value: lz.nativeFee()}(
            DST_EID, IMagnetaGateway.OpType.CREATE_LP, "", amount, ""
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(FEE_VAULT), 0, "a zeroed value fee must cost nothing");
        assertEq(usdc.balanceOf(alice), 0, "only the bridged amount may leave the caller");
    }

    /// A non-zero value fee is still charged on the bridged amount, and a
    /// command op still pays the flat command fee — the split must not have
    /// broken either mode.
    function test_F13_ValueAndCommandModesRemainCorrect() public {
        gw.setCctp(address(cctp), 0);
        gw.setEidCctpDomain(DST_EID, 3);
        gw.setPeer(DST_EID, bytes32(uint256(uint160(address(0xC0DE)))));
        gw.setCrossChainFees(1_000_000, 15);   // $1 flat, 0.15%

        uint256 amount = 10_000e6;
        // Alice must cover the bridged amount PLUS the 15 USDC value fee PLUS
        // the 1 USDC command fee charged by the second leg of this test.
        usdc.mint(alice, amount + 100e6);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        usdc.approve(address(gw), type(uint256).max);
        gw.sendCrossChainValueOp{value: lz.nativeFee()}(
            DST_EID, IMagnetaGateway.OpType.CREATE_LP, "", amount, ""
        );
        vm.stopPrank();

        // Value mode: 0.15% of 10 000 USDC = 15 USDC, NOT the $1 command fee.
        assertEq(usdc.balanceOf(FEE_VAULT), 15e6, "value fee must be BPS on the amount");

        // Command mode: flat fee per destination.
        vm.startPrank(alice);
        gw.sendCrossChainOp{value: lz.nativeFee()}(
            DST_EID, IMagnetaGateway.OpType.CREATE_LP, "", ""
        );
        vm.stopPrank();
        assertEq(usdc.balanceOf(FEE_VAULT), 15e6 + 1_000_000, "command fee must still apply");
    }

    // ══════════════════════════════════════════════════════════════════════
    // F-17 — the admin clear masqueraded as a real fulfilment
    // ══════════════════════════════════════════════════════════════════════

    /// adminClearPendingValueOp emitted ValueOpFulfilled — the exact event of a
    /// successful execution — although no module ran and nobody was paid. An
    /// indexer booked as accomplished an op that is in fact a debt.
    function test_F17_AdminClearDoesNotEmitValueOpFulfilled() public {
        _receive(GUID_A, _valuePayload(alice, LEG));

        vm.recordLogs();
        gw.adminClearPendingValueOp(GUID_A);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool cleared;
        bytes32 fulfilledSig = keccak256("ValueOpFulfilled(bytes32,uint8,address)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != fulfilledSig, "clear must not emit ValueOpFulfilled");
            if (logs[i].topics[0] == keccak256("ValueOpCleared(bytes32,uint8,address,uint256)")) {
                cleared = true;
                // The outstanding debt must be carried in the event.
                assertEq(abi.decode(logs[i].data, (uint256)), LEG, "cleared amount must be reported");
            }
        }
        assertTrue(cleared, "ValueOpCleared must be emitted");
    }

    /// A genuine fulfilment must still emit ValueOpFulfilled — the fix must not
    /// have silenced the real signal.
    function test_F17_RealFulfilmentStillEmitsValueOpFulfilled() public {
        _receive(GUID_A, _valuePayload(alice, LEG));
        usdc.mint(address(gw), LEG);

        vm.expectEmit(true, true, true, false);
        emit ValueOpFulfilled(GUID_A, IMagnetaGateway.OpType.CREATE_LP, alice);
        gw.fulfillValueOp(GUID_A);
    }

    event ValueOpFulfilled(bytes32 indexed guid, IMagnetaGateway.OpType indexed op, address indexed caller);
}
