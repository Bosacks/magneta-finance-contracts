// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../contracts/modules/TokenCreationModule.sol";
import "../contracts/modules/LPModule.sol";
import "../contracts/interfaces/IModule.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";
import "../contracts/mocks/MockOFTFactories.sol";
import "../contracts/mocks/MockV2Router.sol";
import "../contracts/mocks/MockWETH.sol";

/// @dev Stands in for MagnetaGateway. Both modules only check
///      `msg.sender == gateway` and read `requiredDVNCount()`, so a stub keeps
///      these tests focused on the modules themselves.
contract R19GatewayStub {
    function requiredDVNCount() external pure returns (uint8) { return 2; }

    function call(address module, IModule.Context memory ctx, bytes memory params)
        external
        payable
        returns (bytes memory)
    {
        return IModule(module).execute{value: msg.value}(ctx, params);
    }

    receive() external payable {}
}

contract R19Token is ERC20 {
    constructor() ERC20("R19", "R19") { _mint(msg.sender, 1e30); }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract R19Usdc is ERC20 {
    constructor() ERC20("USDC", "USDC") { _mint(msg.sender, 1e30); }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

// ─────────────────────────────────────────────────────────────────────────────
// report-19 F-12 — the same creator could never create the same token twice
// ─────────────────────────────────────────────────────────────────────────────

/// @notice On the LOCAL path (`ctx.guid == 0`) the anti-replay key was a pure
///         function of (originChainId, caller, templateKind, innerParams) —
///         no nonce, no operation identifier — and `executedPayloads` has no
///         reset. A creator submitting byte-identical parameters twice hit
///         `AlreadyExecuted` on the second attempt, permanently, on the most
///         travelled path (`Gateway.executeOperation(CREATE_TOKEN, …)`).
contract TokenCreationLocalNonceTest is Test {
    R19GatewayStub gw;
    MockOFTStandardFactory stdFactory;
    MockOFTAutoLiquidityFactory alFactory;
    TokenCreationModule mod;

    address creator = makeAddr("creator");
    address other   = makeAddr("otherCreator");

    function setUp() public {
        gw = new R19GatewayStub();
        stdFactory = new MockOFTStandardFactory();
        alFactory = new MockOFTAutoLiquidityFactory();
        mod = new TokenCreationModule(address(gw), address(stdFactory), address(alFactory));
        stdFactory.setCrossChainCreator(address(mod));
        alFactory.setCrossChainCreator(address(mod));
    }

    function _ctx(address caller, bytes32 guid) internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: caller,
            originChainId: block.chainid,
            feeVault: address(0xFEE0),
            tokenSource: address(0),
            guid: guid
        });
    }

    /// Byte-for-byte identical parameters — the exact input the finding is about.
    function _identicalParams() internal pure returns (bytes memory) {
        TokenCreationModule.StandardParams memory p = TokenCreationModule.StandardParams({
            name: "Magneta Test",
            symbol: "MGT",
            tokenURI: "ipfs://same",
            totalSupply: 1_000_000e18,
            revokeUpdate: false,
            revokeFreeze: false,
            revokeMint: false
        });
        return abi.encodePacked(uint8(TokenCreationModule.TemplateKind.Standard), abi.encode(p));
    }

    function _create(address caller, bytes32 guid) internal returns (address token) {
        bytes memory out = gw.call(address(mod), _ctx(caller, guid), _identicalParams());
        return abi.decode(out, (address));
    }

    /// @dev Same dispatch, WITHOUT decoding the return value. Under
    ///      `vm.expectRevert` the cheatcode hands the caller empty returndata,
    ///      so an `abi.decode` in the helper would itself panic and mask the
    ///      module's actual revert reason.
    function _createExpectingRevert(address caller, bytes32 guid) internal {
        gw.call(address(mod), _ctx(caller, guid), _identicalParams());
    }

    // ── the bug ──────────────────────────────────────────────────────────

    function test_F12_TwoIdenticalLocalCreationsBothSucceedAndYieldDistinctTokens() public {
        address first = _create(creator, bytes32(0));
        address second = _create(creator, bytes32(0));

        assertTrue(first != address(0), "first creation must deploy a token");
        assertTrue(second != address(0), "second creation must deploy a token");
        assertTrue(first != second, "two identical submissions must yield two distinct tokens");
    }

    /// A third and fourth pass: the fix must not merely shift the collision by one.
    function test_F12_RepeatedIdenticalLocalCreationsKeepSucceeding() public {
        address[4] memory tokens;
        for (uint256 i = 0; i < 4; i++) {
            tokens[i] = _create(creator, bytes32(0));
        }
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                assertTrue(tokens[i] != tokens[j], "every creation must be a distinct token");
            }
        }
    }

    /// AutoLiquidity is the other local template and shares the same key.
    function test_F12_IdenticalAutoLiquidityCreationsAlsoSucceedTwice() public {
        TokenCreationModule.AutoLiquidityParams memory p = TokenCreationModule.AutoLiquidityParams({
            name: "Auto",
            symbol: "AUTO",
            tokenURI: "ipfs://auto",
            totalSupply: 5_000e18,
            liquidityToBurn: 0
        });
        bytes memory params =
            abi.encodePacked(uint8(TokenCreationModule.TemplateKind.AutoLiquidity), abi.encode(p));

        address a = abi.decode(gw.call(address(mod), _ctx(creator, bytes32(0)), params), (address));
        address b = abi.decode(gw.call(address(mod), _ctx(creator, bytes32(0)), params), (address));
        assertTrue(a != b, "identical AutoLiquidity submissions must both create");
    }

    // ── the nonce itself ─────────────────────────────────────────────────

    function test_F12_NonceIsPubliclyReadableAndIncrementsPerLocalCreation() public {
        assertEq(mod.localCreationNonce(creator), 0, "nonce must start at zero");
        _create(creator, bytes32(0));
        assertEq(mod.localCreationNonce(creator), 1, "nonce must advance on each local creation");
        _create(creator, bytes32(0));
        assertEq(mod.localCreationNonce(creator), 2, "nonce must advance on each local creation");
    }

    function test_F12_NonceIsScopedPerCaller() public {
        _create(creator, bytes32(0));
        _create(creator, bytes32(0));
        assertEq(mod.localCreationNonce(other), 0, "one creator must not spend another's nonce");

        _create(other, bytes32(0));
        assertEq(mod.localCreationNonce(other), 1, "second creator gets its own counter");
        assertEq(mod.localCreationNonce(creator), 2, "first creator's counter is untouched");
    }

    /// The SDK has to be able to reproduce the key off-chain from the getter,
    /// which is the whole reason the nonce is public.
    function test_F12_LocalReplayKeyIsReproducibleOffChainFromTheGetter() public {
        bytes memory params = _identicalParams();
        uint256 nonceBefore = mod.localCreationNonce(creator);

        bytes32 expectedKey = keccak256(
            abi.encode(
                block.chainid,
                creator,
                TokenCreationModule.TemplateKind.Standard,
                _sliceOffSelectorByte(params),
                nonceBefore
            )
        );
        assertFalse(mod.executedPayloads(expectedKey), "key must be unconsumed before the op");

        gw.call(address(mod), _ctx(creator, bytes32(0)), params);

        assertTrue(mod.executedPayloads(expectedKey), "the recomputed key must be the one consumed");
    }

    function _sliceOffSelectorByte(bytes memory params) internal pure returns (bytes memory out) {
        out = new bytes(params.length - 1);
        for (uint256 i = 1; i < params.length; i++) {
            out[i - 1] = params[i];
        }
    }

    // ── the bridged path must be untouched ───────────────────────────────

    /// The whole point of the guard: a duplicated authenticated LZ message
    /// must still be refused. The nonce must not weaken this.
    function test_F12_BridgedReplayOfTheSameGuidStillReverts() public {
        bytes32 guid = keccak256("lz-guid-1");
        _create(creator, guid);

        vm.expectRevert(TokenCreationModule.AlreadyExecuted.selector);
        _createExpectingRevert(creator, guid);
    }

    /// Two genuinely distinct messages carrying identical params both execute —
    /// the F-22/F-31 behaviour, preserved.
    function test_F12_BridgedDistinctGuidsWithIdenticalParamsBothExecute() public {
        address a = _create(creator, keccak256("lz-guid-a"));
        address b = _create(creator, keccak256("lz-guid-b"));
        assertTrue(a != b, "distinct GUIDs must both create");
    }

    /// The nonce is a LOCAL-path device. Folding it into the bridged key would
    /// make a replayed GUID hash to a fresh slot and execute, so the bridged
    /// path must not touch the counter at all.
    function test_F12_BridgedPathDoesNotConsumeTheLocalNonce() public {
        _create(creator, keccak256("lz-guid-c"));
        assertEq(mod.localCreationNonce(creator), 0, "bridged ops must not spend the local nonce");

        _create(creator, bytes32(0));
        assertEq(mod.localCreationNonce(creator), 1, "local op after a bridged one starts from zero");
    }

    /// A GUID already consumed by the bridged path must stay consumed even
    /// after local activity has moved the counter.
    function test_F12_LocalActivityDoesNotUnlockAConsumedGuid() public {
        bytes32 guid = keccak256("lz-guid-d");
        _create(creator, guid);
        _create(creator, bytes32(0));
        _create(creator, bytes32(0));

        vm.expectRevert(TokenCreationModule.AlreadyExecuted.selector);
        _createExpectingRevert(creator, guid);
    }

    // ── F-22: the dead error is gone, the real fallback is unchanged ─────

    /// `UnsupportedOp` was declared and never reachable — the module cannot
    /// check `ctx.opType` because {IModule.Context} has no such field. The
    /// live fallback for a bad payload is and remains UnsupportedTemplate.
    function test_F22_UnknownTemplateStillGivesUnsupportedTemplate() public {
        vm.expectRevert(TokenCreationModule.UnsupportedTemplate.selector);
        gw.call(address(mod), _ctx(creator, bytes32(0)), abi.encodePacked(uint8(200), abi.encode(uint256(1))));
    }

    function test_F22_EmptyPayloadStillGivesInvalidPayload() public {
        vm.expectRevert(TokenCreationModule.InvalidPayload.selector);
        gw.call(address(mod), _ctx(creator, bytes32(0)), "");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// F-9 / F-5 — LPModule
// ─────────────────────────────────────────────────────────────────────────────

contract LPModuleReport19Test is Test {
    R19GatewayStub gw;
    LPModule mod;
    MockV2Router router;
    MockWETH weth;
    R19Token token;
    R19Usdc usdc;

    address user = makeAddr("lpUser");
    address constant FEE_VAULT = address(0xFEE0);
    address constant MAGNETA_SWAP = address(0x5AA9);

    function setUp() public {
        gw = new R19GatewayStub();
        weth = new MockWETH();
        router = new MockV2Router(address(weth));
        token = new R19Token();
        usdc = new R19Usdc();
        // magnetaSwap is a constructor arg the module no longer reads (F-5);
        // it only has to be non-zero.
        mod = new LPModule(address(gw), address(router), address(usdc), MAGNETA_SWAP);

        token.mint(user, 1e24);
        usdc.mint(user, 1e12);
        vm.deal(user, 100 ether);
        vm.deal(address(gw), 100 ether);
    }

    function _ctx(address caller, address tokenSource) internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: caller,
            originChainId: block.chainid,
            feeVault: FEE_VAULT,
            tokenSource: tokenSource,
            guid: bytes32(0)
        });
    }

    function _createLpParams(uint256 tokenAmount, uint256 ethAmount, uint256 usdcFee)
        internal
        view
        returns (LPModule.CreateLPParams memory)
    {
        return LPModule.CreateLPParams({
            token: address(token),
            tokenAmount: tokenAmount,
            ethAmount: ethAmount,
            amountTokenMin: 0,
            amountETHMin: 0,
            usdcFee: usdcFee,
            deadline: block.timestamp + 1000,
            permit: ""
        });
    }

    /// Bootstraps the (token, WETH) pair on the mock router and leaves `user`
    /// holding pair tokens — the precondition for REMOVE_LP / BURN_LP.
    function _bootstrapPair(uint256 tokenAmount, uint256 ethAmount) internal {
        vm.prank(user);
        token.approve(address(mod), tokenAmount);

        LPModule.CreateLPParams memory p = _createLpParams(tokenAmount, ethAmount, 0);
        gw.call{value: ethAmount}(
            address(mod),
            _ctx(user, address(0)),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );
    }

    // ── F-9 ──────────────────────────────────────────────────────────────

    /// BURN_LP moves a V2 PAIR token. The gateway only ever stages bridged
    /// USDC (or a launch token) in `tokenSource` — it never holds or approves
    /// pair tokens. The op used to be routed into `safeTransferFrom(gateway,
    /// DEAD, …)` and die on a missing allowance: fail-closed, but a dead end
    /// the user already paid a service fee for. It must be refused up front.
    function test_F9_BurnLpWithAGatewayTokenSourceIsRejectedUpFront() public {
        _bootstrapPair(1e21, 1 ether);

        LPModule.BurnLPParams memory p = LPModule.BurnLPParams({token: address(token), liquidity: 1});

        vm.expectRevert(
            abi.encodeWithSelector(
                LPModule.UnexpectedTokenSource.selector, IMagnetaGateway.OpType.BURN_LP
            )
        );
        gw.call(
            address(mod),
            _ctx(user, address(gw)),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.BURN_LP), abi.encode(p))
        );
    }

    /// REMOVE_LP pulls the same pair token via `_pullToken`, which honours
    /// `ctx.tokenSource` identically — the finding applies verbatim.
    function test_F9_RemoveLpWithAGatewayTokenSourceIsRejectedUpFront() public {
        _bootstrapPair(1e21, 1 ether);

        LPModule.RemoveLPParams memory p = LPModule.RemoveLPParams({
            token: address(token),
            liquidity: 1,
            amountTokenMin: 0,
            amountETHMin: 0,
            usdcFee: 0,
            deadline: block.timestamp + 1000
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                LPModule.UnexpectedTokenSource.selector, IMagnetaGateway.OpType.REMOVE_LP
            )
        );
        gw.call(
            address(mod),
            _ctx(user, address(gw)),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.REMOVE_LP), abi.encode(p))
        );
    }

    /// The rejection is reached BEFORE any router lookup: no pair exists here,
    /// so the pre-existing "no pair" require would have fired first if the
    /// guard were placed inside the op instead of at dispatch.
    function test_F9_RejectionPrecedesTheRouterLookup() public {
        LPModule.BurnLPParams memory p = LPModule.BurnLPParams({token: address(token), liquidity: 1});

        vm.expectRevert(
            abi.encodeWithSelector(
                LPModule.UnexpectedTokenSource.selector, IMagnetaGateway.OpType.BURN_LP
            )
        );
        gw.call(
            address(mod),
            _ctx(user, address(gw)),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.BURN_LP), abi.encode(p))
        );
    }

    /// Non-regression: the ordinary BURN_LP, with no tokenSource, still burns.
    function test_F9_BurnLpFromTheCallerStillWorks() public {
        _bootstrapPair(1e21, 1 ether);

        address pair = address(router.pair());
        uint256 held = IERC20(pair).balanceOf(user);
        assertGt(held, 0, "bootstrap must have minted LP to the user");

        vm.prank(user);
        IERC20(pair).approve(address(mod), held);

        LPModule.BurnLPParams memory p = LPModule.BurnLPParams({token: address(token), liquidity: held});
        gw.call(
            address(mod),
            _ctx(user, address(0)),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.BURN_LP), abi.encode(p))
        );

        assertEq(IERC20(pair).balanceOf(user), 0, "LP must have left the user");
        assertEq(IERC20(pair).balanceOf(mod.DEAD()), held, "LP must have landed on the burn address");
    }

    /// Non-regression AND a deliberate scope boundary: CREATE_LP_AND_BUY's
    /// token leg is the LAUNCH token, which the gateway does legitimately
    /// stage on the bridged path (see LPModulePermit's cross-chain case), so
    /// it is intentionally NOT covered by the F-9 guard.
    function test_F9_CreateLpAndBuyWithATokenSourceRemainsAllowed() public {
        uint256 tokenAmount = 1e21;
        uint256 ethAmount = 1 ether;

        // The gateway holds and approves the tokens the ordinary way.
        token.mint(address(gw), tokenAmount);
        vm.prank(address(gw));
        token.approve(address(mod), tokenAmount);

        LPModule.CreateLPAndBuyParams memory p = LPModule.CreateLPAndBuyParams({
            lp: _createLpParams(tokenAmount, ethAmount, 0),
            buyEth: 0,
            buyAmountOutMin: 0,
            buyRecipient: user
        });

        gw.call{value: ethAmount}(
            address(mod),
            _ctx(user, address(gw)),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP_AND_BUY), abi.encode(p))
        );

        assertGt(router.pair().balanceOf(user), 0, "bridged create-and-buy must still settle");
    }

    // ── F-5 ──────────────────────────────────────────────────────────────

    /// The removed `_requireLocalFee` would have demanded at least
    /// MIN_LOCAL_FEE_USDC ($0.10) on any local CREATE_LP with a non-zero
    /// native side. It was never wired into a call site, and the live policy
    /// is a NATIVE fee skimmed by the Gateway before the module runs — so a
    /// local CREATE_LP with usdcFee == 0 is the normal, correct case.
    function test_F5_LocalCreateLpWithZeroUsdcFeeSucceeds() public {
        _bootstrapPair(1e21, 1 ether);

        assertGt(router.pair().balanceOf(user), 0, "local LP with no USDC fee must settle");
        assertEq(usdc.balanceOf(FEE_VAULT), 0, "no USDC may be pulled when usdcFee is zero");
    }

    /// …and the fee-collection logic itself is untouched: a non-zero usdcFee
    /// is still pulled to the feeVault. F-5 was cleanup, not a revenue change.
    function test_F5_NonZeroUsdcFeeIsStillCollected() public {
        uint256 tokenAmount = 1e21;
        uint256 ethAmount = 1 ether;
        uint256 fee = 250_000; // 6dp

        vm.startPrank(user);
        token.approve(address(mod), tokenAmount);
        usdc.approve(address(mod), fee);
        vm.stopPrank();

        LPModule.CreateLPParams memory p = _createLpParams(tokenAmount, ethAmount, fee);
        gw.call{value: ethAmount}(
            address(mod),
            _ctx(user, address(0)),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );

        assertEq(usdc.balanceOf(FEE_VAULT), fee, "a supplied USDC fee must still reach the feeVault");
    }

    /// `magnetaSwap` survives as a constructor arg / getter for the deploy
    /// manifests even though no code path reads it any more.
    function test_F5_MagnetaSwapRemainsReadableForDeployWiring() public view {
        assertEq(mod.magnetaSwap(), MAGNETA_SWAP, "deploy scripts still assert this wiring");
    }
}
