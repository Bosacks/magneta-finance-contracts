// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/TokenCreationModule.sol";
import "../contracts/interfaces/IModule.sol";
import "../contracts/mocks/MockOFTFactories.sol";

/// @notice Regression tests for audit-13 findings F-13, F-23, F-24, F-28,
///         and F-22/F-31 on TokenCreationModule.
///
///         F-13: requiredDVNCount() >= 2 was only checked in the
///         constructor — same architecture gap as LPAtomicModule, fixed the
///         same way (re-check on every execute() dispatch).
///         F-23: execute() is `payable` (IModule mandate) but never
///         rejected, forwarded, refunded, or recovered msg.value — any ETH
///         sent would be trapped forever.
///         F-24: no consumed-message mapping — a twice-delivered
///         authenticated CREATE_TOKEN payload created a duplicate token.
///         F-28: `_maybeRegisterToken` swallowed every registration
///         failure silently while `TokenSpawned` was emitted as though the
///         token were fully wired to TokenOpsModule.
///         F-22 / F-31 (Sentinelle re-scan-15, "GUID dans le Context"): two
///         genuinely distinct authenticated cross-chain messages from the
///         SAME origin chain with byte-identical params used to collide on
///         the F-24 composite key — a real problem at high volume.
///         IModule.Context now carries `guid`; the replay key is `ctx.guid`
///         alone whenever non-zero, so distinct GUIDs never collide and a
///         replayed GUID still reverts. The local (`ctx.guid == 0`) path
///         keeps the F-24 composite key unchanged.
contract TCMutableGatewayStub {
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

/// @dev Stands in for the local TokenOpsModule registration hook.
///      Configurable to succeed or revert with a chosen reason so F-28 can
///      assert both outcomes are observable via the new event.
contract TokenOpsRegistryStub {
    bool public shouldRevert;
    string public revertReason;
    address public lastRegistered;

    function setShouldRevert(bool v, string calldata reason) external {
        shouldRevert = v;
        revertReason = reason;
    }

    function registerByTokenOwner(address token) external {
        if (shouldRevert) revert(revertReason);
        lastRegistered = token;
    }
}

contract TokenCreationModuleFindingsTest is Test {
    bytes32 constant REGISTRATION_EVENT_SIG =
        keccak256("TokenOpsRegistration(address,bool,bytes)");

    TokenCreationModule mod;
    TCMutableGatewayStub gw;
    MockOFTStandardFactory standardFactory;
    MockOFTAutoLiquidityFactory autoLiquidityFactory;
    TokenOpsRegistryStub opsRegistry;

    address alice = address(0xA11CE);

    function setUp() public {
        gw = new TCMutableGatewayStub();
        standardFactory = new MockOFTStandardFactory();
        autoLiquidityFactory = new MockOFTAutoLiquidityFactory();
        opsRegistry = new TokenOpsRegistryStub();

        mod = new TokenCreationModule(
            address(gw), address(standardFactory), address(autoLiquidityFactory)
        );
        standardFactory.setCrossChainCreator(address(mod));
        autoLiquidityFactory.setCrossChainCreator(address(mod));
        mod.setTokenOpsModule(address(opsRegistry));
    }

    function _ctx(uint256 originChainId) internal view returns (IModule.Context memory) {
        // guid: bytes32(0) — simulates the local, non-bridged path so the
        // module falls back to the F-24 composite key. F-22/F-31 tests use
        // `_ctxGuid` instead.
        return IModule.Context({
            caller: alice,
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
            caller: alice,
            originChainId: block.chainid,
            feeVault: address(0xFEE0),
            tokenSource: address(0),
            guid: guid
        });
    }

    function _standardPayload(string memory name) internal pure returns (bytes memory) {
        TokenCreationModule.StandardParams memory p = TokenCreationModule.StandardParams({
            name: name,
            symbol: "SYM",
            tokenURI: "uri",
            totalSupply: 1_000_000e18,
            revokeUpdate: false,
            revokeFreeze: false,
            revokeMint: false
        });
        return abi.encodePacked(uint8(TokenCreationModule.TemplateKind.Standard), abi.encode(p));
    }

    function _findRegistrationEvent(Vm.Log[] memory logs)
        internal
        pure
        returns (bool found, bool success, bytes memory revertData, address token)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == REGISTRATION_EVENT_SIG) {
                token = address(uint160(uint256(logs[i].topics[1])));
                success = logs[i].topics[2] != bytes32(0);
                revertData = abi.decode(logs[i].data, (bytes));
                found = true;
            }
        }
    }

    // ─── F-13 ─────────────────────────────────────────────────────────────

    function test_F13_ExecuteAcceptsWhenGatewayQuorumStillMeetsFloor() public {
        gw.call(address(mod), _ctx(block.chainid), _standardPayload("A"));
    }

    function test_F13_ExecuteRevertsWhenGatewayQuorumDowngradedBelowFloor() public {
        // Same architecture gap as LPAtomicModule: the module passed its
        // constructor check at deploy time (quorum=2); governance later
        // downgrades the gateway to a single-DVN attestation without a
        // module redeploy. Must fail closed on the very next dispatch.
        gw.setRequiredDVNCount(1);

        vm.expectRevert(abi.encodeWithSelector(TokenCreationModule.DVNQuorumTooLow.selector, uint8(1)));
        gw.call(address(mod), _ctx(block.chainid), _standardPayload("A"));
    }

    // ─── F-23 ─────────────────────────────────────────────────────────────

    function test_F23_ExecuteRevertsOnNonZeroMsgValue() public {
        // Before the fix, this ETH would be pulled into the module by
        // `execute{value: ...}` and never forwarded, refunded, or
        // recoverable — permanently trapped.
        vm.deal(address(gw), 1 ether);
        vm.expectRevert(TokenCreationModule.EthNotAccepted.selector);
        gw.call{value: 1 ether}(address(mod), _ctx(block.chainid), _standardPayload("A"));
    }

    function test_F23_ExecuteAcceptsZeroMsgValue() public {
        // Sanity: the normal (no ETH attached) path is unaffected.
        gw.call{value: 0}(address(mod), _ctx(block.chainid), _standardPayload("A"));
    }

    // ─── F-24 ─────────────────────────────────────────────────────────────

    function test_F24_ReplayedPayloadRevertsOnSecondDelivery() public {
        // A twice-delivered authenticated CREATE_TOKEN payload (e.g. a
        // gateway/relayer bug redelivering the same message) must not spawn
        // a second token.
        bytes memory payload = _standardPayload("Dup");
        gw.call(address(mod), _ctx(1), payload);

        vm.expectRevert(TokenCreationModule.AlreadyExecuted.selector);
        gw.call(address(mod), _ctx(1), payload);
    }

    function test_F24_IdenticalParamsFromDifferentOriginChainsBothSucceed() public {
        // Mirrors LPAtomicModule's F-20 fix: two distinct, legitimately
        // authenticated messages from different origin chains with
        // byte-identical params must NOT collide.
        bytes memory payload = _standardPayload("Dup2");
        gw.call(address(mod), _ctx(1), payload);
        gw.call(address(mod), _ctx(2), payload);
    }

    // ─── F-22 / F-31 ──────────────────────────────────────────────────────
    // "GUID dans le Context" (Sentinelle re-scan-15): two LEGITIMATE and
    // DISTINCT cross-chain messages (different LayerZero GUIDs) with
    // byte-identical CREATE_TOKEN params from the same origin chain used to
    // collide on the F-24 composite key. At high volume (many creators
    // spawning tokens with popular default names/symbols from the same
    // chain) this is a real liveness problem, not just a theoretical edge
    // case. ctx.guid fixes it: distinct GUIDs never collide, and a replayed
    // GUID is still rejected.

    function test_F22_DistinctGuidsSameParamsBothSucceed() public {
        bytes memory payload = _standardPayload("SameName");

        gw.call(address(mod), _ctxGuid(keccak256("lz-guid-1")), payload);
        // Same caller, same template kind, same inner params, same origin
        // chain — only the GUID differs. Before F-22/F-31 this would have
        // collided with the F-24 composite key and reverted AlreadyExecuted
        // even though it is a genuinely distinct, separately-authenticated
        // LZ message (e.g. two different users' fan-outs happening to pick
        // the same default token name+symbol).
        gw.call(address(mod), _ctxGuid(keccak256("lz-guid-2")), payload);
    }

    function test_F22_SameGuidReplayedReverts() public {
        bytes memory payload = _standardPayload("ReplayName");
        bytes32 guid = keccak256("lz-guid-replay");

        gw.call(address(mod), _ctxGuid(guid), payload);
        // The SAME GUID delivered twice must still be rejected — GUID-keyed
        // replay protection is not weaker than the composite key it
        // replaces for the bridged path.
        vm.expectRevert(TokenCreationModule.AlreadyExecuted.selector);
        gw.call(address(mod), _ctxGuid(guid), payload);
    }

    function test_F22_LocalPathSameParamsSecondCallStillReverts() public {
        // ctx.guid == 0 (local, non-bridged path) keeps the pre-existing
        // F-24 composite-key behavior unchanged: two calls sharing the same
        // origin chain, caller, and params with no message GUID still
        // collide and the second reverts. This is exactly
        // test_F24_ReplayedPayloadRevertsOnSecondDelivery above, restated
        // here for symmetry with the LPAtomicModule findings file.
        bytes memory payload = _standardPayload("LocalDup");
        gw.call(address(mod), _ctx(1), payload);

        vm.expectRevert(TokenCreationModule.AlreadyExecuted.selector);
        gw.call(address(mod), _ctx(1), payload);
    }

    // ─── F-28 ─────────────────────────────────────────────────────────────

    function test_F28_EmitsSuccessEventWhenRegistrationSucceeds() public {
        opsRegistry.setShouldRevert(false, "");

        vm.recordLogs();
        bytes memory result = gw.call(address(mod), _ctx(block.chainid), _standardPayload("Ok"));
        address expectedToken = abi.decode(result, (address));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, bool success, bytes memory revertData, address token) =
            _findRegistrationEvent(logs);

        assertTrue(found, "TokenOpsRegistration not emitted");
        assertTrue(success, "expected success=true");
        assertEq(token, expectedToken, "wrong token in event");
        assertEq(revertData.length, 0, "unexpected revert data on success");
        assertEq(opsRegistry.lastRegistered(), expectedToken, "registry never actually called");
    }

    function test_F28_EmitsFailureEventWithRevertDataWhenRegistrationFails() public {
        opsRegistry.setShouldRevert(true, "boom");

        vm.recordLogs();
        // Before F-28: this call would emit TokenSpawned with no signal at
        // all that registration failed. It must still succeed (creation is
        // not blocked by a registration failure) but now also emit the
        // failure explicitly.
        bytes memory result = gw.call(address(mod), _ctx(block.chainid), _standardPayload("Fail"));
        address expectedToken = abi.decode(result, (address));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, bool success, bytes memory revertData, address token) =
            _findRegistrationEvent(logs);

        assertTrue(found, "TokenOpsRegistration not emitted");
        assertFalse(success, "expected success=false");
        assertEq(token, expectedToken, "wrong token in event");
        assertGt(revertData.length, 0, "expected non-empty revert data");
        // Error(string) selector, since TokenOpsRegistryStub reverts with revert("boom").
        assertEq(bytes4(revertData), bytes4(0x08c379a0), "expected Error(string) selector");

        // Token creation itself must not have been blocked by the
        // registration failure.
        assertTrue(expectedToken != address(0), "token was not created despite registration failure");
    }
}
