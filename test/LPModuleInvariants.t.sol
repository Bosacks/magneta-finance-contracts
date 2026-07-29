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


/// @dev A router that only PARTIALLY fills, like a real UniV2 router does when
///      the pool ratio differs from what the caller offered.
///
///      This exists because MockV2Router consumes exactly what it is offered:
///      full token amount, full msg.value, nothing left over. Against such a
///      router the module can never strand dust and never leave a residual
///      allowance, so LP-1/2/3 held even with F7 and F52 deliberately deleted —
///      they passed because the scenario was unreachable, not because the code
///      was right. A partial fill is what makes those guards observable.
contract PartialFillRouter {
    using SafeERC20 for IERC20;

    address public immutable override_WETH;
    MockLPToken public pair;

    /// Fraction of the offered amounts actually consumed, in basis points.
    uint16 public fillBps = 10_000;

    constructor(address _weth) { override_WETH = _weth; }

    function setFillBps(uint16 bps) external { fillBps = bps > 10_000 ? 10_000 : bps; }

    function WETH() external view returns (address) { return override_WETH; }
    function factory() external view returns (address) { return address(this); }
    function getPair(address, address) external view returns (address) { return address(pair); }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint /*amountTokenMin*/,
        uint /*amountETHMin*/,
        address to,
        uint /*deadline*/
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        if (address(pair) == address(0)) pair = new MockLPToken(address(this));

        amountToken = (amountTokenDesired * fillBps) / 10_000;
        amountETH   = (msg.value * fillBps) / 10_000;

        // Real router behaviour: pull ONLY what is consumed, and hand back the
        // unused native to the immediate caller (the module).
        if (amountToken > 0) IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);
        liquidity = amountToken + amountETH;
        pair.mint(to, liquidity);

        if (msg.value > amountETH) {
            (bool ok, ) = msg.sender.call{value: msg.value - amountETH}("");
            require(ok, "refund failed");
        }
    }

    /// @dev Burns the LP the module holds and pays the unwound side out to `to`,
    ///      like the real router. Needed to reach LPModule's REMOVE_LP dust path.
    function removeLiquidity(
        address token,
        address /*tokenB*/,
        uint liquidity,
        uint /*amountAMin*/,
        uint /*amountBMin*/,
        address to,
        uint /*deadline*/
    ) external returns (uint amountA, uint amountB) {
        pair.burn(msg.sender, liquidity);
        amountA = liquidity;
        amountB = 0;
        IERC20(token).safeTransfer(to, amountA);
    }

    receive() external payable {}
}

contract TestToken is ERC20 {
    constructor() ERC20("T", "T") { _mint(msg.sender, 1e30); }
}

contract TestUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") { _mint(msg.sender, 1e30); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @dev Stands in for MagnetaGateway. LPModule only checks `msg.sender ==
///      gateway` and reads `requiredDVNCount()` in its constructor, so a stub
///      is enough — and it keeps the campaign focused on the module.
contract GatewayStub {
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

/// @dev The user on whose behalf ops run. Holds the tokens, grants the
///      allowance, and receives refunds — mirroring a real caller.
contract LPUser {
    receive() external payable {}
}

/// @dev Bounded random driver. Every action goes through the gateway stub, as
///      a real op would.
contract LPModuleHandler is Test {
    LPModule public immutable mod;
    GatewayStub public immutable gw;
    TestToken public immutable token;
    PartialFillRouter public immutable router;
    LPUser public immutable user;
    address public immutable feeVault;

    uint256 public ghost_createOk;
    uint256 public ghost_createReverted;
    /// Ghost: native sent straight to the module's receive(). LPModule has no
    /// sweep function, so a donation legitimately sits there — the invariant
    /// must not mistake it for an operation leaving value behind.
    uint256 public ghost_donatedNative;
    /// Ghost: native the module handed back out. _refundDust computes its dust
    /// as `balance - (balance - msg.value)`, so a PRIOR donation is swept to
    /// whoever calls createLp next. Not a vulnerability (donated native is
    /// unowned) but it means the module's balance can also go DOWN on its own.
    uint256 public ghost_donationsSweptAway;

    constructor(
        LPModule _mod,
        GatewayStub _gw,
        TestToken _token,
        PartialFillRouter _router,
        LPUser _user,
        address _feeVault
    ) {
        mod = _mod; gw = _gw; token = _token; router = _router; user = _user; feeVault = _feeVault;
    }

    function _ctx() internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: address(user),
            originChainId: block.chainid,
            feeVault: feeVault,
            tokenSource: address(0)
        });
    }

    /// Create LP with random amounts.
    function createLp(uint256 tokenAmount, uint256 ethAmount) external {
        tokenAmount = bound(tokenAmount, 1e15, 1e22);
        ethAmount   = bound(ethAmount,   1e12, 5 ether);

        if (token.balanceOf(address(user)) < tokenAmount) return;

        LPModule.CreateLPParams memory p = LPModule.CreateLPParams({
            token: address(token),
            tokenAmount: tokenAmount,
            ethAmount: ethAmount,
            amountTokenMin: 0,
            amountETHMin: 0,
            usdcFee: 0,
            deadline: block.timestamp + 1000
        });

        // A create sweeps any pre-existing donation out with the caller's dust.
        uint256 modBalBefore = address(mod).balance;

        // Fund the HANDLER: it is the one attaching value to the call.
        // Crediting the gateway instead made every single op revert for lack
        // of funds - 42724/42724 - while the suite still reported PASS.
        vm.deal(address(this), ethAmount);
        // Deliberately NOT wrapped in try/catch. Swallowing the revert made the
        // whole campaign green while the module was never actually reached —
        // Foundry's own revert counter is the honest signal.
        gw.call{value: ethAmount}(
            address(mod),
            _ctx(),
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );
        ghost_createOk += 1;
        if (modBalBefore > address(mod).balance) {
            ghost_donationsSweptAway += modBalBefore - address(mod).balance;
        }
    }

    /// Make the router fill only part of the offer — that is what produces the
    /// leftover token / native / allowance the guards are supposed to clean up.
    function setFill(uint16 bps) external {
        router.setFillBps(uint16(bound(uint256(bps), 1, 10_000)));
    }

    /// Adversarial: send native straight at the module. Its receive() accepts
    /// it (the router refunds that way), but nothing should ever let it stay.
    function stuckNative(uint256 amount) external {
        amount = bound(amount, 1 wei, 1 ether);
        vm.deal(address(this), amount);
        (bool ok, ) = address(mod).call{value: amount}("");
        if (ok) ghost_donatedNative += amount;
    }

}

