// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/LPAtomicModule.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";
import "../contracts/interfaces/IModule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev A UniV2-style LP token that also answers `factory()`/`token0()`/
///      `token1()`. F-19: LPAtomicModule now verifies canonicity via
///      `factory.getPair(token0, token1) == pair` instead of trusting
///      `pair.factory()` alone, so the mock needs token0/token1 too.
contract PairToken is ERC20 {
    address public factory;
    address public token0;
    address public token1;
    constructor(address _factory, address _token0, address _token1) ERC20("LP", "LP") {
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
    }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
    function burn(address from, uint256 amt) external { _burn(from, amt); }
}

contract RouterStub {
    address public factory;
    constructor(address _factory) { factory = _factory; }
}

/// @dev A real, working UniV2-style factory: `getPair` is now load-bearing
///      (F-19) rather than a value that's merely compared for equality.
contract FactoryStub {
    mapping(bytes32 => address) private _pairs;
    function setPair(address tokenA, address tokenB, address pair) external {
        _pairs[_key(tokenA, tokenB)] = pair;
    }
    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[_key(tokenA, tokenB)];
    }
    function _key(address a, address b) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }
}

contract RegistryStub {
    mapping(address => bool) public allowed;
    function setAllowed(address r, bool v) external { allowed[r] = v; }
    function isRouterAllowed(address r) external view returns (bool) { return allowed[r]; }
}

/// @dev Stands in for MagnetaLpAtomicHelper.
///
///      `consumeBps` is the whole point: a helper that always pulls the full
///      approved amount can never leave a residue, which makes the SC06
///      `_refundDelta` guard unobservable and the invariant vacuous. Writing
///      the LPModule suite taught that the hard way — a too-obliging mock let
///      F7 and F52 be deleted with every test still green.
contract HelperStub {
    using SafeERC20 for IERC20;

    uint16 public consumeBps = 10_000;
    PairToken public newLp;

    constructor() { newLp = new PairToken(address(this), address(0xAAA1), address(0xAAA2)); }

    function setConsumeBps(uint16 bps) external { consumeBps = bps > 10_000 ? 10_000 : bps; }

    function _run(address pair, uint256 lpAmount, address user) internal {
        uint256 consumed = (lpAmount * consumeBps) / 10_000;
        if (consumed > 0) {
            // Pull only what is consumed, exactly like a helper that partially
            // fills. The remainder stays on the module and must be refunded.
            IERC20(pair).safeTransferFrom(msg.sender, address(this), consumed);
        }
        newLp.mint(user, consumed);
    }

    function compoundPositionFor(
        address pair, address, uint256 lpAmount, uint256, uint256, uint256, address user
    ) external { _run(pair, lpAmount, user); }

    function migratePositionFor(
        address srcPair, address, address, uint256 lpAmount, uint256, uint256, uint256, address user
    ) external { _run(srcPair, lpAmount, user); }
}

/// @dev Stands in for MagnetaGateway: LPAtomicModule only enforces
///      `msg.sender == gateway`.
contract GatewayStub2 {
    /// LPAtomicModule asserts a DVN quorum against the gateway at construction.
    function requiredDVNCount() external pure returns (uint8) { return 2; }

    function call(address module, IModule.Context memory ctx, bytes memory params)
        external payable returns (bytes memory)
    {
        return IModule(module).execute{value: msg.value}(ctx, params);
    }
    receive() external payable {}
}

contract AtomicUser {}

