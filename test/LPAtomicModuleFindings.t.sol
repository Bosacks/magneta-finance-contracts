// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/LPAtomicModule.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";
import "../contracts/interfaces/IModule.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Regression tests for audit-13 findings F-13 and F-20 on
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
contract FindingsPairToken is ERC20 {
    address public factory;
    constructor(address _factory) ERC20("LP", "LP") { factory = _factory; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract FindingsRouterStub {
    address public factory;
    constructor(address _factory) { factory = _factory; }
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
    constructor() { newLp = new FindingsPairToken(address(this)); }

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
    FindingsRegistryStub registry;
    FindingsHelperStub helper;
    AtomicFindingsUser user;
    address constant FACTORY = address(0xFAC0);

    function setUp() public {
        pair     = new FindingsPairToken(FACTORY);
        router   = new FindingsRouterStub(FACTORY);
        registry = new FindingsRegistryStub();
        helper   = new FindingsHelperStub();
        gw       = new MutableGatewayStub();
        user     = new AtomicFindingsUser();

        registry.setAllowed(address(router), true);
        mod = new LPAtomicModule(address(gw), address(helper), address(registry));

        pair.mint(address(user), 1e26);
        vm.prank(address(user));
        pair.approve(address(mod), type(uint256).max);
    }

    function _ctx(uint256 originChainId) internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: address(user),
            originChainId: originChainId,
            feeVault: address(0xFEE0),
            tokenSource: address(0)
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

    function test_F20_SameOriginSameParamsSecondCallStillReverts_KnownLimitation() public {
        // Documents the residual limitation acknowledged in the remediation:
        // IModule.Context carries no per-message GUID/nonce, only
        // originChainId. Two calls from the SAME origin chain with
        // byte-identical params are architecturally indistinguishable at
        // the module layer and still collide here. Real duplicate-GUID
        // replay of a single message is blocked one layer up, at
        // MagnetaGateway._lzReceive's `processedGuid[_guid]` check, before
        // the module is ever invoked — this module-level guard cannot see
        // the GUID because IModule.Context doesn't carry one.
        bytes memory payload = _compoundPayload(block.timestamp + 1000);

        gw.call(address(mod), _ctx(1), payload);
        vm.expectRevert(LPAtomicModule.AlreadyExecuted.selector);
        gw.call(address(mod), _ctx(1), payload);
    }
}