/// @notice Invariants for LPModule — the contract that actually touches user
///         funds on the CREATE_LP path (it is the `spender` users approve).
///
///         LP-1  The module never holds native currency between operations.
///               Anything the router refunds must be swept to the caller by
///               _refundDust; a residue means user funds are stranded in a
///               contract with no withdrawal function.
///         LP-2  The module never holds the pool token between operations,
///               for the same reason.
///         LP-3  The module never leaves a standing allowance on the router.
///               A residual approval is what F52 was added to prevent: a
///               compromised router could re-pull it later.
contract LPModuleInvariantTest is Test {
    LPModule mod;
    GatewayStub gw;
    TestToken token;
    TestUSDC usdc;
    PartialFillRouter router;
    MockWETH weth;
    LPUser user;
    LPModuleHandler handler;
    address constant FEE_VAULT = address(0xFEE0);
    address constant MAGNETA_SWAP = address(0x5AAA);

    function setUp() public {
        weth   = new MockWETH();
        router = new PartialFillRouter(address(weth));
        token  = new TestToken();
        usdc   = new TestUSDC();
        gw     = new GatewayStub();
        user   = new LPUser();

        mod = new LPModule(address(gw), address(router), address(usdc), MAGNETA_SWAP);

        // Fund the user and let the module pull from them, as the frontend does.
        token.transfer(address(user), 1e26);
        vm.prank(address(user));
        token.approve(address(mod), type(uint256).max);

        handler = new LPModuleHandler(mod, gw, token, router, user, FEE_VAULT);

        targetContract(address(handler));
    }

    /// LP-1: no OPERATION ever leaves native behind. The module's balance is
    ///       fully explained by direct donations minus what later creates swept
    ///       out — never more. An excess would mean user ETH stranded in a
    ///       contract that has no withdrawal function.
    function invariant_NoOpLeavesNativeBehind() public view {
        assertLe(
            address(mod).balance,
            handler.ghost_donatedNative() - handler.ghost_donationsSweptAway(),
            "LPModule holds more native than was donated - an op stranded user ETH"
        );
    }

    /// LP-2: the module never holds the pool token between ops. Strict zero:
    ///       nothing donates tokens to it, so any balance is op residue.
    function invariant_ModuleHoldsNoOpToken() public view {
        assertEq(token.balanceOf(address(mod)), 0, "LPModule left pool token behind");
    }

    /// LP-3: no standing router allowance between ops.
    function invariant_NoStandingRouterAllowance() public view {
        assertEq(
            token.allowance(address(mod), address(router)),
            0,
            "LPModule left an allowance on the router"
        );
    }
}

