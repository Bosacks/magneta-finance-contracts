// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaServiceFee.sol";

/// @dev A feeVault that reenters `payFee` exactly once from its `receive()`,
///      re-spending the very ether it just received as the reentrant call's
///      `msg.value`. Models the "callback-capable feeVault" from F-25 —
///      the FeeVault is owner/Safe-controlled (trusted), but the contract
///      should not depend on that trust for its nonce bookkeeping to stay
///      coherent.
contract ReentrantVault {
    MagnetaServiceFee public immutable collector;
    bytes32 public immutable opId;
    bool public reentered;

    constructor(MagnetaServiceFee _collector, bytes32 _opId) {
        collector = _collector;
        opId = _opId;
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            collector.payFee{value: msg.value}(opId);
        }
    }
}

/// @notice Regression coverage for F-25: `payFee` used to forward native
///         currency to `feeVault` and only evaluate/increment `paymentNonce`
///         inside the `emit` line AFTER that external call returned. A
///         callback-capable feeVault reentering mid-call would therefore
///         reserve its own nonce BEFORE the original (outer) caller's nonce
///         got reserved — even though the outer call was invoked first —
///         inverting the causal order between "who called payFee first" and
///         "which nonce they got". This test pins that ordering: the call
///         that is INVOKED first (the outer, direct call from ALICE) must
///         receive the LOWER nonce, and the call that only runs because of
///         reentrancy (the inner call, made by the vault) must receive the
///         HIGHER nonce — regardless of which one's `emit` statement
///         executes/returns last.
///
///         Note: reserving the nonce before the external call does not, by
///         itself, stop a callback-capable vault from re-spending the same
///         forwarded ether to trigger a second accepted payment (that would
///         need `nonReentrant`, deliberately not added here — see the
///         comment on `payFee`). What it fixes, and what this test checks,
///         is that whichever payments ARE accepted get nonces in call-order,
///         not emit-order.
contract MagnetaServiceFeeReentrancyTest is Test {
    MagnetaServiceFee collector;
    ReentrantVault vault;

    address constant ALICE = address(0xA11CE);
    bytes32 constant OP = keccak256("REENTRANCY_TEST_OP");

    // keccak256("ServiceFeePaid(address,bytes32,uint256,uint256)")
    bytes32 constant SERVICE_FEE_PAID_TOPIC0 =
        keccak256("ServiceFeePaid(address,bytes32,uint256,uint256)");

    function setUp() public {
        // Deploy with a throwaway vault first so the constructor's
        // zero-address check is satisfied, then rotate to the reentrant one.
        collector = new MagnetaServiceFee(address(0xDEAD));
        vault = new ReentrantVault(collector, OP);
        collector.setFeeVault(address(vault));
        collector.setOpFee(OP, 1 ether);
    }

    function test_NonceReflectsInvocationOrderNotReturnOrder() public {
        vm.deal(ALICE, 1 ether);

        vm.recordLogs();
        vm.prank(ALICE);
        collector.payFee{value: 1 ether}(OP);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        address[] memory payers = new address[](2);
        uint256[] memory nonces = new uint256[](2);
        uint256 found;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(collector)) continue;
            if (logs[i].topics[0] != SERVICE_FEE_PAID_TOPIC0) continue;
            (uint256 amount, uint256 nonce) = abi.decode(logs[i].data, (uint256, uint256));
            address payer = address(uint160(uint256(logs[i].topics[1])));
            assertEq(amount, 1 ether, "unexpected amount in ServiceFeePaid");
            payers[found] = payer;
            nonces[found] = nonce;
            found++;
        }

        // Sanity: the reentrant vault must actually have fired twice through
        // payFee, or this test proves nothing about ordering.
        assertEq(found, 2, "expected exactly two ServiceFeePaid events (outer + reentrant)");
        assertTrue(vault.reentered(), "vault never reentered - test is not exercising F-25");

        // Logs are recorded in EMISSION order. Under the OLD (pre-fix) code,
        // the reentrant (vault) call's emit statement ran and returned
        // BEFORE the outer (Alice) call's emit statement, because the nonce
        // increment lived in the emit line itself, downstream of the
        // external call. So logs[0] would be the vault's payment with
        // nonce=0, and logs[1] would be Alice's payment with nonce=1 - the
        // call that was invoked SECOND got the LOWER nonce.
        //
        // With the fix, the nonce is reserved at the top of payFee, before
        // any external call. Alice's outer call reserves nonce 0 first; the
        // vault's inner (reentrant) call only starts running afterwards
        // and reserves nonce 1. Emission order is unchanged (vault's emit
        // still returns first, so logs[0] is still the vault's event) but
        // the nonce values now correctly reflect invocation order.
        uint256 vaultLogIndex = (payers[0] == address(vault)) ? 0 : 1;
        uint256 aliceLogIndex = (payers[0] == ALICE) ? 0 : 1;
        assertTrue(payers[aliceLogIndex] == ALICE, "did not find Alice's ServiceFeePaid event");
        assertTrue(payers[vaultLogIndex] == address(vault), "did not find the vault's reentrant ServiceFeePaid event");

        assertEq(nonces[aliceLogIndex], 0, "outer (first-invoked) call must reserve the lower nonce");
        assertEq(nonces[vaultLogIndex], 1, "inner (reentrant, second-invoked) call must reserve the higher nonce");

        assertEq(collector.paymentNonce(), 2, "final nonce counter should equal number of accepted payments");
    }
}
