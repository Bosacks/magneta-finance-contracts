// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/TokenCreationModule.sol";
import "../contracts/interfaces/IModule.sol";
import "../contracts/mocks/MockOFTFactories.sol";

/// @notice Regression tests for audit-13 findings F-13, F-23, F-24, F-28 on
///         TokenCreationModule.
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
        return IModule.Context({
            caller: alice,
            originChainId: originChainId,
            feeVault: address(0xFEE0),
            tokenSource: address(0)
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