contract LPAtomicHandler is Test {
    LPAtomicModule public immutable mod;
    GatewayStub2 public immutable gw;
    PairToken public immutable pair;
    RouterStub public immutable router;
    RegistryStub public immutable registry;
    HelperStub public immutable helper;
    AtomicUser public immutable user;

    uint256 public ghost_opsOk;
    /// Ghost: LP transferred straight to the module. _refundDelta deliberately
    /// does NOT sweep it (SC06 anti-grief), so it must accumulate untouched.
    uint256 public ghost_donatedLp;
    /// Ghost: ops refused because the router was not on the allowlist.
    uint256 public ghost_allowlistRefusals;
    /// Ghost: an op through an UNLISTED router that was accepted. Must stay 0.
    /// A revert here would be useless - Foundry discards a reverting handler
    /// call, so the bypass would never surface as a failure.
    uint256 public ghost_unlistedAccepted;
    /// Ghost: a replayed payload that was accepted twice. Must stay 0.
    uint256 public ghost_replayAccepted;
    /// Ghost: an op carrying ETH that was accepted. Must stay 0.
    uint256 public ghost_ethAccepted;

    uint256 private nonce;

    constructor(
        LPAtomicModule _mod, GatewayStub2 _gw, PairToken _pair,
        RouterStub _router, RegistryStub _registry, HelperStub _helper, AtomicUser _user
    ) {
        mod = _mod; gw = _gw; pair = _pair; router = _router;
        registry = _registry; helper = _helper; user = _user;
    }

    function _ctx() internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: address(user),
            originChainId: block.chainid,
            feeVault: address(0xFEE0),
            tokenSource: address(0)
        });
    }

    function _compoundPayload(uint256 lpAmount, uint256 dl) internal returns (bytes memory) {
        // A fresh deadline each time keeps the replay guard from rejecting
        // legitimate repeats — the guard hashes (caller, op, inner).
        nonce++;
        LPAtomicModule.CompoundParams memory p = LPAtomicModule.CompoundParams({
            pair: address(pair),
            router: address(router),
            lpAmount: lpAmount,
            amountAMin: 1,
            amountBMin: 1,
            deadline: dl + nonce
        });
        return abi.encodePacked(uint8(IMagnetaGateway.OpType.POOL_FEE_COMPOUND), abi.encode(p));
    }

    function compound(uint256 lpAmount, uint16 consumeBps) external {
        lpAmount = bound(lpAmount, 1e12, 1e21);
        helper.setConsumeBps(uint16(bound(uint256(consumeBps), 0, 10_000)));
        if (pair.balanceOf(address(user)) < lpAmount) return;

        gw.call(address(mod), _ctx(), _compoundPayload(lpAmount, block.timestamp + 1000));
        ghost_opsOk += 1;
    }

    /// Adversarial: replay the exact same payload twice in one call.
    function replay(uint256 lpAmount) external {
        lpAmount = bound(lpAmount, 1e12, 1e18);
        if (pair.balanceOf(address(user)) < lpAmount * 2) return;

        bytes memory payload = _compoundPayload(lpAmount, block.timestamp + 1000);
        gw.call(address(mod), _ctx(), payload);
        try gw.call(address(mod), _ctx(), payload) {
            ghost_replayAccepted += 1;
        } catch {
            // expected
        }
    }

    /// Adversarial: point the op at a router that is not on the allowlist.
    function unlistedRouter(uint256 lpAmount) external {
        lpAmount = bound(lpAmount, 1e12, 1e18);
        if (pair.balanceOf(address(user)) < lpAmount) return;

        RouterStub rogue = new RouterStub(pair.factory()); // right factory, wrong router
        nonce++;
        LPAtomicModule.CompoundParams memory p = LPAtomicModule.CompoundParams({
            pair: address(pair), router: address(rogue), lpAmount: lpAmount,
            amountAMin: 1, amountBMin: 1, deadline: block.timestamp + 1000 + nonce
        });
        bytes memory payload =
            abi.encodePacked(uint8(IMagnetaGateway.OpType.POOL_FEE_COMPOUND), abi.encode(p));

        try gw.call(address(mod), _ctx(), payload) {
            ghost_unlistedAccepted += 1;
        } catch {
            ghost_allowlistRefusals += 1;
        }
    }

    /// Adversarial: attach ETH to an op. SC10 says it must always revert.
    function withEth(uint256 lpAmount, uint256 value) external {
        lpAmount = bound(lpAmount, 1e12, 1e18);
        value    = bound(value, 1 wei, 1 ether);
        if (pair.balanceOf(address(user)) < lpAmount) return;

        vm.deal(address(this), value);
        bytes memory payload = _compoundPayload(lpAmount, block.timestamp + 1000);
        try gw.call{value: value}(address(mod), _ctx(), payload) {
            ghost_ethAccepted += 1;
        } catch {
            // expected
        }
    }

    /// Environment: donate LP straight to the module (the SC06 grief vector).
    function donateLp(uint256 amount) external {
        amount = bound(amount, 1, 1e18);
        if (pair.balanceOf(address(this)) < amount) return;
        pair.transfer(address(mod), amount);
        ghost_donatedLp += amount;
    }
}

