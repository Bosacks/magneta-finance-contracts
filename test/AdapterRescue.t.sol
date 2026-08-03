// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/adapters/DragonSwapSeiAdapter.sol";
import "../contracts/adapters/MoeRouterAdapter.sol";
import "../contracts/adapters/TraderJoeAvaxAdapter.sol";
import "../contracts/adapters/UbeswapCeloAdapter.sol";
import "../contracts/mocks/MockUniV2NativeRouter.sol";

/// @title AdapterRescueTest
/// @notice Proves the rescue surface added to the four live `defaultRouter`
///         adapters (sei / avalanche / mantle / celo) does what its name says
///         and nothing more:
///           - stranded ERC20 and stranded native leave the adapter and land on
///             the named recipient, measured as balances, not as "it didn't
///             revert";
///           - nobody but the owner can move them, and Ownable2Step means a
///             transfer is not a handover until it is accepted;
///           - the owner cannot use it to take funds that belong to an
///             operation still in flight — asserted by running a real
///             `addLiquidity` / `addLiquidityETH` whose token calls back into
///             `sweep` / `sweepNative` from the OWNER address, and checking
///             where the money ended up afterwards.
///
///         Every test that claims a theft is prevented ends on a balance
///         assertion against the attacker, not on an expectRevert.

// ─── Common surface across the four adapters ──────────────────────────────

interface IAdapterRescue {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
    function sweep(address token, address to) external;
    function sweepNative(address to) external;
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256, uint256, uint256);
    function addLiquidityETH(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
}

contract PlainToken is ERC20 {
    constructor(string memory n) ERC20(n, n) { _mint(msg.sender, 1e30); }
}

/// @dev A token with a transfer callback — the only mechanism by which an
///      owner can reach INTO a user's operation, since the adapter holds user
///      funds for the duration of one transaction and nothing longer. Owns the
///      adapter under test (via Ownable2Step accept) and tries to sweep at the
///      exact moment the adapter is holding someone else's money.
contract ReentrantSweepToken is ERC20 {
    address public adapter;
    address public victimToken;
    address public attacker;
    bool    public armed;
    uint8   public mode;          // 0 = sweep(erc20), 1 = sweepNative
    bool    public sweepAttempted;
    bool    public sweepReverted;
    bytes   public sweepRevertData;

    constructor() ERC20("Reenter", "RNT") { _mint(msg.sender, 1e30); }

    function arm(address _adapter, address _victimToken, address _attacker, uint8 _mode) external {
        adapter        = _adapter;
        victimToken    = _victimToken;
        attacker       = _attacker;
        mode           = _mode;
        armed          = true;
        sweepAttempted = false;
        sweepReverted  = false;
    }

    function acceptAdapterOwnership() external {
        IAdapterRescue(adapter).acceptOwnership();
    }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        // Fires exactly once, on the leg that credits the adapter — i.e. while
        // the adapter is mid-operation and holding the user's other leg.
        if (armed && to == adapter) {
            armed = false;
            sweepAttempted = true;
            if (mode == 0) {
                try IAdapterRescue(adapter).sweep(victimToken, attacker) {}
                catch (bytes memory reason) { sweepReverted = true; sweepRevertData = reason; }
            } else {
                try IAdapterRescue(adapter).sweepNative(attacker) {}
                catch (bytes memory reason) { sweepReverted = true; sweepRevertData = reason; }
            }
        }
    }

    receive() external payable {}
}

