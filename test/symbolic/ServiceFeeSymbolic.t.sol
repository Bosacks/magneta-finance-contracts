// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../../contracts/core/MagnetaServiceFee.sol";

/// @dev Sink that always accepts.
contract SymVault {
    receive() external payable {}
}

/// @title Symbolic proofs for the fee collector (Halmos).
///
/// Fuzzing samples; symbolic execution PROVES. Where Echidna and Foundry try
/// many concrete values and report "no counterexample found in N attempts",
/// Halmos reasons over every value a `uint256` can take at once and either
/// returns a counterexample or establishes the property holds for all inputs.
///
/// The fee collector is the right first target: small, pure value-handling, and
/// on the money path. Its properties are arithmetic statements about all
/// possible `msg.value` — exactly what a solver settles and sampling cannot.
///
/// Run:
///   PATH="$HOME/.foundry/bin:$PATH" halmos \
///     --contract ServiceFeeSymbolic --function check_
///
/// `check_` rather than `test_` so `forge test` leaves these alone: Foundry would
/// run them as ordinary fuzz tests, which is not what they are for.
contract ServiceFeeSymbolic is Test {
    MagnetaServiceFee collector;
    SymVault vault;

    function setUp() public {
        vault = new SymVault();
        collector = new MagnetaServiceFee(address(vault));
    }

    /// For ANY posted fee and ANY sent amount, payFee succeeds only when the two
    /// are equal. Proves there is no arithmetic path — overflow, comparison
    /// quirk, zero-handling — that lets a different amount through.
    function check_payFee_acceptsExactlyThePostedFee(uint256 posted, uint256 sent) public {
        vm.assume(posted > 0 && posted <= collector.maxOpFee());
        bytes32 opId = keccak256("SYMBOLIC_OP");
        collector.setOpFee(opId, posted);

        vm.deal(address(this), sent);
        (bool ok, ) = address(collector).call{value: sent}(
            abi.encodeWithSelector(collector.payFee.selector, opId)
        );

        // Success if and only if the amounts matched.
        assertEq(ok, sent == posted);
    }

    /// For ANY accepted payment, the collector keeps nothing. It has no
    /// withdrawal function, so any retained wei is permanently lost.
    function check_payFee_neverRetainsValue(uint256 posted) public {
        vm.assume(posted > 0 && posted <= collector.maxOpFee());
        bytes32 opId = keccak256("SYMBOLIC_OP");
        collector.setOpFee(opId, posted);

        vm.deal(address(this), posted);
        collector.payFee{value: posted}(opId);

        assertEq(address(collector).balance, 0);
    }

    /// For ANY accepted payment, the nonce advances by exactly one. The
    /// off-chain verifier treats (opId, nonce) as a single-use proof, so a nonce
    /// that could repeat or skip would let one payment unlock two operations.
    function check_payFee_advancesNonceByExactlyOne(uint256 posted) public {
        vm.assume(posted > 0 && posted <= collector.maxOpFee());
        bytes32 opId = keccak256("SYMBOLIC_OP");
        collector.setOpFee(opId, posted);

        uint256 before = collector.paymentNonce();
        vm.deal(address(this), posted);
        collector.payFee{value: posted}(opId);

        assertEq(collector.paymentNonce(), before + 1);
    }

    /// For ANY fee the owner tries to post, the cap holds at write time. This is
    /// the bound as actually implemented — note that lowering maxOpFee afterwards
    /// does NOT re-bind fees already stored (see ServiceFeeCapTest).
    function check_setOpFee_neverExceedsTheCap(uint256 fee) public {
        bytes32 opId = keccak256("SYMBOLIC_OP");
        uint256 cap = collector.maxOpFee();

        (bool ok, ) = address(collector).call(
            abi.encodeWithSelector(collector.setOpFee.selector, opId, fee)
        );

        assertEq(ok, fee <= cap);
        if (ok) assertLe(collector.opFee(opId), cap);
    }

    // A deliberately-false control (`assertEq(opFee, posted + 1)`) was run here
    // on 2026-07-30 and Halmos returned a counterexample in 0.16s across 3 paths,
    // confirming these proofs are reached rather than vacuously true. Removed
    // afterwards so the suite stays green; re-add it if the harness is reworked.

    receive() external payable {}
}
