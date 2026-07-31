// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/SwapModule.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";
import "../contracts/interfaces/IModule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SwapToken is ERC20 {
    constructor(string memory n) ERC20(n, n) { _mint(msg.sender, 1e30); }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev UniV2-shaped router with a fixed 1:1 rate. It pays the LAST token of
///      `path`, exactly as a real router does — which is what makes the
///      path/tokenOut consistency check observable: declare a different
///      tokenOut and the module would be paying out a token it never received.
contract SwapRouterStub {
    address public immutable wethAddr;
    constructor(address _weth) { wethAddr = _weth; }
    function WETH() external view returns (address) { return wethAddr; }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256, address[] calldata path, address to, uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        SwapToken(path[path.length - 1]).mint(to, amountIn);
        amounts = new uint256[](2);
        amounts[0] = amountIn; amounts[1] = amountIn;
    }

    function swapExactETHForTokens(
        uint256, address[] calldata path, address to, uint256
    ) external payable returns (uint256[] memory amounts) {
        SwapToken(path[path.length - 1]).mint(to, msg.value);
        amounts = new uint256[](2);
        amounts[0] = msg.value; amounts[1] = msg.value;
    }

    function swapExactTokensForETH(
        uint256 amountIn, uint256, address[] calldata path, address to, uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        (bool ok, ) = to.call{value: amountIn}("");
        require(ok, "eth out");
        amounts = new uint256[](2);
        amounts[0] = amountIn; amounts[1] = amountIn;
    }

    receive() external payable {}
}

contract SwapGatewayStub {
    function requiredDVNCount() external pure returns (uint8) { return 2; }
    function call(address module, IModule.Context memory ctx, bytes memory params)
        external payable returns (bytes memory)
    { return IModule(module).execute{value: msg.value}(ctx, params); }
    receive() external payable {}
}

contract SwapUser { receive() external payable {} }

contract SwapHandler is Test {
    SwapModule public immutable mod;
    SwapGatewayStub public immutable gw;
    SwapToken public immutable tokenIn;
    SwapToken public immutable tokenOut;
    SwapUser public immutable user;
    SwapToken public immutable loot;
    address public immutable feeVault;

    uint256 public ghost_swaps;
    /// Ghost: sum of the fees that were DUE, recomputed independently of the
    /// module so the invariant compares against arithmetic, not against the
    /// module's own bookkeeping.
    uint256 public ghost_feeDue;
    /// Ghost: total output the router produced across all swaps.
    uint256 public ghost_amountOut;
    /// Ghost: a swap whose declared tokenOut disagreed with the path end and
    /// was nonetheless accepted. Must stay 0 — that mismatch is an arbitrary
    /// ERC20 drain (the module would pay out a token it never received).
    uint256 public ghost_pathMismatchAccepted;

    constructor(SwapModule _mod, SwapGatewayStub _gw, SwapToken _in, SwapToken _out, SwapToken _loot, SwapUser _user, address _feeVault) {
        mod = _mod; gw = _gw; tokenIn = _in; tokenOut = _out; loot = _loot; user = _user; feeVault = _feeVault;
    }

    function _ctx() internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: address(user), originChainId: block.chainid,
            feeVault: feeVault, tokenSource: address(0),
            guid: bytes32(0)
        });
    }

    function _payload(address declaredOut, address pathEnd, uint256 amountIn)
        internal view returns (bytes memory)
    {
        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = pathEnd;
        SwapModule.SwapLocalParams memory p = SwapModule.SwapLocalParams({
            tokenIn: address(tokenIn),
            tokenOut: declaredOut,
            amountIn: amountIn,
            amountOutMin: 0,
            path: path,
            recipient: address(user),
            deadline: block.timestamp + 1000
        });
        return abi.encodePacked(uint8(IMagnetaGateway.OpType.SWAP_LOCAL), abi.encode(p));
    }

    function swap(uint256 amountIn) external {
        amountIn = bound(amountIn, 1e12, 1e22);
        if (tokenIn.balanceOf(address(user)) < amountIn) return;

        gw.call(address(mod), _ctx(), _payload(address(tokenOut), address(tokenOut), amountIn));
        ghost_swaps += 1;
        ghost_amountOut += amountIn;                       // stub is 1:1
        ghost_feeDue += (amountIn * mod.FEE_BPS()) / 10_000;
    }

    /// Adversarial: the actual drain. Seed the module with a THIRD token, then
    /// declare it as tokenOut while the path ends elsewhere. The router pays
    /// the path end; without the consistency check the module would hand the
    /// caller the seeded token it merely happens to hold.
    ///
    /// The seeding is the point. A first version of this action declared a
    /// token the module held none of, so removing the check made _sendOut
    /// revert on insufficient balance — the campaign stayed green with the
    /// guard deleted, proving nothing.
    function swapWithMismatchedPath(uint256 amountIn) external {
        amountIn = bound(amountIn, 1e12, 1e18);
        if (tokenIn.balanceOf(address(user)) < amountIn) return;
        if (loot.balanceOf(address(this)) < 1e20) return;

        loot.transfer(address(mod), 1e20);   // something worth stealing
        uint256 before = loot.balanceOf(address(user));

        // declared tokenOut = loot, path ends at tokenOut → inconsistent
        try gw.call(address(mod), _ctx(), _payload(address(loot), address(tokenOut), amountIn)) {
            if (loot.balanceOf(address(user)) > before) ghost_pathMismatchAccepted += 1;
        } catch {
            // expected
        }
    }
}

