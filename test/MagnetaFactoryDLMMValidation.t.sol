// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaFactory.sol";
import "../contracts/core/MagnetaPool.sol";
import "../contracts/tokens/MockERC20.sol";

/// @notice Regression coverage for F-14: `createDLMMPool` forwarded
///         tokenX/tokenY/feeRecipient/binStep/fee inputs to `MagnetaDLMM`'s
///         constructor without validating them at the factory level. Every
///         case here previously reverted only because MagnetaDLMM's own
///         constructor happened to catch it (deep inside the CREATE), not
///         because the factory did — these tests assert the factory now
///         fails fast with its own reason, and that a valid call still
///         succeeds.
contract MagnetaFactoryDLMMValidationTest is Test {
    MagnetaFactory factory;
    MagnetaPool standardPool;
    MockERC20 tokenX;
    MockERC20 tokenY;

    address constant OWNER    = address(0xA11CE);
    address constant CREATOR  = address(0xB0B);
    address constant RECIPIENT = address(0xFEE);

    function setUp() public {
        vm.startPrank(OWNER);
        standardPool = new MagnetaPool(OWNER);
        factory = new MagnetaFactory(address(standardPool), OWNER);
        vm.stopPrank();

        tokenX = new MockERC20("TokenX", "TKX", 18, 1_000_000 ether);
        tokenY = new MockERC20("TokenY", "TKY", 18, 1_000_000 ether);
    }

    function _validParams() internal view returns (
        address tX, address tY, uint16 binStep, uint16 lpFee, uint16 protoFee, uint24 activeId, address recipient
    ) {
        tX = address(tokenX);
        tY = address(tokenY);
        binStep = 25;
        lpFee = 30;
        protoFee = 10;
        activeId = 2 ** 23;
        recipient = RECIPIENT;
    }

    /// A well-formed call still succeeds after the new checks (no false positives).
    function test_ValidDLMMPoolStillDeploys() public {
        (address tX, address tY, uint16 binStep, uint16 lpFee, uint16 protoFee, uint24 activeId, address recipient) = _validParams();
        vm.prank(CREATOR);
        address pool = factory.createDLMMPool(tX, tY, binStep, lpFee, protoFee, activeId, recipient);
        assertTrue(pool != address(0), "pool not deployed");
    }

    function test_RevertsOnZeroTokenX() public {
        (, address tY, uint16 binStep, uint16 lpFee, uint16 protoFee, uint24 activeId, address recipient) = _validParams();
        vm.expectRevert(bytes("MagnetaFactory: zero token"));
        factory.createDLMMPool(address(0), tY, binStep, lpFee, protoFee, activeId, recipient);
    }

    function test_RevertsOnZeroTokenY() public {
        (address tX, , uint16 binStep, uint16 lpFee, uint16 protoFee, uint24 activeId, address recipient) = _validParams();
        vm.expectRevert(bytes("MagnetaFactory: zero token"));
        factory.createDLMMPool(tX, address(0), binStep, lpFee, protoFee, activeId, recipient);
    }

    function test_RevertsOnIdenticalTokens() public {
        (address tX, , uint16 binStep, uint16 lpFee, uint16 protoFee, uint24 activeId, address recipient) = _validParams();
        vm.expectRevert(bytes("MagnetaFactory: identical tokens"));
        factory.createDLMMPool(tX, tX, binStep, lpFee, protoFee, activeId, recipient);
    }

    function test_RevertsOnZeroFeeRecipient() public {
        (address tX, address tY, uint16 binStep, uint16 lpFee, uint16 protoFee, uint24 activeId,) = _validParams();
        vm.expectRevert(bytes("MagnetaFactory: zero fee recipient"));
        factory.createDLMMPool(tX, tY, binStep, lpFee, protoFee, activeId, address(0));
    }

    function test_RevertsOnZeroBinStep() public {
        (address tX, address tY, , uint16 lpFee, uint16 protoFee, uint24 activeId, address recipient) = _validParams();
        vm.expectRevert(bytes("MagnetaFactory: binStep out of range"));
        factory.createDLMMPool(tX, tY, 0, lpFee, protoFee, activeId, recipient);
    }

    function test_RevertsOnBinStepTooHigh() public {
        (address tX, address tY, , uint16 lpFee, uint16 protoFee, uint24 activeId, address recipient) = _validParams();
        vm.expectRevert(bytes("MagnetaFactory: binStep out of range"));
        factory.createDLMMPool(tX, tY, 501, lpFee, protoFee, activeId, recipient);
    }

    /// The specific F-14 example: uint16 fee inputs can represent up to
    /// 65535 bps each; without a factory-level cap this combination sails
    /// straight into `new MagnetaDLMM(...)` before anything checks it.
    function test_RevertsOnFeeSumTooHigh() public {
        (address tX, address tY, uint16 binStep, , , uint24 activeId, address recipient) = _validParams();
        vm.expectRevert(bytes("MagnetaFactory: dlmm fee too high"));
        factory.createDLMMPool(tX, tY, binStep, 40_000, 30_000, activeId, recipient);
    }

    /// Exactly at the cap (1000 bps = 10%) must still be allowed.
    function test_FeeSumExactlyAtCapSucceeds() public {
        (address tX, address tY, uint16 binStep, , , uint24 activeId, address recipient) = _validParams();
        vm.prank(CREATOR);
        address pool = factory.createDLMMPool(tX, tY, binStep, 600, 400, activeId, recipient);
        assertTrue(pool != address(0), "pool not deployed at cap");
    }

    function test_MaxDLMMTotalFeeBpsConstant() public view {
        assertEq(factory.MAX_DLMM_TOTAL_FEE_BPS(), 1000);
    }
}

