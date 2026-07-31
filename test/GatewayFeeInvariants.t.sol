// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/core/MagnetaGateway.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";
import "../contracts/interfaces/IModule.sol";
import "../contracts/mocks/MockLayerZeroEndpoint.sol";

/// @dev Minimal well-behaved module: consumes the forwarded value like a real
///      module would (spends it, keeps nothing). Lets the invariant campaign
///      drive executeOperation without dragging the full LPModule setup in —
///      the gateway-level fee properties do not depend on what the module does
///      with its opValue, only on what the GATEWAY retains and skims.
contract SinkModule is IModule {
    address public immutable gateway;
    address public immutable drain;

    constructor(address _gateway, address _drain) {
        gateway = _gateway;
        drain = _drain;
    }

    function execute(Context calldata, bytes calldata)
        external
        payable
        override
        returns (bytes memory)
    {
        require(msg.sender == gateway, "only gateway");
        if (msg.value > 0) {
            (bool ok, ) = drain.call{value: msg.value}("");
            require(ok, "drain failed");
        }
        return "";
    }
}

/// @dev Bounded random driver for the invariant campaign. Foundry calls these
///      functions in random order with random arguments; the ghost counters
///      record what SHOULD have happened so the invariants can compare against
///      what actually did.
contract GatewayFeeHandler is Test {
    MagnetaGateway public immutable gw;
    address public immutable feeVault;

    /// Ghost: every wei the fee-skim should have sent to the vault.
    uint256 public ghost_feesSkimmed;
    /// Ghost: every wei sent to the gateway OUTSIDE executeOperation (its
    /// receive() accepts donations, e.g. LZ refunds — they are allowed to sit).
    uint256 public ghost_donated;
    /// Ghost: number of ops that succeeded / that were correctly refused.
    uint256 public ghost_opsOk;
    uint256 public ghost_underpaidRefused;
    /// Ghost: times an op paying LESS than the fee was accepted. Must stay 0.
    uint256 public ghost_feeBypassed;
    /// Ghost: every wei that ever left the handler (ops + donations). The
    /// conservation invariant compares this against where it ended up.
    uint256 public ghost_sent;

    IMagnetaGateway.OpType constant OP = IMagnetaGateway.OpType.CREATE_LP;

    constructor(MagnetaGateway _gw, address _feeVault) {
        gw = _gw;
        feeVault = _feeVault;
    }

    /// Owner action: move the fee around, within the on-chain cap.
    function setFee(uint256 fee) external {
        fee = bound(fee, 0, gw.maxOpServiceFeeNative());
        gw.setOpServiceFeeNative(OP, fee);
    }

    /// User action: run an op paying fee + opValue.
    function runOp(uint256 opValue) external {
        opValue = bound(opValue, 0, 5 ether);
        uint256 fee = gw.opServiceFeeNative(OP);
        uint256 total = fee + opValue;
        vm.deal(address(this), total);

        gw.executeOperation{value: total}(OP, "");
        ghost_feesSkimmed += fee;
        ghost_sent += total;
        ghost_opsOk += 1;
    }

    /// Adversarial action: try to pay LESS than the fee. Must always revert —
    /// if it ever goes through, the skim was bypassed.
    function runOpUnderpaid(uint256 shortfall) external {
        uint256 fee = gw.opServiceFeeNative(OP);
        if (fee == 0) return; // nothing to underpay
        shortfall = bound(shortfall, 1, fee);
        uint256 sent = fee - shortfall;
        vm.deal(address(this), sent);

        // NOTE: reverting here would be USELESS. Foundry discards a reverting
        // handler call and moves on, so a genuine fee bypass would show up as
        // a "revert" in the stats and the campaign would still report PASS.
        // The bypass has to be recorded in a ghost that an invariant asserts on.
        try gw.executeOperation{value: sent}(OP, "") {
            ghost_feeBypassed += 1;
        } catch {
            ghost_underpaidRefused += 1;
        }
    }

    /// Environment action: a donation to the gateway (LZ refund pattern).
    /// Allowed to accumulate — the invariant must not confuse it with
    /// op-driven retention.
    function donate(uint256 amount) external {
        amount = bound(amount, 1 wei, 1 ether);
        vm.deal(address(this), amount);
        (bool ok, ) = address(gw).call{value: amount}("");
        require(ok, "donation refused");
        ghost_donated += amount;
        ghost_sent += amount;
    }
}

/// @notice Invariants for the money path of MagnetaGateway.executeOperation.
///
///         GW-1  The FeeVault holds exactly the sum of the skims that were due
///               — never less (fee lost/kept) and never more (over-charge).
///         GW-2  The gateway retains nothing from operations: its balance is
///               exactly what was donated to receive() outside of ops.
///         GW-3  Paying below the configured fee always reverts (checked
///               adversarially inside the handler; surfaced here as a counter
///               so a silent bypass fails the run).
contract GatewayFeeInvariantTest is Test {
    MagnetaGateway gw;
    GatewayFeeHandler handler;
    address constant FEE_VAULT = address(0xFEE0);
    address constant MODULE_DRAIN = address(0xD8A1);

    function setUp() public {
        MockLayerZeroEndpoint ep = new MockLayerZeroEndpoint(30184);
        gw = new MagnetaGateway(address(ep), address(this), FEE_VAULT);
        gw.setRequiredDVNCount(2);

        SinkModule module = new SinkModule(address(gw), MODULE_DRAIN);
        gw.setModule(IMagnetaGateway.OpType.CREATE_LP, address(module));

        handler = new GatewayFeeHandler(gw, FEE_VAULT);
        // The handler drives owner actions (setFee) too, so hand it ownership.
        // MagnetaGateway is Ownable2Step: transferOwnership only nominates,
        // the new owner must accept. Forgetting the second call left setFee
        // reverting on every single run - the campaign then explored only the
        // fee == 0 branch and proved nothing while reporting PASS.
        gw.transferOwnership(address(handler));
        vm.prank(address(handler));
        gw.acceptOwnership();
        assertEq(gw.owner(), address(handler), "handler must own the gateway");

        targetContract(address(handler));
    }

    /// GW-1: vault balance == exact sum of due skims.
    function invariant_FeeVaultHoldsExactlyTheSkims() public view {
        assertEq(
            FEE_VAULT.balance,
            handler.ghost_feesSkimmed(),
            "FeeVault balance != sum of due service-fee skims"
        );
    }

    /// GW-2: the gateway keeps nothing from ops — only explicit donations sit.
    function invariant_GatewayRetainsNothingFromOps() public view {
        assertEq(
            address(gw).balance,
            handler.ghost_donated(),
            "gateway retained value from executeOperation"
        );
    }

    /// GW-3: every wei the handler ever sent is accounted for. Ops split into
    ///       fee -> FEE_VAULT and opValue -> module -> MODULE_DRAIN; donations
    ///       stay on the gateway. Nothing may end up anywhere else, and nothing
    ///       may vanish.
    function invariant_ValueConservation() public view {
        assertEq(
            FEE_VAULT.balance + MODULE_DRAIN.balance + address(gw).balance,
            handler.ghost_sent(),
            "total value in != vault + module + gateway"
        );
    }

    /// GW-4: an op paying less than the configured fee is never accepted.
    function invariant_FeeCanNeverBeBypassed() public view {
        assertEq(handler.ghost_feeBypassed(), 0, "an underpaid op was accepted");
    }
}
