// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/LPModule.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";
import "../contracts/interfaces/IModule.sol";
import "../contracts/mocks/MockV2Router.sol";
import "../contracts/mocks/MockWETH.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PartialFillRouter, TestToken, TestUSDC, GatewayStub} from "./LPModuleInvariants.t.sol";

/// @dev Native-only recipient whose acceptance of native currency is
///     switchable — lets a single test exercise the full F17 lifecycle:
///     push fails while rejecting -> credited to pendingRefunds -> withdraws
///     once it starts accepting.
contract SwitchableRecipient {
    bool public accept;

    function setAccept(bool a) external {
        accept = a;
    }

    function withdraw(LPModule mod) external {
        mod.withdrawPendingRefund();
    }

    receive() external payable {
        require(accept, "SwitchableRecipient: rejecting");
    }
}

/// @dev Gateway stub whose advertised DVN quorum can change after
///     construction — needed to prove execute() re-reads it (F4), unlike a
///     fixed constant that only reflects the deploy-time value.
contract MutableGatewayStub {
    uint8 public dvnCount = 2;

    function setDvnCount(uint8 c) external {
        dvnCount = c;
    }

    function requiredDVNCount() external view returns (uint8) {
        return dvnCount;
    }

    function call(address module, IModule.Context memory ctx, bytes memory params)
        external
        payable
        returns (bytes memory)
    {
        return IModule(module).execute{value: msg.value}(ctx, params);
    }

    receive() external payable {}
}

/// @dev Like MockV2Router but addLiquidityETH only partially fills the
///     native side, so _createLPFromBridgedUsdc's native-dust refund branch
///     (the second F17 site, ~lines 461-465) is actually reachable — a
///     router that always consumes 100% of what it's offered can never
///     strand dust there.
contract BridgedDustRouter {
    using SafeERC20 for IERC20;

    address public immutable wnative;
    uint16 public fillBps = 10_000;
    MockLPToken public pair;

    constructor(address _wnative) {
        wnative = _wnative;
    }

    function setFillBps(uint16 bps) external {
        fillBps = bps > 10_000 ? 10_000 : bps;
    }

    function WETH() external view returns (address) {
        return wnative;
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint /*amountOutMin*/,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external returns (uint[] memory amounts) {
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn; // 1:1, exact fill
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).safeTransfer(to, amountIn);
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint /*amountTokenMin*/,
        uint /*amountETHMin*/,
        address to,
        uint /*deadline*/
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        if (address(pair) == address(0)) pair = new MockLPToken(address(this));

        amountToken = amountTokenDesired;                 // token side fully consumed
        amountETH = (msg.value * fillBps) / 10_000;        // native side PARTIALLY consumed

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);
        liquidity = amountToken + amountETH;
        pair.mint(to, liquidity);

        if (msg.value > amountETH) {
            (bool ok, ) = msg.sender.call{value: msg.value - amountETH}("");
            require(ok, "BridgedDustRouter: refund failed");
        }
    }

    receive() external payable {}
}

