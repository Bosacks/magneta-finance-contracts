// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/LPModule.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";
import "../contracts/interfaces/IModule.sol";
import "../contracts/mocks/MockV2Router.sol";
import "../contracts/mocks/MockWETH.sol";
import "../contracts/mocks/MockPermitToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GatewayStub, TestUSDC} from "./LPModuleInvariants.t.sol";

/// @notice One-click LP: covers LPModule's `_applyPermit` EIP-2612 helper,
///         wired into `_createLP` just before `_pullToken`. See spec (Sentinelle
///         permit chantier, 2026-07-31): consuming a permit signature lets a
///         user who has NEVER called `approve` create a pool in a single
///         operation, and the try/catch around `permit()` must tolerate a
///         signature that a third party already submitted ahead of this call.
contract LPModulePermitTest is Test {
    LPModule mod;
    GatewayStub gw;
    MockPermitToken token;
    TestUSDC usdc;
    MockV2Router router;
    MockWETH weth;

    address constant FEE_VAULT = address(0xFEE0);
    address constant MAGNETA_SWAP = address(0x5AAA);

    // EIP-2612 typehash, hardcoded rather than read off the token — this is
    // what a real SDK would hardcode too, and it doubles as a check that the
    // mock token's domain matches the standard.
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 constant USER_PK = 0xA11CE;
    address user;

    function setUp() public {
        user = vm.addr(USER_PK);

        weth = new MockWETH();
        router = new MockV2Router(address(weth));
        token = new MockPermitToken();
        usdc = new TestUSDC();
        gw = new GatewayStub();

        mod = new LPModule(address(gw), address(router), address(usdc), MAGNETA_SWAP);

        token.mint(user, 1e24);
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

    /// @dev Signs a real EIP-2612 permit for `owner` -> `spender` using the
    ///      token's live domain separator and nonce, so front-running (which
    ///      bumps the nonce) is naturally reflected on the next signature
    ///      built for the same owner.
    function _signPermit(uint256 pk, address owner, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function _lpParams(uint256 tokenAmount, uint256 ethAmount, bytes memory permitBlob)
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
            usdcFee: 0,
            deadline: block.timestamp + 1000,
            permit: permitBlob
        });
    }

    function _executeCreateLp(LPModule.CreateLPParams memory p, address caller, address tokenSource, uint256 ethAmount)
        internal
        returns (bytes memory)
    {
        return gw.call{value: ethAmount}(
            address(mod), _ctx(caller, tokenSource),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. The headline use case: no prior approve, permit alone unblocks it.
    // ─────────────────────────────────────────────────────────────────────
    function test_CreateLp_NeverApproved_PermitUnlocksSingleTxFlow() public {
        uint256 tokenAmount = 1e20;
        uint256 ethAmount = 1 ether;
        uint256 deadline = block.timestamp + 1000;

        assertEq(token.allowance(user, address(mod)), 0, "precondition: no prior approve");

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(USER_PK, user, address(mod), tokenAmount, deadline);
        bytes memory permitBlob = abi.encode(tokenAmount, deadline, v, r, s);

        LPModule.CreateLPParams memory p = _lpParams(tokenAmount, ethAmount, permitBlob);
        _executeCreateLp(p, user, address(0), ethAmount);

        assertEq(token.balanceOf(address(mod)), 0, "module must not retain pulled tokens");
        assertGt(router.pair().balanceOf(user), 0, "pool must have been created and LP credited to the user");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. Negative control: without a permit AND without a prior approve, the
    //    op must fail — proving the permit above is what actually unblocked it.
    // ─────────────────────────────────────────────────────────────────────
    function test_CreateLp_NoPermitNoApprove_Reverts() public {
        uint256 tokenAmount = 1e20;
        uint256 ethAmount = 1 ether;

        LPModule.CreateLPParams memory p = _lpParams(tokenAmount, ethAmount, "");

        vm.expectRevert();
        _executeCreateLp(p, user, address(0), ethAmount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. Front-run: a third party submits the exact same permit signature
    //    before the real operation runs. The op must still SUCCEED off the
    //    allowance the front-runner already set — this is the scenario the
    //    try/catch in _applyPermit exists for.
    // ─────────────────────────────────────────────────────────────────────
    function test_CreateLp_PermitFrontRun_StillSucceeds() public {
        uint256 tokenAmount = 1e20;
        uint256 ethAmount = 1 ether;
        uint256 deadline = block.timestamp + 1000;

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(USER_PK, user, address(mod), tokenAmount, deadline);
        bytes memory permitBlob = abi.encode(tokenAmount, deadline, v, r, s);

        // A third party (anyone can submit a public permit signature) consumes
        // it directly against the token, ahead of the LPModule operation.
        address frontRunner = address(0xBEEF);
        vm.prank(frontRunner);
        token.permit(user, address(mod), tokenAmount, deadline, v, r, s);
        assertEq(token.allowance(user, address(mod)), tokenAmount, "front-runner should have set the allowance");
        assertEq(token.nonces(user), 1, "front-run must have consumed the nonce");

        // The real operation now replays the SAME (now-stale) signature.
        // permit() will revert internally on the stale nonce; _applyPermit
        // must swallow that and fall through to the allowance already set.
        LPModule.CreateLPParams memory p = _lpParams(tokenAmount, ethAmount, permitBlob);
        _executeCreateLp(p, user, address(0), ethAmount);

        assertGt(router.pair().balanceOf(user), 0, "op must succeed despite the stale/front-run permit");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. Invalid/expired permit with NO pre-existing allowance must fail
    //    cleanly at transferFrom — no panic, a plain ERC20 insufficient-
    //    allowance revert.
    // ─────────────────────────────────────────────────────────────────────
    function test_CreateLp_ExpiredPermitNoAllowance_RevertsCleanlyAtTransferFrom() public {
        uint256 tokenAmount = 1e20;
        uint256 ethAmount = 1 ether;
        uint256 deadline = block.timestamp; // will be warped past

        (uint8 v, bytes32 r, bytes32 s) = _signPermit(USER_PK, user, address(mod), tokenAmount, deadline);
        bytes memory permitBlob = abi.encode(tokenAmount, deadline, v, r, s);

        vm.warp(block.timestamp + 1); // deadline now in the past

        LPModule.CreateLPParams memory p = _lpParams(tokenAmount, ethAmount, permitBlob);

        // _applyPermit swallows the expired-permit revert; safeTransferFrom
        // is what actually reverts, on insufficient allowance (0).
        vm.expectRevert();
        _executeCreateLp(p, user, address(0), ethAmount);

        assertEq(token.allowance(user, address(mod)), 0, "expired permit must not have set any allowance");
    }

    function test_CreateLp_InvalidSignatureNoAllowance_RevertsCleanlyAtTransferFrom() public {
        uint256 tokenAmount = 1e20;
        uint256 ethAmount = 1 ether;
        uint256 deadline = block.timestamp + 1000;

        // Signed by the WRONG key — recovers to some address != user, so
        // permit()'s "invalid signature" check fails inside the token.
        uint256 wrongPk = 0xBAD;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(wrongPk, user, address(mod), tokenAmount, deadline);
        bytes memory permitBlob = abi.encode(tokenAmount, deadline, v, r, s);

        LPModule.CreateLPParams memory p = _lpParams(tokenAmount, ethAmount, permitBlob);

        vm.expectRevert();
        _executeCreateLp(p, user, address(0), ethAmount);

        assertEq(token.allowance(user, address(mod)), 0, "invalid signature must not have set any allowance");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. Cross-chain path: ctx.tokenSource != 0 means funds are staged by the
    //    gateway, not pulled from an end-user signature. A non-empty permit
    //    blob must be silently ignored — behaviour identical to before this
    //    feature existed.
    //
    //    Routed via CREATE_LP_AND_BUY rather than plain CREATE_LP: execute()
    //    only ever calls `_createLP` when `ctx.tokenSource == address(0)`
    //    (CREATE_LP with a non-zero tokenSource is routed to the separate
    //    `_createLPFromBridgedUsdc` bridged-USDC flow instead, which has no
    //    permit blob at all), so `_applyPermit`'s tokenSource-guard branch is
    //    only reachable in practice through `_createLPAndBuy`, whose dispatch
    //    is NOT conditioned on tokenSource.
    // ─────────────────────────────────────────────────────────────────────
    function test_CreateLpAndBuy_CrossChainTokenSource_PermitIgnored() public {
        uint256 tokenAmount = 1e20;
        uint256 ethAmount = 1 ether;
        uint256 deadline = block.timestamp + 1000;

        // Bridged path: tokenSource is the gateway itself, which must hold
        // and have approved the tokens the ordinary way (no permit involved
        // for the bridged leg).
        token.mint(address(gw), tokenAmount);
        vm.prank(address(gw));
        token.approve(address(mod), tokenAmount);

        // A validly-signed permit for the real user is attached anyway — it
        // must be ignored entirely because tokenSource != address(0).
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(USER_PK, user, address(mod), tokenAmount, deadline);
        bytes memory permitBlob = abi.encode(tokenAmount, deadline, v, r, s);

        LPModule.CreateLPParams memory lp = _lpParams(tokenAmount, ethAmount, permitBlob);
        LPModule.CreateLPAndBuyParams memory p = LPModule.CreateLPAndBuyParams({
            lp: lp,
            buyEth: 0,
            buyAmountOutMin: 0,
            buyRecipient: user
        });

        bytes memory payload = abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP_AND_BUY), abi.encode(p));
        IModule.Context memory ctx = IModule.Context({
            caller: user,
            originChainId: block.chainid,
            feeVault: FEE_VAULT,
            tokenSource: address(gw),
            guid: bytes32(0)
        });

        gw.call{value: ethAmount}(address(mod), ctx, payload);

        // The user's own signature/nonce must be untouched — proof the
        // permit was never even attempted against the token.
        assertEq(token.nonces(user), 0, "cross-chain path must never consume the user's permit nonce");
        assertGt(router.pair().balanceOf(user), 0, "bridged LP-and-buy creation must still have succeeded via the pre-set allowance");
    }
}
