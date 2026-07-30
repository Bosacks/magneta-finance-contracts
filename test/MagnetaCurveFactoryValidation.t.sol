// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/curve/MagnetaCurveFactory.sol";

/// @dev Minimal router stub: MagnetaCurvePool's constructor calls
///      `router.WETH()`, and nothing else is exercised in these tests.
contract RouterWethStub {
    address public immutable weth;
    constructor(address _weth) { weth = _weth; }
    function WETH() external view returns (address) { return weth; }
}

contract FeeSink { receive() external payable {} }

/// @notice Regression coverage for:
///           F-26 — `setParameterBounds` accepted mutually-unsatisfiable
///                  bounds (no graduationThreshold could ever be both within
///                  [minGraduationThreshold, maxGraduationThreshold] and
///                  strictly greater than any legal virtualNativeReserve),
///                  bricking every future `createCurveToken` call.
///           F-27 — `getUserTokensPaginated` / `getAllTokensPaginated`
///                  computed `offset + limit` before clamping to the array
///                  length, panicking (arithmetic overflow, 0x11) on a large
///                  `limit` such as `type(uint256).max`.
contract MagnetaCurveFactoryValidationTest is Test {
    using stdStorage for StdStorage;

    MagnetaCurveFactory factory;
    RouterWethStub router;
    FeeSink feeVault;

    address constant OWNER   = address(0xA11CE);
    address constant CREATOR = address(0xB0B);

    function setUp() public {
        router   = new RouterWethStub(makeAddr("weth"));
        feeVault = new FeeSink();
        vm.prank(OWNER);
        factory = new MagnetaCurveFactory(address(router), address(feeVault), OWNER);
    }

    // ─────────────────────────── F-26 ───────────────────────────────────

    /// The literal scenario the finding describes: an owner narrows
    /// maxGraduationThreshold down to something at or below the
    /// (independently configured) minVirtualNativeReserve floor. Every
    /// future createCurveToken call needs `graduationThreshold >
    /// virtualNativeReserve >= minVirtualNativeReserve`, and
    /// `graduationThreshold <= maxGraduationThreshold` — impossible here.
    /// The OLD setParameterBounds only checked
    /// `_maxGraduationThreshold >= _minGraduationThreshold` (100 >= 1, true)
    /// and would have accepted this, bricking the launchpad.
    function test_SetParameterBoundsRevertsOnUnsatisfiableBounds() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("bounds unsatisfiable"));
        factory.setParameterBounds({
            _minVirtualNativeReserve: 1000 ether,
            _maxTotalSupply: 1e9 ether,
            _minGraduationThreshold: 1,
            _maxGraduationThreshold: 100
        });
    }

    /// The boundary of satisfiability: maxGraduationThreshold strictly above
    /// minVirtualNativeReserve must still be accepted (no over-tightening).
    function test_SetParameterBoundsAcceptsBoundaryOfSatisfiability() public {
        vm.prank(OWNER);
        factory.setParameterBounds({
            _minVirtualNativeReserve: 1 ether,
            _maxTotalSupply: 1e9 ether,
            _minGraduationThreshold: 1,
            _maxGraduationThreshold: 1 ether + 1
        });
        assertTrue(factory.boundsSatisfiable(), "boundary bounds should be satisfiable");

        // And it is genuinely usable: pick the tuple the require's own proof
        // constructs (graduationThreshold = minVirtualNativeReserve + 1).
        vm.prank(CREATOR);
        (address token, address pool) = factory.createCurveToken(
            "T", "T", "uri", 1_000_000 ether, 500_000 ether, 1 ether, 1 ether + 1
        );
        assertTrue(token != address(0) && pool != address(0), "boundary bounds rejected a valid launch");
    }

    /// Exactly at maxGraduationThreshold == minVirtualNativeReserve (not
    /// strictly greater) must still be rejected — graduationThreshold would
    /// have to simultaneously be <= minVirtualNativeReserve and >
    /// virtualNativeReserve >= minVirtualNativeReserve, which is impossible.
    function test_SetParameterBoundsRevertsWhenEqualNotStrictlyGreater() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("bounds unsatisfiable"));
        factory.setParameterBounds({
            _minVirtualNativeReserve: 1 ether,
            _maxTotalSupply: 1e9 ether,
            _minGraduationThreshold: 1,
            _maxGraduationThreshold: 1 ether
        });
    }

    /// `boundsSatisfiable()` is a pure function of state, independent of the
    /// setter's own guard. Force an unsatisfiable state directly into
    /// storage (bypassing setParameterBounds entirely) and confirm the view
    /// correctly reports `false` — proving the view genuinely re-derives the
    /// condition rather than just mirroring "the setter would have allowed
    /// this".
    function test_BoundsSatisfiableDetectsBadStateWrittenDirectly() public {
        assertTrue(factory.boundsSatisfiable(), "defaults must be satisfiable");

        stdstore.target(address(factory)).sig("maxGraduationThreshold()").checked_write(uint256(1));
        stdstore.target(address(factory)).sig("minVirtualNativeReserve()").checked_write(uint256(1000 ether));

        assertEq(factory.maxGraduationThreshold(), 1, "storage write did not land");
        assertEq(factory.minVirtualNativeReserve(), 1000 ether, "storage write did not land");
        assertFalse(factory.boundsSatisfiable(), "view failed to detect an unsatisfiable state");
    }

    // ─────────────────────────── F-27 ───────────────────────────────────

    function _launchToken(uint256 seed) internal returns (address token) {
        vm.prank(CREATOR);
        (token, ) = factory.createCurveToken(
            string(abi.encodePacked("Token", vm.toString(seed))),
            string(abi.encodePacked("T", vm.toString(seed))),
            "uri",
            1_000_000 ether,
            500_000 ether,
            0.01 ether,
            0.1 ether
        );
    }

    /// The exact repro from the finding: offset > 0 and limit =
    /// type(uint256).max used to compute `end = offset + limit`, which
    /// overflows uint256 and panics (0x11) instead of returning the
    /// remaining slice.
    function test_GetUserTokensPaginatedDoesNotOverflowWithMaxLimit() public {
        address t0 = _launchToken(0);
        address t1 = _launchToken(1);
        address t2 = _launchToken(2);

        address[] memory slice = factory.getUserTokensPaginated(CREATOR, 1, type(uint256).max);
        assertEq(slice.length, 2, "expected the 2 remaining tokens after offset 1");
        assertEq(slice[0], t1);
        assertEq(slice[1], t2);
        t0; // silence unused-var warning; kept for readability of the 3-token setup
    }

    function test_GetAllTokensPaginatedDoesNotOverflowWithMaxLimit() public {
        _launchToken(10);
        address t1 = _launchToken(11);
        address t2 = _launchToken(12);

        address[] memory slice = factory.getAllTokensPaginated(1, type(uint256).max);
        assertEq(slice.length, 2, "expected the 2 remaining tokens after offset 1");
        assertEq(slice[0], t1);
        assertEq(slice[1], t2);
    }

    /// offset == len still must not overflow and must return an empty slice.
    function test_GetAllTokensPaginatedMaxLimitAtExactLength() public {
        _launchToken(20);
        uint256 len = factory.getTokenCount();
        address[] memory slice = factory.getAllTokensPaginated(len, type(uint256).max);
        assertEq(slice.length, 0);
    }
}
