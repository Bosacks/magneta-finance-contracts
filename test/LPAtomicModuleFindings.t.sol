// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/LPAtomicModule.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";
import "../contracts/interfaces/IModule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Regression tests for audit-13 findings F-13, F-20, F-22/F-31 on
///         LPAtomicModule. Kept as a dedicated file (rather than folding
///         into LPAtomicModuleInvariants.t.sol) so each finding maps to a
///         small, obviously-named, deterministic test instead of being
///         buried inside the invariant-fuzz handler.
///
///         F-13: requiredDVNCount() >= 2 was only checked in the
///         constructor. If the gateway is later reconfigured below the
///         2-DVN floor, the module must stop accepting execute() calls
///         immediately, not keep running under the old attestation.
///
///         F-20: the SC02 replay-guard key was
///         keccak256(abi.encode(ctx.caller, op, inner)) — it ignored
///         ctx.originChainId (and any other message-identifying data), so
///         two distinct authenticated messages from the same caller with
///         byte-identical op+params collided even when they legitimately
///         originated on different chains.
///
///         F-22 / F-31 (Sentinelle re-scan-15, "GUID dans le Context"): even
///         after F-20, two genuinely distinct authenticated cross-chain
///         messages from the SAME origin chain with byte-identical
///         op+params still collided, because IModule.Context carried no
///         per-message identifier. IModule.Context now carries `guid` (the
///         LayerZero GUID for bridged ops); the replay key is `ctx.guid`
///         alone whenever it is non-zero, so distinct GUIDs never collide
///         and a replayed GUID still reverts. The local, non-bridged path
///         (`ctx.guid == 0`) keeps the F-20 composite key unchanged.
contract FindingsPairToken is ERC20 {
    address public factory;
    address public token0;
    address public token1;
    constructor(address _factory, address _token0, address _token1) ERC20("LP", "LP") {
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
    }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract FindingsRouterStub {
    address public factory;
    constructor(address _factory) { factory = _factory; }
}

/// @dev F-19: a real, working UniV2-style factory whose `getPair` is
///      load-bearing — LPAtomicModule now asks IT for the canonical pair
///      instead of trusting the pair's self-reported `factory()`.
contract FindingsFactoryStub {
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

/// @dev F-19: a malicious "pair" that spoofs `factory()` to point at the
///      real, allowlisted factory but was never actually registered there
///      via getPair(token0, token1) — the exact attack the finding
///      describes. It also freely lies about its own token0/token1 (an
///      attacker controls both).
contract MaliciousPair {
    address public factory;
    address public token0;
    address public token1;
    constructor(address _factory, address _token0, address _token1) {
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
    }
}

contract FindingsRegistryStub {
    mapping(address => bool) public allowed;
    function setAllowed(address r, bool v) external { allowed[r] = v; }
    function isRouterAllowed(address r) external view returns (bool) { return allowed[r]; }
}

/// @dev Stands in for MagnetaLpAtomicHelper — always fully consumes the LP
///      it is approved for. The residual/partial-consume behavior is
///      already covered by LPAtomicModuleInvariants.t.sol; this file only
///      needs the happy path to reach _compound successfully.
contract FindingsHelperStub {
    FindingsPairToken public newLp;
    constructor() { newLp = new FindingsPairToken(address(this), address(0xAAA1), address(0xAAA2)); }

    function compoundPositionFor(
        address pair, address, uint256 lpAmount, uint256, uint256, uint256, address user
    ) external {
        IERC20(pair).transferFrom(msg.sender, address(this), lpAmount);
        newLp.mint(user, lpAmount);
    }

    function migratePositionFor(
        address srcPair, address, address, uint256 lpAmount, uint256, uint256, uint256, address user
    ) external {
        IERC20(srcPair).transferFrom(msg.sender, address(this), lpAmount);
        newLp.mint(user, lpAmount);
    }
}

/// @dev Gateway stub whose attested DVN quorum can be changed AFTER the
///      module is deployed — needed to exercise F-13's execution-time
///      recheck (the real MagnetaGateway supports this via
///      setRequiredDVNCount(), owner-only; this stub mirrors that surface).
contract MutableGatewayStub {
    uint8 public dvn = 2;
    function setRequiredDVNCount(uint8 v) external { dvn = v; }
    function requiredDVNCount() external view returns (uint8) { return dvn; }

    function call(address module, IModule.Context memory ctx, bytes memory params)
        external payable returns (bytes memory)
    {
        return IModule(module).execute{value: msg.value}(ctx, params);
    }
    receive() external payable {}
}

contract AtomicFindingsUser {}

contract LPAtomicModuleFindingsTest is Test {
    LPAtomicModule mod;
    MutableGatewayStub gw;
    FindingsPairToken pair;
    FindingsRouterStub router;
    FindingsFactoryStub factory;
    FindingsRegistryStub registry;
    FindingsHelperStub helper;
    AtomicFindingsUser user;
    address constant TOKEN0 = address(0x1111);
    address constant TOKEN1 = address(0x2222);

    function setUp() public {
        factory  = new FindingsFactoryStub();
        pair     = new FindingsPairToken(address(factory), TOKEN0, TOKEN1);
        router   = new FindingsRouterStub(address(factory));
        registry = new FindingsRegistryStub();
        helper   = new FindingsHelperStub();
        gw       = new MutableGatewayStub();
        user     = new AtomicFindingsUser();

        // F-19: the real factory must actually know about this pair.
        factory.setPair(TOKEN0, TOKEN1, address(pair));

        registry.setAllowed(address(router), true);
        mod = new LPAtomicModule(address(gw), address(helper), address(registry));

        pair.mint(address(user), 1e26);
        vm.prank(address(user));
        pair.approve(address(mod), type(uint256).max);
    }

    function _ctx(uint256 originChainId) internal view returns (IModule.Context memory) {
        // guid: bytes32(0) — simulates the local, non-bridged path so the
        // module falls back to the F-20 composite key. This is the pre-
        // existing helper used by the F-13/F-20/F-19 tests below; F-22/F-31
        // tests use `_ctxGuid` instead.
        return IModule.Context({
            caller: address(user),
            originChainId: originChainId,
            feeVault: address(0xFEE0),
            tokenSource: address(0),
            guid: bytes32(0)
        });
    }

    /// @dev F-22/F-31 helper: a Context carrying a non-zero message GUID,
    ///      simulating what MagnetaGateway now populates on every bridged
    ///      dispatch (_lzReceive / fulfillValueOp).
    function _ctxGuid(bytes32 guid) internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: address(user),
            originChainId: block.chainid,
            feeVault: address(0xFEE0),
            tokenSource: address(0),
            guid: guid
        });
    }

    function _compoundPayload(uint256 deadline) internal view returns (bytes memory) {
        LPAtomicModule.CompoundParams memory p = LPAtomicModule.CompoundParams({
            pair: address(pair),
            router: address(router),
            lpAmount: 1e18,
            amountAMin: 1,
            amountBMin: 1,
            deadline: deadline
        });
        return abi.encodePacked(uint8(IMagnetaGateway.OpType.POOL_FEE_COMPOUND), abi.encode(p));
    }

    // ─── F-13 ─────────────────────────────────────────────────────────────

    function test_F13_ExecuteAcceptsWhenGatewayQuorumStillMeetsFloor() public {
        // Sanity baseline: quorum untouched (2, same as constructor time).
        gw.call(address(mod), _ctx(block.chainid), _compoundPayload(block.timestamp + 1000));
    }

    function test_F13_ExecuteRevertsWhenGatewayQuorumDowngradedBelowFloor() public {
        // The module passed its constructor check at deploy time (quorum=2).
        // Governance later reconfigures the gateway down to a single-DVN
        // attestation WITHOUT redeploying the module. Without the F-13 fix
        // the module has no way to notice and keeps accepting execute()
        // calls under the weaker trust model — this must now fail closed.
        gw.setRequiredDVNCount(1);

        vm.expectRevert(abi.encodeWithSelector(LPAtomicModule.DVNQuorumTooLow.selector, uint8(1)));
        gw.call(address(mod), _ctx(block.chainid), _compoundPayload(block.timestamp + 1000));
    }

    function test_F13_ExecuteRevertsAtZeroQuorum() public {
        gw.setRequiredDVNCount(0);
        vm.expectRevert(abi.encodeWithSelector(LPAtomicModule.DVNQuorumTooLow.selector, uint8(0)));
        gw.call(address(mod), _ctx(block.chainid), _compoundPayload(block.timestamp + 1000));
    }

    // ─── F-20 ─────────────────────────────────────────────────────────────

    function test_F20_IdenticalParamsFromDifferentOriginChainsBothSucceed() public {
        // Two authenticated messages from the SAME caller with byte-identical
        // op + inner params (including deadline), arriving with different
        // ctx.originChainId — e.g. two legitimate LZ messages relayed from
        // two different sibling gateways. Before the fix, the replay key
        // ignored ctx.originChainId entirely, so the second call would
        // collide with the first and revert AlreadyExecuted even though it
        // is a distinct, legitimately authenticated message.
        bytes memory payload = _compoundPayload(block.timestamp + 1000);

        gw.call(address(mod), _ctx(1), payload); // "arrives from" chain id 1
        gw.call(address(mod), _ctx(2), payload); // "arrives from" chain id 2 — must NOT collide
    }

    function test_F20_LocalPathSameOriginSameParamsSecondCallStillReverts() public {
        // F-22/F-31 follow-up: this is now SPECIFICALLY the local
        // (non-bridged, ctx.guid == 0) fallback behavior, not a residual
        // limitation of the bridged path anymore. Two calls sharing the
        // same origin chain, same caller, same params, and no message GUID
        // are architecturally indistinguishable at the module layer under
        // the composite key and still collide by design — see
        // `test_F22_DistinctGuidsSameParamsBothSucceed` below for the fix
        // that now covers the bridged case.
        bytes memory payload = _compoundPayload(block.timestamp + 1000);

        gw.call(address(mod), _ctx(1), payload);
        vm.expectRevert(LPAtomicModule.AlreadyExecuted.selector);
        gw.call(address(mod), _ctx(1), payload);
    }

    // ─── F-22 / F-31 ──────────────────────────────────────────────────────
    // "GUID dans le Context" (Sentinelle re-scan-15): two LEGITIMATE and
    // DISTINCT cross-chain messages (different LayerZero GUIDs) with
    // byte-identical business params from the same origin chain used to
    // collide on the module-level replay key — a real problem at high
    // volume. ctx.guid fixes this: distinct GUIDs never collide, and a
    // replayed GUID is still rejected.

    function test_F22_DistinctGuidsSameParamsBothSucceed() public {
        bytes memory payload = _compoundPayload(block.timestamp + 1000);

        gw.call(address(mod), _ctxGuid(keccak256("lz-guid-1")), payload);
        // Same caller, same op, same inner params, same origin chain — only
        // the GUID differs. Before F-22/F-31 this would have collided with
        // the composite key and reverted AlreadyExecuted even though it is
        // a genuinely distinct, separately-authenticated LZ message.
        gw.call(address(mod), _ctxGuid(keccak256("lz-guid-2")), payload);
    }

    function test_F22_SameGuidReplayedReverts() public {
        bytes memory payload = _compoundPayload(block.timestamp + 1000);
        bytes32 guid = keccak256("lz-guid-replay");

        gw.call(address(mod), _ctxGuid(guid), payload);
        // The SAME GUID delivered twice (LZ redelivery, compromised gateway
        // path, etc.) must still be rejected — GUID-keyed replay protection
        // is not weaker than the composite key it replaces.
        vm.expectRevert(LPAtomicModule.AlreadyExecuted.selector);
        gw.call(address(mod), _ctxGuid(guid), payload);
    }

    // ─── F-19 ─────────────────────────────────────────────────────────────
    // Sentinelle rescan-15: _checkRouterAndPair used to compare only
    // pair.factory() == router.factory() — a value the "pair" contract
    // self-reports and can freely lie about. The fix asks the router's
    // factory directly: factory.getPair(token0, token1) must equal the
    // pair address itself.

    function _compoundPayloadFor(address pairAddr, uint256 deadline) internal view returns (bytes memory) {
        LPAtomicModule.CompoundParams memory p = LPAtomicModule.CompoundParams({
            pair: pairAddr,
            router: address(router),
            lpAmount: 1e18,
            amountAMin: 1,
            amountBMin: 1,
            deadline: deadline
        });
        return abi.encodePacked(uint8(IMagnetaGateway.OpType.POOL_FEE_COMPOUND), abi.encode(p));
    }

    function test_F19_GenuinePairPasses() public {
        // Sanity: the real pair, genuinely registered in the factory via
        // getPair(TOKEN0, TOKEN1), must still be accepted.
        gw.call(address(mod), _ctx(block.chainid), _compoundPayloadFor(address(pair), block.timestamp + 1000));
    }

    function test_F19_MaliciousPairSpoofingFactoryReverts() public {
        // Attacker deploys a fake "pair" that claims factory() == the real,
        // allowlisted factory (and freely lies about token0/token1 too), but
        // was never actually created by that factory — factory.getPair(...)
        // for whatever tokens it claims will not resolve back to THIS
        // contract's address. Before the fix, the old check only compared
        // pair.factory() == router.factory() and this would have passed.
        MaliciousPair evil = new MaliciousPair(address(factory), TOKEN0, TOKEN1);

        // Give the module something to pull so a false-negative (the module
        // wrongly accepting) would be observable via a real balance change,
        // not just silently reverting for an unrelated reason (no LP token
        // logic on MaliciousPair — but the revert must happen BEFORE any
        // token movement is even attempted, at the validation step).
        vm.expectRevert(
            abi.encodeWithSelector(LPAtomicModule.PairFactoryMismatch.selector, address(evil), address(router))
        );
        gw.call(address(mod), _ctx(block.chainid), _compoundPayloadFor(address(evil), block.timestamp + 1000));
    }

    function test_F19_MaliciousPairClaimingDifferentTokensReverts() public {
        // Same attack, but the malicious pair claims a token0/token1 pair
        // that was never registered with the factory at all (not even for a
        // different, legitimate pair) — factory.getPair returns address(0),
        // which trivially != the malicious pair's address.
        MaliciousPair evil = new MaliciousPair(address(factory), address(0x3333), address(0x4444));

        vm.expectRevert(
            abi.encodeWithSelector(LPAtomicModule.PairFactoryMismatch.selector, address(evil), address(router))
        );
        gw.call(address(mod), _ctx(block.chainid), _compoundPayloadFor(address(evil), block.timestamp + 1000));
    }
}
