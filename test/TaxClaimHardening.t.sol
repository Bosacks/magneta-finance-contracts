// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/TaxClaimModule.sol";
import "../contracts/interfaces/IModule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Managed token shaped like MagnetaERC20OFT: fees accumulate on the token
///      contract and `withdrawFees()` (owner-gated there) moves them to the
///      marketing wallet — here, the module.
contract TaxToken is ERC20 {
    address public owner;
    address public marketingWallet;
    uint256 public pending;

    constructor() ERC20("Tax", "TAX") { owner = msg.sender; _mint(address(this), 1e30); }
    function setMarketingWallet(address w) external { marketingWallet = w; }
    function seedPending(uint256 a) external { pending = a; }
    function withdrawFees() external {
        uint256 a = pending; pending = 0;
        _transfer(address(this), marketingWallet, a);
    }
}

contract Usdc is ERC20 {
    constructor() ERC20("USDC", "USDC") { _mint(msg.sender, 1e30); }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev Quotes honestly, then delivers whatever `deliver` says — which is what
///      a sandwich looks like from inside the transaction. Unlike the shared
///      MockV2Router it ENFORCES amountOutMin, so the floor is observable.
contract QuotingRouter {
    address public immutable wethAddr;
    Usdc public immutable usdc;
    uint256 public quote;      // what getAmountsOut reports
    uint256 public deliver;    // what the swap actually pays out

    constructor(address _weth, Usdc _usdc) { wethAddr = _weth; usdc = _usdc; }
    function WETH() external view returns (address) { return wethAddr; }
    function setQuote(uint256 q) external { quote = q; }
    function setDeliver(uint256 d) external { deliver = d; }

    function getAmountsOut(uint256, address[] calldata path)
        external view returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[path.length - 1] = quote;
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        require(deliver >= amountOutMin, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        usdc.mint(to, deliver);
        amounts = new uint256[](path.length);
        amounts[path.length - 1] = deliver;
    }
}

contract TaxGatewayStub {
    function requiredDVNCount() external pure returns (uint8) { return 2; }
    function call(address module, IModule.Context memory ctx, bytes memory params)
        external payable returns (bytes memory)
    { return IModule(module).execute{value: msg.value}(ctx, params); }
}

contract RecordingMessenger {
    bytes32 public lastRecipient;
    uint256 public lastAmount;
    uint32 public lastDomain;
    function depositForBurn(uint256 amount, uint32 dstDomain, bytes32 mintRecipient, address burnToken)
        external returns (uint64)
    {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        lastRecipient = mintRecipient; lastAmount = amount; lastDomain = dstDomain;
        return 1;
    }
}

/// @dev Accepts the call and burns nothing — an EOA-shaped or misrouted
///      messenger. The allowance survives.
contract TaxSilentMessenger {
    function depositForBurn(uint256, uint32, bytes32, address) external returns (uint64) { return 1; }
}

contract TaxClaimHardeningTest is Test {
    TaxClaimModule mod;
    TaxGatewayStub gw;
    QuotingRouter router;
    TaxToken token;
    Usdc usdc;
    address constant WETH = address(0xEEEE);
    address constant FEE_VAULT = address(0xFEE0);
    address admin = makeAddr("tokenAdmin");

    function setUp() public {
        usdc   = new Usdc();
        router = new QuotingRouter(WETH, usdc);
        gw     = new TaxGatewayStub();
        mod    = new TaxClaimModule(address(gw), address(router), address(usdc));

        token = new TaxToken();
        token.setMarketingWallet(address(mod));
        mod.registerToken(address(token), admin);
    }

    function _ctx() internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: admin, originChainId: block.chainid,
            feeVault: FEE_VAULT, tokenSource: address(0), guid: bytes32(0)
        });
    }

    function _params(bool bridge) internal view returns (bytes memory) {
        return abi.encode(TaxClaimModule.ClaimParams({
            token: address(token), amountOutMin: 0,
            deadline: block.timestamp + 1000, bridgeToTreasury: bridge,
            destinationDomain: 6
        }));
    }

    function _claim(bool bridge) internal returns (bytes memory) {
        token.seedPending(1_000e18);
        return gw.call(address(mod), _ctx(), _params(bridge));
    }

    // ── Slippage: the bound the client cannot compute ─────────────────────

    /// The production UI hard-codes amountOutMin: 0. minUsdc is an absolute $20
    /// floor, so a $1,000 claim sandwiched down to $21 used to settle happily.
    function test_SandwichedClaimRevertsOnTheProportionalFloor() public {
        router.setQuote(1_000e6);
        router.setDeliver(21e6);          // above minUsdc, ~98% below quote
        token.seedPending(1_000e18);
        // The floor is passed to the router, so the router is what rejects it.
        // Asserting the exact string keeps this test from passing on an
        // unrelated revert — a bare expectRevert() hid a bug in this very file.
        vm.expectRevert(bytes("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"));
        gw.call(address(mod), _ctx(), _params(false));
    }

    function test_AnHonestSwapWithinToleranceStillSettles() public {
        router.setQuote(1_000e6);
        router.setDeliver(980e6);         // 2% slippage, inside the 3% bound
        _claim(false);
        uint256 fee = (980e6 * uint256(mod.FEE_BPS())) / 10_000;
        assertEq(usdc.balanceOf(FEE_VAULT), fee, "fee not skimmed");
        assertEq(usdc.balanceOf(admin), 980e6 - fee, "admin underpaid");
    }

    function test_StricterCallerMinimumStillWins() public {
        router.setQuote(1_000e6);
        router.setDeliver(980e6);         // passes the module's 970e6 floor
        token.seedPending(1_000e18);
        bytes memory p = abi.encode(TaxClaimModule.ClaimParams({
            token: address(token), amountOutMin: 990e6,   // caller is stricter
            deadline: block.timestamp + 1000, bridgeToTreasury: false,
            destinationDomain: 6
        }));
        vm.expectRevert(bytes("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"));
        gw.call(address(mod), _ctx(), p);
    }

    // ── CCTP: whose money is it, and did the burn happen ──────────────────

    function test_BridgeMintsToTheAdminNotAGlobalRecipient() public {
        RecordingMessenger m = new RecordingMessenger();
        mod.setCctpRoute(address(m), 6, bytes32(uint256(uint160(address(0xBEEF)))));
        mod.setCctpDomain(6, true);
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        _claim(true);

        uint256 fee = (1_000e6 * uint256(mod.FEE_BPS())) / 10_000;
        assertEq(m.lastAmount(), 1_000e6 - fee, "wrong amount bridged");
        assertEq(
            m.lastRecipient(),
            bytes32(uint256(uint160(admin))),
            "admin's proceeds were minted to someone else"
        );
    }

    function test_BurnThatConsumesNothingRevertsAndLeavesNoAllowance() public {
        TaxSilentMessenger m = new TaxSilentMessenger();
        mod.setCctpRoute(address(m), 6, bytes32(uint256(1)));
        mod.setCctpDomain(6, true);
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        token.seedPending(1_000e18);

        vm.expectRevert(TaxClaimModule.BurnDidNotConsumeApproval.selector);
        gw.call(address(mod), _ctx(), _params(true));
    }

    function test_SetCctpRouteRejectsAnEoaMessenger() public {
        address eoa = makeAddr("notAContract");
        vm.expectRevert(abi.encodeWithSelector(TaxClaimModule.NotAContract.selector, eoa));
        mod.setCctpRoute(eoa, 6, bytes32(uint256(1)));
    }

    // ── Value that used to have no way out ────────────────────────────────

    function test_NativeValueIsRefusedRatherThanTrapped() public {
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        token.seedPending(1_000e18);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("TaxClaim: no native value expected"));
        gw.call{value: 1 ether}(address(mod), _ctx(), _params(false));
    }

    function test_DonatedTokensAreRecoverable() public {
        usdc.mint(address(mod), 500e6);              // stray donation
        mod.rescueERC20(address(usdc), address(0xCAFE), 500e6);
        assertEq(usdc.balanceOf(address(0xCAFE)), 500e6, "donation still stuck");
    }

    function test_TrappedNativeIsRecoverable() public {
        vm.deal(address(mod), 1 ether);
        mod.rescueNative(payable(address(0xCAFE)), 1 ether);
        assertEq(address(0xCAFE).balance, 1 ether, "native still stuck");
    }

    // ── A wrong registration used to be permanent ─────────────────────────

    function test_UnregisterLetsAWrongAdminBeCorrected() public {
        address wrong = makeAddr("wrongAdmin");
        TaxToken t2 = new TaxToken();
        t2.setMarketingWallet(address(mod));
        mod.registerToken(address(t2), wrong);

        vm.expectRevert(bytes("already registered"));
        mod.registerToken(address(t2), admin);

        mod.unregisterToken(address(t2));
        mod.registerToken(address(t2), admin);
        assertEq(mod.tokenAdmin(address(t2)), admin, "could not correct the admin");
    }

    // ── The destination is the admin's decision, within an allow-list ─────

    /// The bridge exists so an admin can claim revenue accrued HERE and take
    /// delivery on the chain they work from. That destination came from
    /// `treasuryDomain`, an owner-set per-deployment constant.
    function test_AdminChoosesTheDestinationChain() public {
        RecordingMessenger m = new RecordingMessenger();
        mod.setCctpRoute(address(m), 6, bytes32(uint256(1)));   // deployment default = 6
        mod.setCctpDomain(3, true);                              // admin wants 3 (Arbitrum)
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        token.seedPending(1_000e18);

        bytes memory p = abi.encode(TaxClaimModule.ClaimParams({
            token: address(token), amountOutMin: 0,
            deadline: block.timestamp + 1000, bridgeToTreasury: true,
            destinationDomain: 3
        }));
        gw.call(address(mod), _ctx(), p);
        assertEq(m.lastDomain(), uint32(3), "burned to the deployment default, not the admin's choice");
    }

    /// `depositForBurn` accepts any uint32. A domain Circle does not operate is
    /// never attested: the USDC is burned here and minted nowhere.
    function test_UnknownDestinationDomainIsRefusedBeforeTheBurn() public {
        RecordingMessenger m = new RecordingMessenger();
        mod.setCctpRoute(address(m), 6, bytes32(uint256(1)));
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        token.seedPending(1_000e18);

        bytes memory p = abi.encode(TaxClaimModule.ClaimParams({
            token: address(token), amountOutMin: 0,
            deadline: block.timestamp + 1000, bridgeToTreasury: true,
            destinationDomain: 424242              // typo, not a CCTP domain
        }));
        vm.expectRevert(abi.encodeWithSelector(TaxClaimModule.DomainNotEnabled.selector, uint32(424242)));
        gw.call(address(mod), _ctx(), p);
        assertEq(usdc.balanceOf(address(m)), 0, "USDC left for a domain that does not exist");
    }
}