/// @notice Regression tests for the Sentinelle audit-13 remediation of
///         LPModule — F4 (stale DVN quorum check), F17 (native dust refund
///         reverting a completed op) and F21 (missing msg.value == 0 guard
///         on the bridged-USDC branch).
contract LPModuleHardeningTest is Test {
    LPModule mod;
    GatewayStub gw;
    TestToken token;
    TestUSDC usdc;
    PartialFillRouter router;
    MockWETH weth;
    SwitchableRecipient recipient;
    address constant FEE_VAULT = address(0xFEE0);
    address constant MAGNETA_SWAP = address(0x5AAA);

    function setUp() public {
        weth = new MockWETH();
        router = new PartialFillRouter(address(weth));
        token = new TestToken();
        usdc = new TestUSDC();
        gw = new GatewayStub();
        recipient = new SwitchableRecipient();

        mod = new LPModule(address(gw), address(router), address(usdc), MAGNETA_SWAP);

        token.transfer(address(recipient), 1e26);
        vm.prank(address(recipient));
        token.approve(address(mod), type(uint256).max);
    }

    function _ctx() internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: address(recipient),
            originChainId: block.chainid,
            feeVault: FEE_VAULT,
            tokenSource: address(0)
        });
    }

    /// F17 (local site, ~lines 528-539 `_refundDust`): a native dust refund
    /// push that fails must credit pendingRefunds instead of reverting the
    /// whole (already completed) LP operation. Before the fix this whole
    /// call would revert with "native refund failed" and the LP add would
    /// never happen at all.
    function test_CreateLp_RejectingRecipient_CreditsThenWithdraws() public {
        router.setFillBps(5000); // half-fill => guaranteed native leftover

        uint256 tokenAmount = 1e20;
        uint256 ethAmount = 1 ether;
        uint256 expectedDust = ethAmount / 2;

        LPModule.CreateLPParams memory p = LPModule.CreateLPParams({
            token: address(token),
            tokenAmount: tokenAmount,
            ethAmount: ethAmount,
            amountTokenMin: 0,
            amountETHMin: 0,
            usdcFee: 0,
            deadline: block.timestamp + 1000
        });

        vm.deal(address(gw), ethAmount);
        // Recipient starts REJECTING native. Must NOT revert.
        gw.call{value: ethAmount}(
            address(mod), _ctx(),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );

        assertEq(
            mod.pendingRefunds(address(recipient)), expectedDust,
            "F17: failed native dust push was not credited to pendingRefunds"
        );
        assertEq(
            address(mod).balance, expectedDust,
            "F17: module should be holding the credited dust pending withdrawal"
        );

        // Still rejecting: withdrawal must fail cleanly and leave the credit
        // untouched (the push failure inside withdrawPendingRefund reverts
        // the whole call, so no partial state change survives).
        vm.expectRevert(bytes("LPModule: withdraw failed"));
        recipient.withdraw(mod);
        assertEq(mod.pendingRefunds(address(recipient)), expectedDust, "credit must survive a failed withdraw attempt");

        // Flip to accepting and withdraw the credited dust.
        recipient.setAccept(true);
        uint256 balBefore = address(recipient).balance;
        recipient.withdraw(mod);

        assertEq(address(recipient).balance, balBefore + expectedDust, "F17: withdrawPendingRefund did not pay out");
        assertEq(mod.pendingRefunds(address(recipient)), 0, "F17: pendingRefunds not cleared after withdrawal");
        assertEq(address(mod).balance, 0, "F17: module still holding native after withdrawal");
    }

    /// F21: the bridged-USDC branch must reject any attached native value —
    /// its dust accounting only tracks WETH withdrawn during the op, so a
    /// forwarded msg.value would be silently absorbed as "dust" and refunded
    /// as if it had come from the swap.
    function test_CreateLPFromBridgedUsdc_RevertsIfMsgValueNonZero() public {
        LPModule.CrossChainLPParams memory p = LPModule.CrossChainLPParams({
            token: address(token),
            usdcTotal: 1_000e6,
            tokenShareBps: 5000,
            amountTokenMin: 0,
            amountNativeMin: 0,
            lpAmountTokenMin: 0,
            lpAmountNativeMin: 0,
            deadline: block.timestamp + 1000
        });

        IModule.Context memory ctx = IModule.Context({
            caller: address(recipient),
            originChainId: block.chainid,
            feeVault: FEE_VAULT,
            tokenSource: address(gw) // non-zero => bridged branch
        });

        vm.deal(address(gw), 1 ether);
        vm.expectRevert(bytes("LPModule: no native for bridged LP"));
        gw.call{value: 1 ether}(
            address(mod), ctx,
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );
    }

    /// F4: execute() must re-read the gateway's CURRENT DVN quorum for any
    /// cross-chain op, not just trust the constructor-time check. Here the
    /// quorum is 2 (valid) at construction, then drops to 1 afterwards.
    function test_Execute_RevertsCrossChainOpWhenGatewayQuorumDrops() public {
        MutableGatewayStub gw2 = new MutableGatewayStub();
        LPModule mod2 = new LPModule(address(gw2), address(router), address(usdc), MAGNETA_SWAP);

        gw2.setDvnCount(1); // quorum degraded post-deployment

        IModule.Context memory ctx = IModule.Context({
            caller: address(recipient),
            originChainId: block.chainid + 1, // != block.chainid => cross-chain
            feeVault: FEE_VAULT,
            tokenSource: address(0)
        });

        // A single valid opcode byte is enough — the guard fires before the
        // op-specific payload is ever decoded.
        bytes memory params = abi.encodePacked(uint8(IMagnetaGateway.OpType.REMOVE_LP));

        vm.expectRevert(LPModule.DVNQuorumBelowMinimum.selector);
        gw2.call(address(mod2), ctx, params);
    }

    /// F4 (negative control): a LOCAL op (originChainId == block.chainid) is
    /// untouched by a degraded gateway quorum — the guard only applies to
    /// ops that actually traversed a bridge.
    function test_Execute_LocalOpUnaffectedByGatewayQuorumDrop() public {
        MutableGatewayStub gw2 = new MutableGatewayStub();
        LPModule mod2 = new LPModule(address(gw2), address(router), address(usdc), MAGNETA_SWAP);
        gw2.setDvnCount(1); // degraded, but irrelevant for a local op

        token.transfer(address(recipient), 1e20);
        vm.prank(address(recipient));
        token.approve(address(mod2), type(uint256).max);

        LPModule.CreateLPParams memory p = LPModule.CreateLPParams({
            token: address(token), tokenAmount: 1e20, ethAmount: 1 ether,
            amountTokenMin: 0, amountETHMin: 0, usdcFee: 0, deadline: block.timestamp + 1000
        });
        IModule.Context memory ctx = IModule.Context({
            caller: address(recipient), originChainId: block.chainid,
            feeVault: FEE_VAULT, tokenSource: address(0)
        });

        vm.deal(address(gw2), 1 ether);
        // NOT wrapped in try/catch: must succeed despite the degraded quorum.
        gw2.call{value: 1 ether}(
            address(mod2), ctx,
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );
    }
}