/// @notice Regression coverage for F-32 (Sentinelle rescan-15): removePauser
///         did not clear {pauseGuardian} when the removed account was the
///         canonical guardian, leaving monitoring reading a guardian address
///         that can no longer call pause(). Mirrors the pattern already
///         applied in MagnetaLending / MagnetaBundler.
contract MagnetaFactoryPauserFindingsTest is Test {
    MagnetaFactory factory;
    MagnetaPool standardPool;

    address constant OWNER = address(0xA11CE);
    address constant GUARDIAN = address(0xC0FFEE);

    function setUp() public {
        vm.startPrank(OWNER);
        standardPool = new MagnetaPool(OWNER);
        factory = new MagnetaFactory(address(standardPool), OWNER);
        vm.stopPrank();
    }

    function test_F32_RemovePauser_ClearsCanonicalGuardian() public {
        vm.startPrank(OWNER);
        factory.setPauseGuardian(GUARDIAN);
        assertEq(factory.pauseGuardian(), GUARDIAN, "setup: guardian not set");
        assertTrue(factory.isPauser(GUARDIAN), "setup: guardian not a pauser");

        factory.removePauser(GUARDIAN);
        vm.stopPrank();

        assertEq(factory.pauseGuardian(), address(0), "F-32: pauseGuardian not cleared after removing the guardian");
        assertFalse(factory.isPauser(GUARDIAN), "guardian should no longer be a pauser");
    }

    /// Non-regression: removing an unrelated pauser must not clear the
    /// canonical guardian.
    function test_F32_RemovePauser_UnrelatedPauserDoesNotClearGuardian() public {
        address otherPauser = address(0xBEEF);
        vm.startPrank(OWNER);
        factory.setPauseGuardian(GUARDIAN);
        factory.addPauser(otherPauser);

        factory.removePauser(otherPauser);
        vm.stopPrank();

        assertEq(factory.pauseGuardian(), GUARDIAN, "unrelated removePauser must not clear the canonical guardian");
        assertFalse(factory.isPauser(otherPauser));
        assertTrue(factory.isPauser(GUARDIAN));
    }
}