/// @notice Sanity check that the invariant campaign is actually exercising the
///         module. An invariant suite whose handler silently reverts every call
///         reports PASS while proving nothing — this test is the guard against
///         that, and it caught exactly that situation while these were written.
contract LPModuleReachabilityTest is LPModuleInvariantTest {
    function test_CreateLpActuallyExecutes() public {
        router.setFillBps(5000); // half fill => leftovers on both sides

        uint256 tokenAmount = 1e20;
        uint256 ethAmount   = 1 ether;

        LPModule.CreateLPParams memory p = LPModule.CreateLPParams({
            token: address(token),
            tokenAmount: tokenAmount,
            ethAmount: ethAmount,
            amountTokenMin: 0,
            amountETHMin: 0,
            usdcFee: 0,
            deadline: block.timestamp + 1000
        });

        IModule.Context memory ctx = IModule.Context({
            caller: address(user),
            originChainId: block.chainid,
            feeVault: FEE_VAULT,
            tokenSource: address(0)
        });

        vm.deal(address(gw), ethAmount);
        // NOT wrapped in try/catch on purpose: a revert must fail the test.
        gw.call{value: ethAmount}(
            address(mod),
            ctx,
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );

        assertEq(address(mod).balance, 0, "native dust left in module");
        assertEq(token.balanceOf(address(mod)), 0, "token dust left in module");
        assertEq(token.allowance(address(mod), address(router)), 0, "allowance left on router");
    }

    /// @dev REMOVE_LP used to refund `pair.balanceOf(module)` — the module's
    ///      WHOLE pair-token balance — while the native side of the very same
    ///      refund was bounded by `nativeBefore`. Any pair tokens the module
    ///      already held (a stray donation, an aborted flow, a non-conforming
    ///      router) were therefore handed to whoever called removeLP next.
    ///
    ///      Here a third party donates LP tokens to the module, then a caller
    ///      runs REMOVE_LP. The donation must still be sitting in the module
    ///      afterwards. Against the old code this assertion fails: the caller
    ///      receives the donation on top of their own unwound liquidity.
    function test_RemoveLp_DoesNotSweepPreexistingPairTokens() public {
        // Seed a pair by creating liquidity once, so `getPair` is non-zero.
        router.setFillBps(10_000);
        _createLp(1e20, 1 ether);

        MockLPToken pair = router.pair();
        uint256 donation = 7e17;

        // A stranger donates LP tokens straight to the module. Nothing in the
        // protocol does this, which is exactly why nothing may spend them.
        address stranger = makeAddr("stranger");
        vm.prank(address(user));
        pair.transfer(stranger, donation);
        vm.prank(stranger);
        pair.transfer(address(mod), donation);
        assertEq(pair.balanceOf(address(mod)), donation, "setup: donation not in place");

        // The user removes a small slice of their own liquidity.
        uint256 liquidity = 1e17;
        vm.prank(address(user));
        pair.approve(address(mod), type(uint256).max);

        uint256 callerPairBefore = pair.balanceOf(address(user));

        LPModule.RemoveLPParams memory p = LPModule.RemoveLPParams({
            token: address(token),
            liquidity: liquidity,
            amountTokenMin: 0,
            amountETHMin: 0,
            usdcFee: 0,
            deadline: block.timestamp + 1000
        });
        IModule.Context memory ctx = IModule.Context({
            caller: address(user),
            originChainId: block.chainid,
            feeVault: FEE_VAULT,
            tokenSource: address(0)
        });

        gw.call(
            address(mod),
            ctx,
            abi.encodePacked(uint8(IMagnetaGateway.OpType.REMOVE_LP), abi.encode(p))
        );

        assertEq(
            pair.balanceOf(address(mod)),
            donation,
            "REMOVE_LP swept pair tokens the module already held"
        );
        assertEq(
            pair.balanceOf(address(user)),
            callerPairBefore - liquidity,
            "caller received pair tokens that were not theirs"
        );
    }

    function _createLp(uint256 tokenAmount, uint256 ethAmount) internal {
        LPModule.CreateLPParams memory p = LPModule.CreateLPParams({
            token: address(token),
            tokenAmount: tokenAmount,
            ethAmount: ethAmount,
            amountTokenMin: 0,
            amountETHMin: 0,
            usdcFee: 0,
            deadline: block.timestamp + 1000
        });
        IModule.Context memory ctx = IModule.Context({
            caller: address(user),
            originChainId: block.chainid,
            feeVault: FEE_VAULT,
            tokenSource: address(0)
        });
        vm.deal(address(gw), ethAmount);
        gw.call{value: ethAmount}(
            address(mod),
            ctx,
            abi.encodePacked(uint8(IMagnetaGateway.OpType.CREATE_LP), abi.encode(p))
        );
    }
}
