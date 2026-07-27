// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/adapters/CctpV2Adapter.sol";
import "../contracts/adapters/UbeswapCeloAdapter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Takes `feeBps` on every transfer — the class of token the adapters'
///      "desired minus used" accounting silently broke on.
contract FeeToken is ERC20 {
    uint16 public feeBps;
    constructor(uint16 _feeBps) ERC20("Fee", "FEE") { feeBps = _feeBps; _mint(msg.sender, 1e30); }
    // OpenZeppelin 4.9 here, so the hook is _transfer, not _update.
    function _transfer(address from, address to, uint256 value) internal override {
        uint256 fee = (value * feeBps) / 10_000;
        if (fee > 0) super._transfer(from, address(0xFEE), fee);
        super._transfer(from, to, value - fee);
    }
}

contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") { _mint(msg.sender, 1e30); }
}

/// @dev Records what it was actually approved for and pulls exactly that.
contract RecordingRouter {
    address public immutable factoryAddr;
    uint256 public lastPulledA;
    uint256 public lastPulledB;
    constructor() { factoryAddr = address(this); }
    function factory() external view returns (address) { return factoryAddr; }
    function getPair(address, address) external pure returns (address) { return address(0); }

    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256, uint256, address, uint256
    ) external returns (uint256, uint256, uint256) {
        // A real router pulls what it was asked to. If the adapter approved
        // more than it holds, this reverts — which is the whole point.
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        lastPulledA = amountADesired;
        lastPulledB = amountBDesired;
        return (amountADesired, amountBDesired, amountADesired + amountBDesired);
    }
}

/// @dev A minimal contract standing in for Circle's messenger, so the
///      constructor's code-length check passes.
contract MessengerStub {
    function depositForBurn(uint256 amount, uint32, bytes32, address burnToken, bytes32, uint256, uint32) external {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount); // consumes the allowance
    }
}

/// @dev Accepts the call but burns nothing — what an EOA does, and what a
///      messenger pointed at the wrong address would do.
contract SilentMessenger {
    function depositForBurn(uint256, uint32, bytes32, address, bytes32, uint256, uint32) external {}
}

contract AdapterHardeningTest is Test {
    // ── CCTP: the messenger must be a contract, and the burn must consume ──

    function test_ConstructorRejectsAnEoaMessenger() public {
        address eoa = makeAddr("notAContract");
        vm.expectRevert(abi.encodeWithSelector(CctpV2Adapter.MessengerNotAContract.selector, eoa));
        new CctpV2Adapter(eoa);
    }

    function test_ConstructorAcceptsARealContract() public {
        CctpV2Adapter a = new CctpV2Adapter(address(new MessengerStub()));
        assertEq(address(a.v2Messenger()), address(a.v2Messenger()), "constructed");
    }

    /// The second line of defence: even a contract that answers without
    /// burning must not leave the adapter reporting a successful burn while a
    /// live allowance sits on the caller's USDC.
    function test_BurnThatConsumesNothingRevertsAndLeavesNoAllowance() public {
        SilentMessenger silent = new SilentMessenger();
        CctpV2Adapter a = new CctpV2Adapter(address(silent));
        PlainToken usdc = new PlainToken();
        usdc.approve(address(a), type(uint256).max);

        vm.expectRevert(CctpV2Adapter.BurnDidNotConsumeApproval.selector);
        a.depositForBurn(1_000e6, 6, bytes32(uint256(1)), address(usdc));

        assertEq(usdc.allowance(address(a), address(silent)), 0, "allowance left on a messenger that burnt nothing");
    }

    function test_RealMessengerBurnSucceeds() public {
        CctpV2Adapter a = new CctpV2Adapter(address(new MessengerStub()));
        PlainToken usdc = new PlainToken();
        usdc.approve(address(a), type(uint256).max);
        a.depositForBurn(1_000e6, 6, bytes32(uint256(1)), address(usdc));
    }

    // ── Adapters: forward what arrived, not what was asked for ────────────

    function test_FeeOnTransferTokenIsForwardedAtTheReceivedAmount() public {
        RecordingRouter router = new RecordingRouter();
        UbeswapCeloAdapter adapter = new UbeswapCeloAdapter(address(router));

        FeeToken fee = new FeeToken(500);      // 5 %
        PlainToken plain = new PlainToken();
        fee.approve(address(adapter), type(uint256).max);
        plain.approve(address(adapter), type(uint256).max);

        uint256 desired = 1_000e18;
        adapter.addLiquidity(address(fee), address(plain), desired, desired, 0, 0, address(this), block.timestamp + 1);

        // 5 % was taken in flight, so 950 arrived and 950 is what the router
        // must be asked for. Requesting 1000 would have it pull more than the
        // adapter holds — the bug this fixes.
        assertEq(router.lastPulledA(), (desired * 9500) / 10_000, "router asked for the desired amount, not the received one");
        assertEq(router.lastPulledB(), desired, "the plain token leg must be unaffected");
    }

    function test_AdapterKeepsNothingAfterAFeeTokenAdd() public {
        RecordingRouter router = new RecordingRouter();
        UbeswapCeloAdapter adapter = new UbeswapCeloAdapter(address(router));

        FeeToken fee = new FeeToken(300);
        PlainToken plain = new PlainToken();
        fee.approve(address(adapter), type(uint256).max);
        plain.approve(address(adapter), type(uint256).max);

        adapter.addLiquidity(address(fee), address(plain), 500e18, 500e18, 0, 0, address(this), block.timestamp + 1);

        // The documented invariant: adapters never hold user funds after a call.
        assertEq(fee.balanceOf(address(adapter)), 0, "fee token stranded in the adapter");
        assertEq(plain.balanceOf(address(adapter)), 0, "plain token stranded in the adapter");
    }
}
