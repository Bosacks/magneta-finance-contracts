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
    function setOwner(address o) external { owner = o; }
    function setMarketingWallet(address w) external virtual { marketingWallet = w; }
    function seedPending(uint256 a) external { pending = a; }
    /// @dev Mirrors MagnetaERC20OFT.withdrawFees: falls back to owner() when
    ///      the marketing wallet is unset.
    function withdrawFees() external {
        uint256 a = pending; pending = 0;
        _transfer(address(this), marketingWallet != address(0) ? marketingWallet : owner, a);
    }
}

contract Usdc is ERC20 {
    constructor() ERC20("USDC", "USDC") { _mint(msg.sender, 1e30); }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev Quotes `quote`, actually pays out `deliver`, and can be told to REPORT
///      something else (`report`) or to pull only part of its allowance
///      (`pullBps`). Unlike the shared MockV2Router it ENFORCES amountOutMin,
///      so the floor is observable.
contract QuotingRouter {
    address public immutable wethAddr;
    Usdc public immutable usdc;
    uint256 public quote;      // what getAmountsOut reports
    uint256 public deliver;    // what the swap actually pays out
    uint256 public report;     // what the return value claims (0 = tell the truth)
    uint16  public pullBps = 10_000;
    bool    public lax;        // skip the amountOutMin check, like a rogue router

    constructor(address _weth, Usdc _usdc) { wethAddr = _weth; usdc = _usdc; }
    function WETH() external view returns (address) { return wethAddr; }
    function setQuote(uint256 q) external { quote = q; }
    function setDeliver(uint256 d) external { deliver = d; }
    function setReport(uint256 r) external { report = r; }
    function setPullBps(uint16 b) external { pullBps = b; }
    function setLax(bool l) external { lax = l; }

    function getAmountsOut(uint256, address[] calldata path)
        external view returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[path.length - 1] = quote;
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), (amountIn * pullBps) / 10_000);
        if (!lax) require(deliver >= amountOutMin, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        usdc.mint(to, deliver);
        amounts = new uint256[](path.length);
        amounts[path.length - 1] = report == 0 ? deliver : report;
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

/// @dev Accepts `setMarketingWallet` and ignores it — a token whose owner hook
///      is a no-op. The repair path must not report success on it.
contract StubbornTaxToken is TaxToken {
    function setMarketingWallet(address) external pure override {}
    function forceMarketingWallet(address w) external { marketingWallet = w; }
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

    /// @dev A nominal, non-binding floor for tests that are about something
    ///      other than slippage. Zero is now rejected outright.
    uint256 constant NOMINAL_MIN = 1e6;

    function _params(bool bridge) internal view returns (bytes memory) {
        return _params(bridge, NOMINAL_MIN, 6);
    }

    function _params(bool bridge, uint256 amountOutMin, uint32 domain)
        internal view returns (bytes memory)
    {
        return abi.encode(TaxClaimModule.ClaimParams({
            token: address(token), amountOutMin: amountOutMin,
            deadline: block.timestamp + 1000, bridgeToTreasury: bridge,
            destinationDomain: domain
        }));
    }

    function _claim(bool bridge) internal returns (bytes memory) {
        token.seedPending(1_000e18);
        return gw.call(address(mod), _ctx(), _params(bridge));
    }

    // ── Slippage: the only bound a sandwich cannot move ───────────────────

    /// A real sandwich collapses the quote and the output TOGETHER: the attacker
    /// buys, the module's `getAmountsOut` reads the poisoned reserves, and the
    /// swap lands right where that quote said it would. The ratio between them
    /// is untouched, so `maxSlippageBps` — which is that ratio — passes.
    /// `amountOutMin`, fixed from a quote taken in an earlier block, does not.
    function test_SandwichedClaimRevertsOnTheCallerFloor() public {
        // Pre-broadcast quote was 1_000e6; caller allowed 5% and signed 950e6.
        router.setQuote(30e6);            // reserves already drained by the front-run
        router.setDeliver(30e6);          // above minUsdc, consistent with the quote
        token.seedPending(1_000e18);
        // The floor is passed through to the router, so the router is what
        // rejects it. Asserting the exact string keeps this test from passing
        // on an unrelated revert — a bare expectRevert() hid a bug in this file.
        vm.expectRevert(bytes("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"));
        gw.call(address(mod), _ctx(), _params(false, 950e6, 6));
    }

    /// The companion to the above, and the reason `amountOutMin` had to become
    /// mandatory: with only the in-transaction ratio guarding it, the very same
    /// sandwich settles and pays out $30 on a $1,000 claim.
    function test_TheProportionalBoundAloneDoesNotStopThatSandwich() public {
        router.setQuote(30e6);
        router.setDeliver(30e6);          // 100% of the poisoned quote
        token.seedPending(1_000e18);
        gw.call(address(mod), _ctx(), _params(false, 1, 6));
        uint256 fee = (30e6 * uint256(mod.FEE_BPS())) / 10_000;
        assertEq(usdc.balanceOf(admin), 30e6 - fee, "the ratio bound was never going to fire");
    }

    function test_AZeroMinimumIsRefusedOutright() public {
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        token.seedPending(1_000e18);
        vm.expectRevert(TaxClaimModule.ZeroAmountOutMin.selector);
        gw.call(address(mod), _ctx(), _params(false, 0, 6));
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

        gw.call(address(mod), _ctx(), _params(true, NOMINAL_MIN, 3));
        assertEq(m.lastDomain(), uint32(3), "burned to the deployment default, not the admin's choice");
    }

    /// `depositForBurn` accepts any uint32. A domain Circle does not operate is
    /// never attested: the USDC is burned here and minted nowhere.
    function test_UnknownDestinationDomainIsRefusedBeforeTheBurn() public {
        RecordingMessenger m = new RecordingMessenger();
        mod.setCctpRoute(address(m), 6, bytes32(uint256(1)));
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        token.seedPending(1_000e18);

        vm.expectRevert(abi.encodeWithSelector(TaxClaimModule.DomainNotEnabled.selector, uint32(424242)));
        gw.call(address(mod), _ctx(), _params(true, NOMINAL_MIN, 424242));  // typo, not a CCTP domain
        assertEq(usdc.balanceOf(address(m)), 0, "USDC left for a domain that does not exist");
    }

    /// A claim that asked to be bridged and was not is a different outcome from
    /// the one requested, not a fallback: the module used to pay out locally
    /// and emit `bridged = false`.
    function test_BridgeWithNoMessengerRevertsInsteadOfPayingLocally() public {
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        token.seedPending(1_000e18);
        vm.expectRevert(TaxClaimModule.CctpNotConfigured.selector);
        gw.call(address(mod), _ctx(), _params(true));
        assertEq(usdc.balanceOf(admin), 0, "silently paid out on the local chain");
    }

    // ── The router's word is not evidence ─────────────────────────────────

    /// The module used to size the fee split, the payout and the CCTP burn off
    /// `amounts[amounts.length - 1]`, while a comment claimed it checked "the
    /// balance actually gained". It now does.
    function test_AnOverDeclaringRouterCannotInflateTheSplit() public {
        router.setQuote(1_000e6);
        router.setDeliver(980e6);
        router.setReport(5_000e6);        // claims five times what it transferred
        _claim(false);

        uint256 fee = (980e6 * uint256(mod.FEE_BPS())) / 10_000;
        assertEq(usdc.balanceOf(FEE_VAULT), fee, "fee sized off the router's claim");
        assertEq(usdc.balanceOf(admin), 980e6 - fee, "payout sized off the router's claim");
        assertEq(usdc.balanceOf(address(mod)), 0, "module kept a remainder");
    }

    /// Same trick, this time to walk past the floor: a router that skips its own
    /// amountOutMin check and reports a compliant figure.
    function test_AnOverDeclaringRouterCannotWalkPastTheFloor() public {
        router.setLax(true);
        router.setQuote(1_000e6);
        router.setDeliver(900e6);         // under the 970e6 proportional floor
        router.setReport(1_000e6);
        token.seedPending(1_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(TaxClaimModule.SlippageExceeded.selector, uint256(900e6), uint256(970e6))
        );
        gw.call(address(mod), _ctx(), _params(false));
    }

    /// A router that pulls less than it was approved leaves a live allowance on
    /// this module's token balance, exactly as LPModule and MagnetaBundler
    /// guard against.
    function test_NoAllowanceSurvivesTheSwap() public {
        router.setPullBps(5_000);         // consumes half
        router.setQuote(1_000e6); router.setDeliver(1_000e6);
        _claim(false);
        assertEq(token.allowance(address(mod), address(router)), 0, "router keeps a standing allowance");
    }

    // ── Registration used to assert nothing about where the money goes ────

    function test_RegisterRefusesATokenWhoseFeesGoElsewhere() public {
        TaxToken t2 = new TaxToken();
        t2.setMarketingWallet(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(TaxClaimModule.MarketingWalletNotModule.selector, address(0xDEAD))
        );
        mod.registerToken(address(t2), admin);
    }

    /// Unset is legitimate — but only in the one configuration where the token's
    /// own fallback (`marketingWallet != 0 ? marketingWallet : owner()`) still
    /// lands the fees here.
    function test_AnUnsetMarketingWalletIsAcceptedOnlyWhenTheModuleOwnsTheToken() public {
        TaxToken t2 = new TaxToken();                       // marketingWallet = 0, owner = this test
        vm.expectRevert(
            abi.encodeWithSelector(TaxClaimModule.MarketingWalletNotModule.selector, address(0))
        );
        mod.registerToken(address(t2), admin);

        t2.setOwner(address(mod));
        mod.registerToken(address(t2), admin);
        assertEq(mod.tokenAdmin(address(t2)), admin, "owner fallback rejected");
    }

    /// Front-running is harmless: whoever calls first still registers the
    /// token's own owner, never themselves.
    function test_RegisterByTokenOwnerIgnoresWhoCallsIt() public {
        TaxToken t2 = new TaxToken();
        address realOwner = makeAddr("realOwner");
        t2.setMarketingWallet(address(mod));
        t2.setOwner(realOwner);

        vm.prank(makeAddr("frontRunner"));
        mod.registerByTokenOwner(address(t2));
        assertEq(mod.tokenAdmin(address(t2)), realOwner, "front-runner captured the registration");
    }

    /// `tokenAdmin` is compared against `ctx.caller`, so registering this module
    /// as its own admin would lock every claim behind an address no caller can
    /// ever present.
    function test_RegisterByTokenOwnerRefusesAModuleOwnedToken() public {
        TaxToken t2 = new TaxToken();
        t2.setMarketingWallet(address(mod));
        t2.setOwner(address(mod));
        vm.expectRevert(
            abi.encodeWithSelector(TaxClaimModule.TokenOwnerUnusable.selector, address(mod))
        );
        mod.registerByTokenOwner(address(t2));
    }

    function test_RegisterByTokenOwnerStillChecksTheMarketingWallet() public {
        TaxToken t2 = new TaxToken();
        t2.setMarketingWallet(address(0xDEAD));
        t2.setOwner(makeAddr("realOwner"));
        vm.expectRevert(
            abi.encodeWithSelector(TaxClaimModule.MarketingWalletNotModule.selector, address(0xDEAD))
        );
        mod.registerByTokenOwner(address(t2));
    }

    // ── A misdirected marketing wallet used to be terminal ────────────────

    /// `setMarketingWallet` is onlyOwner on the token. Once ownership is here,
    /// nobody could reach it: the tax stream stayed pointed at the wrong
    /// address and each claim still "succeeded" on whatever sat on the module.
    function test_MarketingWalletCanBeRepairedOnceTheModuleOwnsTheToken() public {
        TaxToken t2 = new TaxToken();
        t2.setMarketingWallet(address(0xDEAD));
        t2.setOwner(address(mod));

        mod.repairMarketingWallet(address(t2));
        assertEq(t2.marketingWallet(), address(mod), "fee stream still misdirected");
        mod.registerToken(address(t2), admin);
    }

    function test_RepairReportsFailureRatherThanAssumingItWorked() public {
        StubbornTaxToken t2 = new StubbornTaxToken();
        t2.forceMarketingWallet(address(0xDEAD));
        t2.setOwner(address(mod));
        vm.expectRevert(
            abi.encodeWithSelector(TaxClaimModule.MarketingWalletNotModule.selector, address(0xDEAD))
        );
        mod.repairMarketingWallet(address(t2));
    }
}