/// @notice F17 (cross-chain site, ~lines 456-465 `_createLPFromBridgedUsdc`):
///         same pull-payment fallback, exercised on the bridged path itself
///         rather than the shared `_refundDust` helper.
contract LPModuleBridgedDustRefundTest is Test {
    LPModule mod;
    GatewayStub gw;
    TestToken token;
    TestUSDC usdc;
    BridgedDustRouter router;
    MockWETH weth;
    SwitchableRecipient recipient;
    address constant FEE_VAULT = address(0xFEE0);
    address constant MAGNETA_SWAP = address(0x5AAA);

    function setUp() public {
        weth = new MockWETH();
        router = new BridgedDustRouter(address(weth));
        token = new TestToken();
        usdc = new TestUSDC();
        gw = new GatewayStub();
        recipient = new SwitchableRecipient();

        mod = new LPModule(address(gw), address(router), address(usdc), MAGNETA_SWAP);

        // Fund the router with what it pays out: WNATIVE for the USDC->WNATIVE
        // hop, and `token` for the USDC->WNATIVE->token hop.
        weth.mint(address(router), 1_000e18);
        token.transfer(address(router), 1_000e18);
        // MockWETH.withdraw() needs real native backing to pay the module.
        vm.deal(address(weth), 1_000 ether);

        // ctx.tokenSource == address(gw): the gateway holds the bridged USDC.
        usdc.transfer(address(gw), 1_000_000e6);
        vm.prank(address(gw));
        usdc.approve(address(mod), type(uint256).max);
    }

    function test_CreateLPFromBridgedUsdc_RejectingRecipient_CreditsThenWithdraws() public {
        router.setFillBps(4000); // 40% native fill => 60% guaranteed leftover

        LPModule.CrossChainLPParams memory p = LPModule.CrossChainLPParams({
            token: address(token),
            usdcTotal: 1_000e6,
            tokenShareBps: 5000,
            amountTokenMin: 0,
            amountNativeMin: 0,
            lpAmountTokenMin: 0,
            lpAmountNativeMin: 0,
            deadline: block.timestamp + 1000
        });

        IModule.Context memory ctx = IModule.Context({
            caller: address(recipient),
            originChainId: block.chainid,
            feeVault: FEE_VAULT,
            tokenSource: address(gw)
        });

        // Recipient rejects native. Must NOT revert (msg.value is correctly
        // 0 for this branch per F21 — the native side comes entirely from
        // the USDC->WNATIVE swap unwound inside the module).
        gw.call(
            address(mod), ctx,
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );

        uint256 credited = mod.pendingRefunds(address(recipient));
        assertGt(credited, 0, "F17 (bridged): expected native dust to be credited, got 0");
        assertEq(address(mod).balance, credited, "F17 (bridged): module should be holding the credited dust");

        recipient.setAccept(true);
        uint256 balBefore = address(recipient).balance;
        recipient.withdraw(mod);

        assertEq(address(recipient).balance, balBefore + credited, "F17 (bridged): withdrawal did not pay out");
        assertEq(mod.pendingRefunds(address(recipient)), 0, "F17 (bridged): pendingRefunds not cleared");
    }
}
