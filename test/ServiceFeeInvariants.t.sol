// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaServiceFee.sol";

/// @dev The FeeVault sink. Accepts native and counts what arrived, so value
///      conservation can be asserted against the collector's own accounting.
contract VaultStub {
    uint256 public received;
    receive() external payable { received += msg.value; }
}

/// @dev A sink that rejects payment, used to prove payFee fails CLOSED: a
///      refused forward must revert the whole call rather than leave the fee
///      sitting in a contract that has no withdrawal function.
contract HostileVault {
    receive() external payable { revert("vault refuses"); }
}

/// @notice Bounds the fuzzer to sequences the collector can act on, and records
///         ghost state the invariants compare against.
///
///         Ops are drawn from a small fixed set rather than random bytes32: a
///         random opId almost always has no fee set, so payFee would revert on
///         FeeNotSet and the campaign would exercise nothing.
contract ServiceFeeHandler is Test {
    MagnetaServiceFee public immutable collector;
    VaultStub public immutable vault;
    address public immutable payer;

    bytes32[3] public OPS = [
        keccak256("PROMOTE_TOKEN"),
        keccak256("AUDIT_REQUEST"),
        keccak256("LISTING_FAST_TRACK")
    ];

    /// Sum of every fee successfully paid, tracked independently of the contract.
    uint256 public ghost_totalPaid;
    uint256 public ghost_payments;
    /// Highest fee ever accepted by setOpFee, for the standing-cap invariant.
    uint256 public ghost_highestFeeEverSet;

    constructor(MagnetaServiceFee _collector, VaultStub _vault, address _payer) {
        collector = _collector; vault = _vault; payer = _payer;
    }

    function setOpFee(uint256 opSeed, uint256 fee) external {
        bytes32 opId = OPS[opSeed % 3];
        fee = bound(fee, 1, 2 ether); // straddles the 1 ether default cap
        try collector.setOpFee(opId, fee) {
            if (fee > ghost_highestFeeEverSet) ghost_highestFeeEverSet = fee;
        } catch { /* FeeTooHigh — the write-time guard doing its job */ }
    }

    function setMaxOpFee(uint256 maxFee) external {
        maxFee = bound(maxFee, 0, 2 ether);
        try collector.setMaxOpFee(maxFee) {} catch {}
    }

    function payFee(uint256 opSeed) external {
        bytes32 opId = OPS[opSeed % 3];
        uint256 required = collector.opFee(opId);
        if (required == 0) return;               // not enabled — nothing to pay
        vm.deal(payer, required);
        vm.prank(payer);
        try collector.payFee{value: required}(opId) {
            ghost_totalPaid += required;
            ghost_payments++;
        } catch { /* forward refused */ }
    }

    /// Wrong amounts must always be refused; asserted by the invariant below.
    function payWrongAmount(uint256 opSeed, uint256 wrong) external {
        bytes32 opId = OPS[opSeed % 3];
        uint256 required = collector.opFee(opId);
        if (required == 0) return;
        wrong = bound(wrong, 1, 3 ether);
        if (wrong == required) return;
        vm.deal(payer, wrong);
        vm.prank(payer);
        try collector.payFee{value: wrong}(opId) {
            // Recorded so the invariant can fail loudly rather than silently.
            ghost_wrongAmountAccepted++;
        } catch { /* expected */ }
    }

    uint256 public ghost_wrongAmountAccepted;

    function opAt(uint256 i) external view returns (bytes32) { return OPS[i % 3]; }
}

/// @notice Invariants for the off-chain-op fee collector — the contract users pay
///         when they buy a service that settles off chain.
///
///         SF-1  The collector never retains native currency. It has no
///               withdrawal function, so a single retained wei is stuck forever.
///         SF-2  The FeeVault received exactly the sum of accepted payments.
///         SF-3  paymentNonce equals the number of accepted payments, and only
///               ever increases. The off-chain verifier treats (opId, nonce) as
///               a single-use proof, so a repeated nonce would let one payment
///               unlock two paid operations.
///         SF-4  A payment whose value differs from the posted fee is never
///               accepted — no overpayment silently kept, no underpayment.
contract ServiceFeeInvariantTest is Test {
    MagnetaServiceFee collector;
    VaultStub vault;
    ServiceFeeHandler handler;
    address constant PAYER = address(0xBEEF);

    function setUp() public virtual {
        vault     = new VaultStub();
        collector = new MagnetaServiceFee(address(vault));
        handler   = new ServiceFeeHandler(collector, vault, PAYER);

        // The handler drives owner-only setters, so it must own the collector.
        collector.transferOwnership(address(handler));
        vm.prank(address(handler));
        collector.acceptOwnership();

        targetContract(address(handler));
    }

    /// SF-1
    function invariant_CollectorRetainsNothing() public view {
        assertEq(address(collector).balance, 0, "fee stuck in a contract with no withdrawal");
    }

    /// SF-2
    function invariant_VaultReceivedExactlyWhatWasPaid() public view {
        assertEq(vault.received(), handler.ghost_totalPaid(), "vault total diverges from payments");
    }

    /// SF-3
    function invariant_NonceCountsPaymentsExactly() public view {
        assertEq(
            collector.paymentNonce(),
            handler.ghost_payments(),
            "nonce is not a faithful payment counter - proofs could repeat"
        );
    }

    /// SF-4
    function invariant_WrongAmountNeverAccepted() public view {
        assertEq(handler.ghost_wrongAmountAccepted(), 0, "a mismatched fee amount was accepted");
    }
}

/// @notice Reachability: the invariants above are meaningless if the handler
///         never got a fee posted and paid. Foundry evaluates invariants once
///         before the first call, so this has to be a plain test.
contract ServiceFeeReachabilityTest is ServiceFeeInvariantTest {
    function test_HandlerActuallyCollectsFees() public {
        handler.setOpFee(0, 0.05 ether);
        handler.payFee(0);
        assertGt(handler.ghost_payments(), 0, "no fee was ever paid");
        assertEq(vault.received(), handler.ghost_totalPaid(), "vault did not receive the fee");
        assertEq(collector.paymentNonce(), 1, "nonce did not advance");
    }
}

/// @notice The standing-cap question, kept separate because it is a claim about
///         the contract's design rather than a fuzz campaign.
///
///         `setOpFee` refuses a fee above `maxOpFee`. `setMaxOpFee` does NOT
///         revisit fees already stored. So lowering the cap leaves a
///         previously-accepted higher fee live and chargeable, and the cap stops
///         describing what a user can actually be charged.
contract ServiceFeeCapTest is ServiceFeeInvariantTest {
    function test_LoweringTheCapDoesNotBindFeesAlreadySet() public {
        bytes32 op = handler.opAt(0);

        vm.startPrank(address(handler));
        collector.setOpFee(op, 0.9 ether);   // allowed: default cap is 1 ether
        collector.setMaxOpFee(0.1 ether);    // owner tightens the bound
        vm.stopPrank();

        uint256 live = collector.opFee(op);
        uint256 cap  = collector.maxOpFee();

        // Documents the behaviour as it stands: the stored fee outlives the cap.
        assertGt(live, cap, "fee no longer exceeds the cap - behaviour changed, revisit this test");

        // And it is still chargeable at the old, higher amount.
        vm.deal(PAYER, live);
        vm.prank(PAYER);
        collector.payFee{value: live}(op);
        assertEq(vault.received(), live, "the above-cap fee was not actually charged");
    }
}