/// @notice Invariants for SwapModule — the contract that routes user swaps and
///         skims the 0.15 % Magneta fee.
///
///         S-1  The fee vault holds exactly the sum of the fees that were due,
///              recomputed independently of the module.
///         S-2  Fee + recipient payout == total router output. Nothing is
///              created, nothing evaporates.
///         S-3  A swap whose declared tokenOut disagrees with the end of the
///              path is ALWAYS refused. Accepting one lets a caller be paid in
///              a token the module merely happens to hold — the arbitrary-drain
///              bug the SSP path check was added to close.
contract SwapModuleInvariantTest is Test {
    SwapModule mod;
    SwapGatewayStub gw;
    SwapRouterStub router;
    SwapToken tokenIn;
    SwapToken tokenOut;
    SwapToken weth;
    SwapToken usdc;
    SwapToken loot;
    SwapUser user;
    SwapHandler handler;
    address constant FEE_VAULT = address(0xFEE0);

    function setUp() public {
        weth     = new SwapToken("WETH");
        usdc     = new SwapToken("USDC");
        tokenIn  = new SwapToken("IN");
        tokenOut = new SwapToken("OUT");
        router   = new SwapRouterStub(address(weth));
        gw       = new SwapGatewayStub();
        user     = new SwapUser();

        mod = new SwapModule(address(gw), address(router), address(usdc));

        tokenIn.transfer(address(user), 1e26);
        vm.prank(address(user));
        tokenIn.approve(address(mod), type(uint256).max);

        loot = new SwapToken("LOOT");
        handler = new SwapHandler(mod, gw, tokenIn, tokenOut, loot, user, FEE_VAULT);
        loot.transfer(address(handler), 1e26);   // ammo to seed the module with

        targetContract(address(handler));
    }

    /// S-1
    function invariant_FeeVaultHoldsExactlyWhatWasDue() public view {
        assertEq(
            tokenOut.balanceOf(FEE_VAULT),
            handler.ghost_feeDue(),
            "fee vault balance != sum of fees due"
        );
    }

    /// S-2
    function invariant_OutputIsFullyDistributed() public view {
        // Everything the router produced went to the vault or the recipient.
        assertEq(
            tokenOut.balanceOf(FEE_VAULT) + tokenOut.balanceOf(address(user)),
            handler.ghost_amountOut(),
            "router output is not fully accounted for between vault and recipient"
        );
    }

    /// S-3
    function invariant_PathMismatchAlwaysRefused() public view {
        assertEq(
            handler.ghost_pathMismatchAccepted(), 0,
            "a swap with tokenOut != path end was accepted - arbitrary ERC20 drain"
        );
    }
}

/// @notice Guards against a campaign that never reaches the module.
contract SwapReachabilityTest is SwapModuleInvariantTest {
    function test_SwapExecutesAndSplitsTheFee() public {
        uint256 amountIn = 1e21;
        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);

        SwapModule.SwapLocalParams memory p = SwapModule.SwapLocalParams({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: amountIn, amountOutMin: 0, path: path,
            recipient: address(user), deadline: block.timestamp + 1000
        });

        IModule.Context memory ctx = IModule.Context({
            caller: address(user), originChainId: block.chainid,
            feeVault: FEE_VAULT, tokenSource: address(0),
            guid: bytes32(0)
        });

        // NOT wrapped in try/catch — a revert must fail this test.
        gw.call(address(mod), ctx, abi.encodePacked(uint8(IMagnetaGateway.OpType.SWAP_LOCAL), abi.encode(p)));

        uint256 expectedFee = (amountIn * mod.FEE_BPS()) / 10_000;
        assertEq(tokenOut.balanceOf(FEE_VAULT), expectedFee, "fee not skimmed");
        assertEq(tokenOut.balanceOf(address(user)), amountIn - expectedFee, "recipient underpaid");
        assertEq(tokenOut.balanceOf(address(mod)), 0, "module retained output");
        assertEq(tokenIn.balanceOf(address(mod)), 0, "module retained input");
    }
}
