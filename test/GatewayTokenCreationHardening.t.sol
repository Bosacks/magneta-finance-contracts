// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/TokenCreationModule.sol";
import "../contracts/interfaces/IModule.sol";

/// @dev Minimal gateway stand-in: the module only reads requiredDVNCount from
///      it at construction and checks msg.sender in onlyGateway.
contract TokenCreationGatewayStub {
    function requiredDVNCount() external pure returns (uint8) { return 2; }
    function call(address module, IModule.Context memory ctx, bytes memory params)
        external payable returns (bytes memory)
    { return IModule(module).execute{value: msg.value}(ctx, params); }
}

contract TokenCreationFactoryStub {
    function createForCreator(
        address, string memory, string memory, string memory, uint256, bool, bool, bool
    ) external pure returns (address) { return address(0xF00D); }
}

contract TokenCreationHardeningTest is Test {
    TokenCreationGatewayStub gw;
    TokenCreationFactoryStub factory;
    TokenCreationModule mod;
    address user = makeAddr("creator");

    function setUp() public {
        gw = new TokenCreationGatewayStub();
        factory = new TokenCreationFactoryStub();
        mod = new TokenCreationModule(address(gw), address(factory), address(0));
    }

    function _ctx() internal view returns (IModule.Context memory) {
        return IModule.Context({
            caller: user, originChainId: block.chainid,
            feeVault: address(0xFEE0), tokenSource: address(0), guid: bytes32(0)
        });
    }

    // ── An out-of-range template selector panicked ────────────────────────

    /// `TemplateKind(uint8(params[0]))` reverts with Panic(0x21) above the last
    /// enum member, so UnsupportedTemplate was unreachable for precisely the
    /// inputs it describes — and a panic reads as a contract bug rather than a
    /// bad request, which matters when triaging a cross-chain failure.
    function test_UnknownTemplateSelectorGivesANamedError() public {
        bytes memory params = abi.encodePacked(uint8(200), abi.encode(uint256(1)));
        vm.expectRevert(TokenCreationModule.UnsupportedTemplate.selector);
        gw.call(address(mod), _ctx(), params);
    }

    function test_EmptyPayloadStillGivesInvalidPayload() public {
        vm.expectRevert(TokenCreationModule.InvalidPayload.selector);
        gw.call(address(mod), _ctx(), "");
    }

    // ── The constructor skipped the validation its setters enforce ────────

    function test_ConstructorRejectsAnEoaFactory() public {
        address eoa = makeAddr("notAContract");
        vm.expectRevert(bytes("TokenCreation: standardFactory not a contract"));
        new TokenCreationModule(address(gw), eoa, address(0));
    }

    function test_ConstructorRejectsAnEoaAutoLiquidityFactory() public {
        address eoa = makeAddr("notAContract2");
        vm.expectRevert(bytes("TokenCreation: autoLiquidityFactory not a contract"));
        new TokenCreationModule(address(gw), address(factory), eoa);
    }

    /// address(0) stays legal — it is the documented "not wired yet", which
    /// exists to break the module/factory circular dependency at deploy time.
    function test_ZeroFactoriesRemainLegalAtDeployTime() public {
        TokenCreationModule m = new TokenCreationModule(address(gw), address(0), address(0));
        assertEq(m.standardFactory(), address(0), "zero must stay allowed");
    }
}