/// @notice Invariants for LPAtomicModule — until now the only fund-touching
///         module in the protocol with no test at all, and it moves a user's
///         entire LP position in one call.
///
///         LA-1  The module's LP balance always equals exactly what was
///               donated to it. Every wei of LP pulled for an operation is
///               either consumed by the helper or refunded (SC06 _refundDelta),
///               and a donation is never swept into someone else's refund.
///         LA-2  No standing helper allowance survives an operation.
///         LA-3  A payload can never execute twice (SC02 replay guard).
///         LA-4  A router outside the registry allowlist is always refused.
///         LA-5  An operation carrying ETH is always refused (SC10).
contract LPAtomicModuleInvariantTest is Test {
    LPAtomicModule mod;
    GatewayStub2 gw;
    PairToken pair;
    RouterStub router;
    FactoryStub factory;
    RegistryStub registry;
    HelperStub helper;
    AtomicUser user;
    LPAtomicHandler handler;
    address constant TOKEN0 = address(0x1111);
    address constant TOKEN1 = address(0x2222);

    function setUp() public {
        factory  = new FactoryStub();
        pair     = new PairToken(address(factory), TOKEN0, TOKEN1);
        router   = new RouterStub(address(factory));
        registry = new RegistryStub();
        helper   = new HelperStub();
        gw       = new GatewayStub2();
        user     = new AtomicUser();

        // F-19: register the canonical (token0, token1) -> pair mapping in
        // the real factory, which _checkRouterAndPair now consults directly
        // instead of trusting the pair's self-reported factory() value.
        factory.setPair(TOKEN0, TOKEN1, address(pair));

        registry.setAllowed(address(router), true);
        mod = new LPAtomicModule(address(gw), address(helper), address(registry));

        pair.mint(address(user), 1e26);
        vm.prank(address(user));
        pair.approve(address(mod), type(uint256).max);

        handler = new LPAtomicHandler(mod, gw, pair, router, registry, helper, user);
        pair.mint(address(handler), 1e24); // ammo for donateLp

        targetContract(address(handler));
    }

    /// LA-1
    function invariant_ModuleLpEqualsDonationsOnly() public view {
        assertEq(
            pair.balanceOf(address(mod)),
            handler.ghost_donatedLp(),
            "LPAtomicModule LP balance != donations - an op left LP behind or swept a donation"
        );
    }

    /// LA-2
    function invariant_NoStandingHelperAllowance() public view {
        assertEq(
            pair.allowance(address(mod), address(helper)),
            0,
            "LPAtomicModule left an allowance on the helper"
        );
    }

    /// LA-3
    function invariant_PayloadNeverReplays() public view {
        assertEq(handler.ghost_replayAccepted(), 0, "a replayed payload was accepted");
    }

    /// LA-4
    function invariant_UnlistedRouterAlwaysRefused() public view {
        assertEq(
            handler.ghost_unlistedAccepted(), 0,
            "an op through a router outside the registry allowlist was accepted"
        );
    }

    /// LA-5
    function invariant_EthNeverAccepted() public view {
        assertEq(handler.ghost_ethAccepted(), 0, "an operation carrying ETH was accepted");
    }
}

/// @notice Guards against the failure mode that made three earlier invariant
///         suites report PASS while never reaching the contract: if the ops
///         silently revert, every invariant above holds trivially.
contract LPAtomicReachabilityTest is LPAtomicModuleInvariantTest {
    function test_CompoundActuallyExecutesAndRefundsResidue() public {
        helper.setConsumeBps(6000); // 40 % left over -> _refundDelta must fire

        uint256 lpAmount = 1e20;
        uint256 userBefore = pair.balanceOf(address(user));

        LPAtomicModule.CompoundParams memory p = LPAtomicModule.CompoundParams({
            pair: address(pair), router: address(router), lpAmount: lpAmount,
            amountAMin: 1, amountBMin: 1, deadline: block.timestamp + 1000
        });

        IModule.Context memory ctx = IModule.Context({
            caller: address(user), originChainId: block.chainid,
            feeVault: address(0xFEE0), tokenSource: address(0)
        });

        // NOT wrapped in try/catch: a revert must fail this test.
        gw.call(
            address(mod), ctx,
            abi.encodePacked(uint8(IMagnetaGateway.OpType.POOL_FEE_COMPOUND), abi.encode(p))
        );

        // 60 % consumed by the helper, 40 % refunded to the user.
        assertEq(pair.balanceOf(address(user)), userBefore - (lpAmount * 6000) / 10_000, "residue not refunded");
        assertEq(pair.balanceOf(address(mod)), 0, "LP left in module");
        assertEq(pair.allowance(address(mod), address(helper)), 0, "allowance left on helper");
    }
}
