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

/// @dev Minimal LayerZero endpoint: enough for OApp construction, quoting and
///      sending. `send` is payable and keeps whatever the OApp forwards, which
///      is what makes the overpayment refund observable at the gateway.
contract LzEndpointStub {
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

contract CctpStub {
    function depositForBurn(uint256 amount, uint32, bytes32, address token)
        external returns (uint64)
    {
        MockERC20(token).transferFrom(msg.sender, address(this), amount);
        return 1;
    }
}

/// @dev Stand-in module that pulls only HALF of whatever allowance the
///      gateway granted it — exactly what "a module consuming less than the
///      full bridged amount" looks like. Used to make the stale-allowance
///      defect (and its fix) observable.
contract PartialConsumerModule {
    IERC20 public immutable token;
    constructor(IERC20 _token) { token = _token; }
    function execute(IModule.Context calldata, bytes calldata) external payable returns (bytes memory) {
        uint256 allowed = token.allowance(msg.sender, address(this));
        token.transferFrom(msg.sender, address(this), allowed / 2);
        return "";
    }
}

contract GatewayHardeningTest is Test {
    MagnetaGateway gw;
    LzEndpointStub lz;
    CctpStub cctp;
    MockERC20 usdc;

    uint32 constant DST_EID = 30110;   // Arbitrum
    address constant FEE_VAULT = address(0xFEE0);

    function setUp() public {
        lz   = new LzEndpointStub();
        usdc = new MockERC20("USD Coin", "USDC", 6, 0);
        cctp = new CctpStub();

        gw = new MagnetaGateway(address(lz), address(this), FEE_VAULT);
        gw.setRequiredDVNCount(2);
    }

    // ── An unconfigured CCTP domain used to mean "Ethereum" ───────────────

    /// A Solidity mapping answers 0 for an absent key, and CCTP domain 0 is
    /// Ethereum — a real destination. An EID with no mapping therefore burned
    /// USDC toward Ethereum while the LayerZero message went to the intended
    /// chain, leaving the destination op pending with no funds.
    function test_UnconfiguredCctpDomainIsRefusedNotTreatedAsEthereum() public {
        assertEq(gw.eidToCctpDomain(DST_EID), 0, "precondition: mapping answers zero");
        assertFalse(gw.cctpDomainConfigured(DST_EID), "precondition: never configured");

        vm.expectRevert(
            abi.encodeWithSelector(MagnetaGateway.CctpDomainNotConfigured.selector, DST_EID)
        );
        gw.cctpDomainOf(DST_EID);
    }

    function test_ConfiguredDomainZeroStillResolves() public {
        // Ethereum really is domain 0 — configuring it must keep working.
        gw.setEidCctpDomain(DST_EID, 0);
        assertTrue(gw.cctpDomainConfigured(DST_EID), "explicit configuration lost");
        assertEq(gw.cctpDomainOf(DST_EID), 0, "explicit zero must resolve");
    }

    // ── USDC rotation while operations are pending ────────────────────────

    /// A pending op records the token live when its LZ message arrived, but
    /// `totalEarmarked` is one counter and rescueERC20 only guards it for the
    /// CURRENT usdc. Rotating with ops pending makes the old token fully
    /// rescuable — including funds owed to those ops.
    function test_UsdcRotationIsRefusedWhileOpsArePending() public {
        MockERC20 newUsdc = new MockERC20("USDC2", "USDC2", 6, 0);

        // No pending ops: rotation is allowed.
        gw.setUsdc(address(newUsdc));

        _setPendingCount(1);
        vm.expectRevert(
            abi.encodeWithSelector(MagnetaGateway.UsdcRotationWithPendingOps.selector, uint256(1))
        );
        gw.setUsdc(address(usdc));

        _setPendingCount(0);
        gw.setUsdc(address(usdc));            // drains, then rotation is fine again
    }

    /// Write pendingValueOpCount directly. Creating a real pending op needs a
    /// verified LayerZero receive, which is not what this test is about.
    function _setPendingCount(uint256 n) internal {
        for (uint256 slot = 0; slot < 40; slot++) {
            if (uint256(vm.load(address(gw), bytes32(slot))) == gw.pendingValueOpCount()
                && _probeSlot(slot, n)) return;
        }
        revert("pendingValueOpCount slot not found");
    }

    function _probeSlot(uint256 slot, uint256 n) internal returns (bool) {
        bytes32 before = vm.load(address(gw), bytes32(slot));
        vm.store(address(gw), bytes32(slot), bytes32(n));
        if (gw.pendingValueOpCount() == n) return true;
        vm.store(address(gw), bytes32(slot), before);
        return false;
    }

    // ── Native overpayment on the two single-leg sends ────────────────────
    //
    // `_payNative` deliberately accepts msg.value ABOVE the quoted fee (so a
    // quote that drifts between simulation and inclusion does not revert) and
    // forwards only the fee to the LZ endpoint. The fan-out paths already
    // refunded the remainder; these two single-leg sends did not, so every
    // ordinary user who over-sent left the difference stuck in the gateway,
    // recoverable only by the owner via rescueETH. Found beyond the two items
    // this port was originally scoped to — same commit (45c8f920), same
    // defect class, no conflict with any audit remediation in this tree.

    function test_OverpaidNativeIsRefundedOnSingleLegSend() public {
        gw.setUsdc(address(usdc));
        gw.setCrossChainFees(0, 0); // skip the USDC command fee entirely
        gw.setPeer(DST_EID, bytes32(uint256(uint160(address(0xC0DE)))));

        address user = makeAddr("commandSender");
        uint256 fee = lz.nativeFee();
        uint256 sent = fee * 2;
        vm.deal(user, sent);

        vm.prank(user);
        gw.sendCrossChainOp{value: sent}(DST_EID, IMagnetaGateway.OpType.CREATE_LP, "", "");

        assertEq(user.balance, fee, "overpayment not refunded on command send");
    }

    function test_OverpaidNativeIsRefundedOnValueOpSend() public {
        gw.setUsdc(address(usdc));
        gw.setCrossChainFees(0, 0);
        gw.setCctp(address(cctp), 0);
        gw.setEidCctpDomain(DST_EID, 3);
        gw.setPeer(DST_EID, bytes32(uint256(uint160(address(0xC0DE)))));

        address user = makeAddr("valueOpSender");
        uint256 usdcAmount = 1_000e6;
        usdc.mint(user, usdcAmount);

        uint256 fee = lz.nativeFee();
        uint256 sent = fee * 2;
        vm.deal(user, sent);

        vm.startPrank(user);
        usdc.approve(address(gw), usdcAmount);
        gw.sendCrossChainValueOp{value: sent}(
            DST_EID, IMagnetaGateway.OpType.CREATE_LP, "", usdcAmount, ""
        );
        vm.stopPrank();

        assertEq(user.balance, fee, "overpayment not refunded on value-op send");
    }

    // ── fulfillValueOp used to leave a standing allowance ──────────────────

    /// forceApprove granted the module the FULL bridged amount; a module that
    /// consumed less left a standing allowance against the gateway's balance
    /// — which holds USDC earmarked for OTHER pending operations.
    function test_FulfillValueOpClearsResidualAllowance() public {
        // _lzReceive stores THIS gateway's configured `usdc` as the pending
        // op's bridgedToken (CCTP mints local USDC on the destination), not
        // whatever address the source chain encoded — so it must be set.
        gw.setUsdc(address(usdc));

        uint32 srcEid = 30184;
        bytes32 peer = bytes32(uint256(uint160(address(0xBEEF))));
        gw.setPeer(srcEid, peer);

        PartialConsumerModule module = new PartialConsumerModule(IERC20(address(usdc)));
        gw.setModule(IMagnetaGateway.OpType.CREATE_LP, address(module));

        uint256 bridgedAmount = 1_000e6;
        bytes memory payload = abi.encode(
            uint8(1), IMagnetaGateway.OpType.CREATE_LP, address(this), bytes(""),
            address(usdc), bridgedAmount
        );
        bytes32 guid = keccak256("test-guid-1");

        vm.prank(address(lz));
        gw.lzReceive(Origin({srcEid: srcEid, sender: peer, nonce: 1}), guid, payload, address(0), "");

        // Simulate the CCTP mint landing on the gateway.
        usdc.mint(address(gw), bridgedAmount);

        gw.fulfillValueOp(guid);

        assertEq(
            usdc.allowance(address(gw), address(module)), 0,
            "module's unused allowance against the gateway's balance was not cleared"
        );
    }
}