contract AdapterRescueTest is Test {
    MockUniV2NativeRouter router;
    PlainToken weth;                    // stands in for WSEI / wNative / WAVAX

    DragonSwapSeiAdapter  dragon;
    MoeRouterAdapter      moe;
    TraderJoeAvaxAdapter  joe;
    UbeswapCeloAdapter    ube;

    IAdapterRescue[4] adapters;
    string[4] names;

    address stranger  = makeAddr("stranger");
    address recipient = makeAddr("recipient");
    address attacker  = makeAddr("attacker");
    address user      = makeAddr("user");

    bytes32 constant REENTRANCY_REVERT =
        keccak256(abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));

    function setUp() public {
        weth   = new PlainToken("WNATIVE");
        router = new MockUniV2NativeRouter(address(weth));

        dragon = new DragonSwapSeiAdapter(address(router));
        moe    = new MoeRouterAdapter(address(router));
        joe    = new TraderJoeAvaxAdapter(address(router));
        ube    = new UbeswapCeloAdapter(address(router));

        adapters = [
            IAdapterRescue(address(dragon)),
            IAdapterRescue(address(moe)),
            IAdapterRescue(address(joe)),
            IAdapterRescue(address(ube))
        ];
        names = ["dragon", "moe", "joe", "ube"];
    }

    receive() external payable {}

    // ─── Ownership ────────────────────────────────────────────────────────

    /// The constructor signature is unchanged (still just the router address):
    /// OZ 4.9's Ownable takes no constructor argument and makes the DEPLOYER
    /// the owner. Pinning that here because the deploy scripts depend on it.
    function test_DeployerIsOwnerAndConstructorTakesOnlyTheRouter() public {
        for (uint256 i = 0; i < 4; i++) {
            assertEq(adapters[i].owner(), address(this), names[i]);
        }
    }

    // ─── The net works ────────────────────────────────────────────────────

    function test_SweepMovesStrandedTokensToTheRecipient() public {
        PlainToken stray = new PlainToken("STRAY");

        for (uint256 i = 0; i < 4; i++) {
            address a = address(adapters[i]);
            uint256 stranded = 777e18 + i;
            stray.transfer(a, stranded);
            assertEq(stray.balanceOf(a), stranded, names[i]);

            uint256 before = stray.balanceOf(recipient);
            adapters[i].sweep(address(stray), recipient);

            assertEq(stray.balanceOf(recipient) - before, stranded, names[i]);
            assertEq(stray.balanceOf(a), 0, names[i]);
        }
    }

    function test_SweepNativeMovesStrandedNativeToTheRecipient() public {
        for (uint256 i = 0; i < 4; i++) {
            address a = address(adapters[i]);
            uint256 stranded = 3 ether + i;

            vm.deal(address(this), stranded);
            (bool sent, ) = a.call{value: stranded}("");
            assertTrue(sent, "receive() refused the native transfer");
            assertEq(a.balance, stranded, names[i]);

            uint256 before = recipient.balance;
            adapters[i].sweepNative(recipient);

            assertEq(recipient.balance - before, stranded, names[i]);
            assertEq(a.balance, 0, names[i]);
        }
    }

    function test_SweepRevertsOnZeroBalanceAndZeroAddress() public {
        PlainToken stray = new PlainToken("STRAY");
        for (uint256 i = 0; i < 4; i++) {
            vm.expectRevert(DragonSwapSeiAdapter.ZeroAmount.selector);
            adapters[i].sweep(address(stray), recipient);

            vm.expectRevert(DragonSwapSeiAdapter.ZeroAmount.selector);
            adapters[i].sweepNative(recipient);

            vm.expectRevert(DragonSwapSeiAdapter.ZeroAddress.selector);
            adapters[i].sweep(address(stray), address(0));

            vm.expectRevert(DragonSwapSeiAdapter.ZeroAddress.selector);
            adapters[i].sweepNative(address(0));
        }
    }

    // ─── Only the owner ───────────────────────────────────────────────────

    function test_StrangerCannotSweepAndTheFundsStay() public {
        PlainToken stray = new PlainToken("STRAY");

        for (uint256 i = 0; i < 4; i++) {
            address a = address(adapters[i]);
            stray.transfer(a, 100e18);
            vm.deal(a, 5 ether);

            vm.prank(stranger);
            vm.expectRevert("Ownable: caller is not the owner");
            adapters[i].sweep(address(stray), stranger);

            vm.prank(stranger);
            vm.expectRevert("Ownable: caller is not the owner");
            adapters[i].sweepNative(stranger);

            // The point is not that it reverted — it is that nothing moved.
            assertEq(stray.balanceOf(stranger), 0, names[i]);
            assertEq(stranger.balance, 0, names[i]);
            assertEq(stray.balanceOf(a), 100e18, names[i]);
            assertEq(a.balance, 5 ether, names[i]);
        }
    }

    /// Ownable2Step: handing ownership over is a proposal until it is accepted,
    /// so a typo'd address never gains the ability to drain the net.
    function test_PendingOwnerCannotSweepUntilAcceptance() public {
        PlainToken stray = new PlainToken("STRAY");

        for (uint256 i = 0; i < 4; i++) {
            address a = address(adapters[i]);
            // A fresh candidate per adapter, so each assertion below reads an
            // account that started empty.
            address newOwner = makeAddr(string.concat("newOwner-", names[i]));
            stray.transfer(a, 50e18);

            adapters[i].transferOwnership(newOwner);
            assertEq(adapters[i].pendingOwner(), newOwner, names[i]);
            assertEq(adapters[i].owner(), address(this), names[i]);

            vm.prank(newOwner);
            vm.expectRevert("Ownable: caller is not the owner");
            adapters[i].sweep(address(stray), newOwner);
            assertEq(stray.balanceOf(newOwner), 0, names[i]);

            vm.prank(newOwner);
            adapters[i].acceptOwnership();

            vm.prank(newOwner);
            adapters[i].sweep(address(stray), newOwner);
            assertEq(stray.balanceOf(newOwner), 50e18, names[i]);
            assertEq(stray.balanceOf(a), 0, names[i]);

            // And the previous owner is now powerless.
            stray.transfer(a, 1e18);
            vm.expectRevert("Ownable: caller is not the owner");
            adapters[i].sweep(address(stray), address(this));
            assertEq(stray.balanceOf(a), 1e18, names[i]);
        }
    }

    // ─── The net cannot become a hook into a live operation ───────────────

    /// A hostile OWNER re-enters `sweep` from a token callback while the
    /// adapter is holding the other leg of a user's `addLiquidity`. The
    /// operation is allowed to complete; what matters is the destination of
    /// the victim's tokens at the end.
    /// @dev Mutation-checked: dropping `nonReentrant` from
    ///      `DragonSwapSeiAdapter.sweep` makes this test fail with
    ///      "ERC20: transfer amount exceeds balance" — the sweep succeeds
    ///      mid-flight, the victim's tokens are gone, and the router's own pull
    ///      then finds an empty adapter. The guard is what this test is
    ///      measuring, and it dies when the guard dies.
    function test_OwnerCannotSweepTokensOfAnOperationInFlight() public {
        for (uint256 i = 0; i < 4; i++) {
            address a = address(adapters[i]);

            PlainToken victim = new PlainToken("VICTIM");
            ReentrantSweepToken evil = new ReentrantSweepToken();

            // Owner of the adapter IS the attacking token.
            evil.arm(a, address(victim), attacker, 0);
            adapters[i].transferOwnership(address(evil));
            evil.acceptAdapterOwnership();
            assertEq(adapters[i].owner(), address(evil), names[i]);

            uint256 amount = 1_000e18;
            victim.approve(a, type(uint256).max);
            evil.approve(a, type(uint256).max);

            uint256 routerVictimBefore = victim.balanceOf(address(router));

            adapters[i].addLiquidity(
                address(victim), address(evil),
                amount, amount, 0, 0,
                user, block.timestamp + 1
            );

            assertTrue(evil.sweepAttempted(), "the callback never fired: test proves nothing");
            assertTrue(evil.sweepReverted(), "the owner swept a live operation");
            assertEq(
                keccak256(evil.sweepRevertData()),
                REENTRANCY_REVERT,
                "sweep failed for some reason other than the reentrancy guard"
            );

            // Where the money actually went.
            assertEq(victim.balanceOf(attacker), 0, names[i]);
            assertEq(victim.balanceOf(address(router)) - routerVictimBefore, amount, names[i]);
            assertEq(victim.balanceOf(a), 0, names[i]);
        }
    }

    /// Same attack against the native leg: the adapter is holding the caller's
    /// `msg.value` AND an older stranded donation. The sweep must not be able
    /// to take the former; the latter must still be there for a legitimate
    /// rescue once the operation is over.
    function test_OwnerCannotSweepNativeOfAnOperationInFlight() public {
        // Ubeswap is excluded: its native leg is the CELO precompile
        // (0x471EcE…), whose ERC20-ledger/native duality cannot be reproduced
        // on a generic EVM without etching a stand-in at that fixed address.
        // Its ERC20 path is covered by the test above.
        IAdapterRescue[3] memory nativeAdapters = [
            IAdapterRescue(address(dragon)),
            IAdapterRescue(address(moe)),
            IAdapterRescue(address(joe))
        ];

        uint256 donation  = 3 ether;
        uint256 sent      = 4 ether;
        uint256 nativeUse = 1 ether;
        router.setNativeCap(nativeUse);

        for (uint256 i = 0; i < 3; i++) {
            address a = address(nativeAdapters[i]);

            ReentrantSweepToken evil = new ReentrantSweepToken();
            evil.arm(a, address(0), attacker, 1);
            nativeAdapters[i].transferOwnership(address(evil));
            evil.acceptAdapterOwnership();
            assertEq(nativeAdapters[i].owner(), address(evil), names[i]);

            // Value stranded before the operation — the legitimate target of a
            // rescue, and the bait for the mid-flight one.
            vm.deal(address(this), sent + donation);
            (bool ok, ) = a.call{value: donation}("");
            assertTrue(ok);

            evil.approve(a, type(uint256).max);
            uint256 selfBefore = address(this).balance;

            nativeAdapters[i].addLiquidityETH{value: sent}(
                address(evil), 500e18, 0, 0, user, block.timestamp + 1
            );

            assertTrue(evil.sweepAttempted(), "the callback never fired: test proves nothing");
            assertTrue(evil.sweepReverted(), "the owner swept native from a live operation");
            assertEq(
                keccak256(evil.sweepRevertData()),
                REENTRANCY_REVERT,
                "sweepNative failed for some reason other than the reentrancy guard"
            );

            // The attacker got nothing, the caller got the unused value back,
            // and the pre-existing donation is untouched.
            assertEq(attacker.balance, 0, names[i]);
            assertEq(selfBefore - address(this).balance, nativeUse, names[i]);
            assertEq(a.balance, donation, names[i]);

            // Outside the operation the net still works, on the donation only.
            vm.prank(address(evil));
            nativeAdapters[i].sweepNative(recipient);
            assertEq(a.balance, 0, names[i]);
        }

        assertEq(recipient.balance, donation * 3, "rescued exactly the stranded native, three times");
    }
}
