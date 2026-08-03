// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/curve/MagnetaCurvePool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*//////////////////////////////////////////////////////////////////////////
                    A FAITHFUL UniswapV2 STAND-IN

    These tests are about what the ROUTER actually deposits, so a mock that
    "just takes whatever you send" would prove nothing. MiniRouter reproduces
    UniswapV2Router02._addLiquidity byte for byte — the quote(), the
    INSUFFICIENT_B_AMOUNT / INSUFFICIENT_A_AMOUNT floors, the ETH refund —
    and MiniPair reproduces the reserve/sync/mint behaviour a griefer plays
    with. The repo's real V2 sources are solc 0.5.16/0.6.6 and are excluded
    from the Foundry build (foundry.toml `skip`), hence the 0.8.20 port.
//////////////////////////////////////////////////////////////////////////*/

contract MiniWETH is ERC20 {
    constructor() ERC20("Wrapped Native", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }
    receive() external payable { _mint(msg.sender, msg.value); }
}

contract MiniPair is ERC20 {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    /// @dev OZ's ERC20 refuses _mint(address(0)); park the locked minimum here.
    address constant LOCK = 0x000000000000000000000000000000000000dEaD;

    constructor(address a, address b) ERC20("Mini LP", "MLP") {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = bal0 - reserve0;
        uint256 amount1 = bal1 - reserve1;
        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(LOCK, MINIMUM_LIQUIDITY);
        } else {
            uint256 l0 = (amount0 * supply) / reserve0;
            uint256 l1 = (amount1 * supply) / reserve1;
            liquidity = l0 < l1 ? l0 : l1;
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        reserve0 = uint112(bal0);
        reserve1 = uint112(bal1);
    }

    /// @notice The griefer's tool: donate dust, sync, and the pair now quotes
    ///         whatever ratio you like.
    function sync() external {
        reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) { z = 1; }
    }
}

contract MiniFactory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address a, address b) public returns (address pair) {
        require(getPair[a][b] == address(0), "PAIR_EXISTS");
        pair = address(new MiniPair(a, b));
        getPair[a][b] = pair;
        getPair[b][a] = pair;
    }
}

contract MiniRouter {
    address public immutable factoryAddr;
    address public immutable wethAddr;

    /// @notice Last slippage floors the pool asked for. The whole CRITICAL was
    ///         that these could be zero; tests read them directly.
    uint256 public lastAmountTokenMin;
    uint256 public lastAmountETHMin;
    bool    public floorsSeen;

    constructor(address _factory, address _weth) {
        factoryAddr = _factory;
        wethAddr = _weth;
    }

    function factory() external view returns (address) { return factoryAddr; }
    function WETH() external view returns (address) { return wethAddr; }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        public pure returns (uint256)
    {
        require(amountA > 0, "INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "INSUFFICIENT_LIQUIDITY");
        return (amountA * reserveB) / reserveA;
    }

    function _reserves(address tokenA, address tokenB)
        internal view returns (uint256 reserveA, uint256 reserveB)
    {
        address pair = MiniFactory(factoryAddr).getPair(tokenA, tokenB);
        if (pair == address(0)) return (0, 0);
        (uint112 r0, uint112 r1, ) = MiniPair(pair).getReserves();
        (reserveA, reserveB) = tokenA < tokenB ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev Verbatim UniswapV2Router02._addLiquidity.
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        if (MiniFactory(factoryAddr).getPair(tokenA, tokenB) == address(0)) {
            MiniFactory(factoryAddr).createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB) = _reserves(tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "INSUFFICIENT_B_AMOUNT");
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, "INSUFFICIENT_A_AMOUNT");
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function addLiquidityETH(
        address tokenA,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 /*deadline*/
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        lastAmountTokenMin = amountTokenMin;
        lastAmountETHMin = amountETHMin;
        floorsSeen = true;

        (amountToken, amountETH) = _addLiquidity(
            tokenA, wethAddr, amountTokenDesired, msg.value, amountTokenMin, amountETHMin
        );
        address pair = MiniFactory(factoryAddr).getPair(tokenA, wethAddr);
        require(IERC20(tokenA).transferFrom(msg.sender, pair, amountToken), "TRANSFER_FROM_FAILED");
        MiniWETH(payable(wethAddr)).deposit{value: amountETH}();
        require(IERC20(wethAddr).transfer(pair, amountETH), "TRANSFER_FAILED");
        liquidity = MiniPair(pair).mint(to);
        if (msg.value > amountETH) {
            (bool ok, ) = payable(msg.sender).call{value: msg.value - amountETH}("");
            require(ok, "ETH_REFUND_FAILED");
        }
    }
}

contract LaunchToken is ERC20 {
    constructor(uint256 supply) ERC20("Launch", "LNCH") { _mint(msg.sender, supply); }
}

contract Vault { receive() external payable {} }

/*//////////////////////////////////////////////////////////////////////////
                                THE TESTS
//////////////////////////////////////////////////////////////////////////*/

/// @notice Balance-level proof of the graduation CRITICAL and its fix.
///
///         The defect: past GRADUATION_RESCUE_DELAY, finalizeGraduation set
///         amountTokenMin = amountETHMin = 0 and deposited into whatever pair
///         a griefer had seeded. Whoever owned that pair took the raise (or,
///         when the pair's ratio made the token side scarce, the leftover
///         sweep sent the raise to the feeVault). Worse, the honest branch was
///         unreachable: the band was measured against the curve terminal price
///         while the floors came from the pool's desired amounts — two
///         different ratios — so a pair sitting perfectly inside the band still
///         reverted on INSUFFICIENT_B_AMOUNT, leaving the forced branch as the
///         only outcome for any seeded pair.
///
///         Every assertion below is on a BALANCE or on the floors the router
///         actually received, never on an event alone.
contract CurveGraduationFixTest is Test {
    MagnetaCurvePool pool;
    LaunchToken token;
    MiniWETH weth;
    MiniFactory factory;
    MiniRouter router;
    Vault feeVault;

    address buyer    = makeAddr("buyer");
    address buyer2   = makeAddr("buyer2");
    address attacker = makeAddr("attacker");
    address keeper   = makeAddr("keeper");

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 constant ALLOCATION   =   800_000_000e18;
    uint256 constant TOKEN_FOR_LP = TOTAL_SUPPLY - ALLOCATION;
    uint256 constant V_NATIVE     = 10 ether;
    uint256 constant THRESHOLD    = 100 ether;

    function setUp() public {
        token   = new LaunchToken(TOTAL_SUPPLY);
        weth    = new MiniWETH();
        factory = new MiniFactory();
        router  = new MiniRouter(address(factory), address(weth));
        feeVault = new Vault();

        pool = new MagnetaCurvePool(
            address(token), address(router), address(feeVault),
            TOTAL_SUPPLY, ALLOCATION, V_NATIVE, THRESHOLD
        );
        // The factory hands the pool the FULL supply (curve allocation + the
        // slice reserved for the graduation LP).
        token.transfer(address(pool), TOTAL_SUPPLY);
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _buy(address who, uint256 value) internal returns (uint256 out) {
        vm.deal(who, who.balance + value);
        vm.prank(who);
        out = pool.buy{value: value}(0);
    }

    /// @dev Close the curve with a single buy well past the threshold.
    function _graduate() internal returns (uint256 tokensBought) {
        tokensBought = _buy(buyer, 150 ether);
        assertTrue(pool.graduated(), "curve did not close");
    }

    /// @dev Put the pair at `nativePerTokenNum / nativePerTokenDen`, using
    ///      `tokenAmount` tokens taken from `from`.
    function _seedPair(
        address from,
        uint256 tokenAmount,
        uint256 nativeAmount
    ) internal returns (MiniPair pair) {
        address pairAddr = factory.getPair(address(token), address(weth));
        if (pairAddr == address(0)) pairAddr = factory.createPair(address(token), address(weth));
        pair = MiniPair(pairAddr);

        vm.prank(from);
        token.transfer(pairAddr, tokenAmount);

        vm.deal(address(this), address(this).balance + nativeAmount);
        weth.deposit{value: nativeAmount}();
        weth.transfer(pairAddr, nativeAmount);

        pair.sync();
    }

    /// @dev The launch ratio the pool must always deposit at: nativeRaised per
    ///      (totalSupply − curveAllocation). This is exactly the price an EMPTY
    ///      pair gets, so it is the only price a seeded pair may impose.
    function _seedAtLaunchRatio(address from, uint256 tokenAmount) internal returns (MiniPair) {
        uint256 nativeAmount = (tokenAmount * pool.nativeRaised()) / TOKEN_FOR_LP;
        return _seedPair(from, tokenAmount, nativeAmount);
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                    1. THE HONEST PATH IS REACHABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice The case that USED to be impossible. A pair seeded at the launch
    ///         ratio — squarely inside GRADUATION_TOLERANCE_BPS — now finalises,
    ///         the LP is burned, and the raise lands in the pair rather than in
    ///         the feeVault.
    function test_HonestPath_SeededPairWithinBand_Finalizes() public {
        _graduate();
        uint256 raise = pool.nativeRaised();

        // Buyer parks 1% of his tokens in the pair at the exact launch ratio.
        uint256 seedTokens = token.balanceOf(buyer) / 100;
        MiniPair pair = _seedAtLaunchRatio(buyer, seedTokens);
        (uint112 sr0, uint112 sr1, ) = pair.getReserves();
        assertTrue(sr0 > 0 && sr1 > 0, "pair not seeded");

        uint256 vaultBefore = address(feeVault).balance;

        vm.prank(keeper);
        pool.finalizeGraduation();

        assertTrue(pool.graduationFinalized(), "not finalized");

        // The LP minted to the pool was burned at DEAD — liquidity locked.
        assertGt(pair.balanceOf(DEAD), pair.MINIMUM_LIQUIDITY(), "graduation LP not burned");
        assertEq(pair.balanceOf(address(pool)), 0, "pool kept LP");

        // The raise is IN THE PAIR, not in the vault. Leftover swept to the
        // vault is bounded by the tolerance band.
        uint256 pairWeth = weth.balanceOf(address(pair));
        assertGe(pairWeth, (raise * 98) / 100, "raise did not reach the pool");
        uint256 swept = address(feeVault).balance - vaultBefore;
        assertLe(swept, (raise * 2) / 100, "feeVault swallowed more than band dust");

        // And the floors were real.
        assertGt(router.lastAmountETHMin(), 0, "ETH floor was zero");
        assertGt(router.lastAmountTokenMin(), 0, "token floor was zero");
    }

    /// @notice Same guarantee on the untouched path: an empty pair still gets
    ///         the launch ratio with non-zero floors.
    function test_EmptyPair_StillDepositsWithRealFloors() public {
        _graduate();
        uint256 raise = pool.nativeRaised();

        vm.prank(keeper);
        pool.finalizeGraduation();

        assertGe(router.lastAmountETHMin(), (raise * 97) / 100, "ETH floor too loose");
        assertGe(router.lastAmountTokenMin(), (TOKEN_FOR_LP * 97) / 100, "token floor too loose");

        MiniPair pair = MiniPair(factory.getPair(address(token), address(weth)));
        assertEq(weth.balanceOf(address(pair)), raise, "empty-pair deposit lost native");
        assertEq(token.balanceOf(address(pair)), TOKEN_FOR_LP, "empty-pair deposit lost tokens");
        assertGt(pair.balanceOf(DEAD), 0, "LP not burned");
    }

    /*//////////////////////////////////////////////////////////////
        2. THE GRIEFED PAIR NEVER GETS THE RAISE — AT ANY TIME
    //////////////////////////////////////////////////////////////*/

    /// @notice The attack from the old "H-1" test, asserted on BALANCES.
    ///         Attacker seeds a dust pair off-ratio, waits out the rescue
    ///         delay, and calls finalizeGraduation. It must revert forever —
    ///         there is no forced branch left — so he can never redeem LP
    ///         against the raise.
    function test_GriefedPair_ForcedDepositIsGone_AttackerGainsNothing() public {
        // Attacker buys a sliver so he has tokens to seed with.
        _buy(attacker, 1 ether);
        _graduate();

        // Off-ratio by ~3 orders of magnitude: all his tokens against 0.001 ETH.
        MiniPair pair = _seedPair(attacker, token.balanceOf(attacker), 0.001 ether);

        uint256 attackerEthBefore = attacker.balance;
        uint256 vaultBefore = address(feeVault).balance;
        uint256 poolBefore = address(pool).balance;

        // Inside the window: refused, as before.
        vm.prank(attacker);
        vm.expectPartialRevert(MagnetaCurvePool.PairRatioOutOfBand.selector);
        pool.finalizeGraduation();

        // Past the window: STILL refused. This is the fix — the old code
        // deposited here with amountTokenMin = amountETHMin = 0.
        vm.warp(block.timestamp + pool.GRADUATION_RESCUE_DELAY() + 1);
        vm.prank(attacker);
        vm.expectPartialRevert(MagnetaCurvePool.PairRatioOutOfBand.selector);
        pool.finalizeGraduation();

        // The router was never even reached, so no floors were ever quoted.
        assertFalse(router.floorsSeen(), "router was called on an out-of-band pair");

        assertFalse(pool.graduationFinalized(), "graduation must stay open");
        assertEq(attacker.balance, attackerEthBefore, "attacker extracted native");
        assertEq(address(feeVault).balance, vaultBefore, "raise leaked to the feeVault");
        assertEq(address(pool).balance, poolBefore, "raise left the pool");
        assertEq(weth.balanceOf(address(pair)), 0.001 ether, "raise reached the griefed pair");
    }

    /*//////////////////////////////////////////////////////////////
                    3. REFUND MODE GIVES THE MONEY BACK
    //////////////////////////////////////////////////////////////*/

    function _griefAndEnterRefund() internal returns (MiniPair pair) {
        _buy(attacker, 1 ether);
        _graduate();
        pair = _seedPair(attacker, token.balanceOf(attacker), 0.001 ether);
        vm.warp(block.timestamp + pool.GRADUATION_RESCUE_DELAY() + 1);
        vm.prank(keeper);
        pool.enterRefundMode();
    }

    /// @notice Buyers get their money back at the curve terminal price; the
    ///         feeVault gets nothing beyond the trading fees it already took,
    ///         and the griefer ends up down.
    ///
    ///         The griefer here takes only a token position (0.01 ETH) so the
    ///         pot is effectively all the buyer's; the pro-rata split with a
    ///         real co-investor is covered by
    ///         test_RefundMode_IsSolventForEveryHolder.
    function test_RefundMode_BuyersRecoverTheirStake() public {
        uint256 buyerSpend = 150 ether;

        _buy(attacker, 0.01 ether);
        uint256 attackerTokens = token.balanceOf(attacker);
        _graduate();

        uint256 raise = pool.nativeRaised();
        uint256 sold  = pool.tokensSold();
        uint256 vaultBefore = address(feeVault).balance;

        MiniPair pair = _seedPair(attacker, attackerTokens, 0.001 ether);
        pair; // reserves only matter for the out-of-band check

        vm.warp(block.timestamp + pool.GRADUATION_RESCUE_DELAY() + 1);
        vm.prank(keeper);
        pool.enterRefundMode();

        assertTrue(pool.refundMode(), "refund mode not set");
        assertEq(pool.refundNativePot(), raise, "pot != raise");
        assertEq(pool.refundTokenPot(), sold, "denominator != tokens outstanding");
        // Graduation is closed for good.
        vm.expectRevert(MagnetaCurvePool.AlreadyFinalized.selector);
        pool.finalizeGraduation();

        // The buyer redeems everything he still holds.
        uint256 buyerTokens = token.balanceOf(buyer);
        vm.startPrank(buyer);
        token.approve(address(pool), buyerTokens);
        uint256 refund = pool.claimRefund(buyerTokens);
        vm.stopPrank();

        // He paid 150 ETH, of which 1% went to the fee vault at buy time and a
        // sliver is the griefer's pro-rata share. Getting >98% back is the
        // property: the money came back to him, not to the griefer.
        assertGt(refund, (buyerSpend * 98) / 100, "buyer did not recover his stake");
        assertEq(buyer.balance, refund, "refund not delivered");
        assertEq(token.balanceOf(buyer), 0, "tokens not burned on claim");
        assertGe(token.balanceOf(DEAD), buyerTokens, "claimed tokens not sent to DEAD");

        // The feeVault took no part of the raise in the process.
        assertEq(address(feeVault).balance, vaultBefore, "feeVault took the raise");

        // No LP anywhere: refund mode creates none.
        address pairAddr = factory.getPair(address(token), address(weth));
        assertEq(weth.balanceOf(pairAddr), 0.001 ether, "liquidity was migrated anyway");

        // The griefer is down his seed and up nothing: his tokens are in the
        // pair he donated to, and he never received native from the pool.
        assertEq(attacker.balance, 0, "attacker extracted native");
    }

    /// @notice Two holders, both redeem: the pot covers them and the pool stays
    ///         solvent throughout (no last-claimer left short).
    function test_RefundMode_IsSolventForEveryHolder() public {
        _buy(buyer, 40 ether);
        _buy(buyer2, 40 ether);
        assertFalse(pool.graduated(), "closed before the threshold");
        _buy(buyer, 40 ether);
        assertTrue(pool.graduated(), "curve did not close");

        _seedPair(buyer2, token.balanceOf(buyer2) / 10, 0.001 ether);

        vm.warp(block.timestamp + pool.GRADUATION_RESCUE_DELAY() + 1);
        pool.enterRefundMode();

        uint256 pot = pool.refundNativePot();

        uint256 b1 = token.balanceOf(buyer);
        vm.startPrank(buyer);
        token.approve(address(pool), b1);
        uint256 r1 = pool.claimRefund(b1);
        vm.stopPrank();

        uint256 b2 = token.balanceOf(buyer2);
        vm.startPrank(buyer2);
        token.approve(address(pool), b2);
        uint256 r2 = pool.claimRefund(b2);
        vm.stopPrank();

        assertLe(r1 + r2, pot, "refunds exceeded the pot");
        // The pool paid every claim out of its own balance and is still solvent
        // for what it has not yet been asked to pay.
        assertEq(address(pool).balance, pot - r1 - r2, "pool accounting drifted");
        // Everything outstanding except the tokens parked in the pair has been
        // paid out, so the pot is nearly drained.
        assertGe(r1 + r2, (pot * 89) / 100, "holders were shortchanged");
    }

    /// @notice The economic answer to "does a permissionless refund create a
    ///         lever?". It does not, because refunds pay the curve TERMINAL
    ///         price while a completed launch prices the same tokens at the
    ///         LAUNCH ratio — nativeRaised over the LP token slice, several
    ///         times higher. Forcing refund mode therefore hands the griefer
    ///         strictly less than letting the launch through, for every holder
    ///         including himself.
    function test_RefundMode_IsUnprofitableForTheGriefer() public {
        _buy(attacker, 1 ether);
        uint256 attackerTokens = token.balanceOf(attacker);
        _graduate();

        uint256 raise = pool.nativeRaised();
        // What his bag is worth at the price a completed launch would set.
        uint256 valueIfLaunchSucceeds = (attackerTokens * raise) / TOKEN_FOR_LP;
        // What refund mode would pay him.
        uint256 valueIfRefunded = (attackerTokens * raise) / pool.tokensSold();

        assertGt(
            valueIfLaunchSucceeds,
            valueIfRefunded * 3,
            "refund mode pays the griefer more than a successful launch would"
        );

        // And the payout is real, not hypothetical: he can only ever collect
        // the smaller number.
        _seedPair(attacker, attackerTokens, 0.001 ether);
        vm.warp(block.timestamp + pool.GRADUATION_RESCUE_DELAY() + 1);
        pool.enterRefundMode();
        // His tokens are in the pair he donated to; he holds nothing to claim.
        assertEq(token.balanceOf(attacker), 0, "griefer kept a claimable bag");
        vm.prank(attacker);
        vm.expectRevert(MagnetaCurvePool.InvalidAmount.selector);
        pool.claimRefund(0);
    }

    /// @notice Refund mode is one-way and cannot be re-entered or undone.
    function test_RefundMode_IsIrreversible() public {
        _griefAndEnterRefund();

        vm.expectRevert(MagnetaCurvePool.AlreadyFinalized.selector);
        pool.enterRefundMode();

        vm.expectRevert(MagnetaCurvePool.AlreadyFinalized.selector);
        pool.finalizeGraduation();

        // Trading stays closed too.
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(MagnetaCurvePool.AlreadyGraduated.selector);
        pool.buy{value: 1 ether}(0);
    }

    /*//////////////////////////////////////////////////////////////
        4. REFUND MODE IS NOT ITSELF A WEAPON
    //////////////////////////////////////////////////////////////*/

    /// @notice The obvious abuse of a permissionless liquidation: seed the pair
    ///         off-ratio, wait, then tear down a healthy launch. It is refused
    ///         while migration is possible — before the delay, on an empty
    ///         pair, and on an in-band pair.
    function test_RefundMode_RefusedWhileGraduationIsViable() public {
        _graduate();

        // Before the delay.
        vm.expectRevert(MagnetaCurvePool.RescueDelayNotElapsed.selector);
        pool.enterRefundMode();

        vm.warp(block.timestamp + pool.GRADUATION_RESCUE_DELAY() + 1);

        // Empty pair: finalizeGraduation would go through right now.
        vm.prank(attacker);
        vm.expectRevert(MagnetaCurvePool.GraduationStillViable.selector);
        pool.enterRefundMode();

        // Seeded, but at the launch ratio: still viable, still refused.
        _seedAtLaunchRatio(buyer, token.balanceOf(buyer) / 100);
        vm.prank(attacker);
        vm.expectRevert(MagnetaCurvePool.GraduationStillViable.selector);
        pool.enterRefundMode();

        // And the launch does complete.
        pool.finalizeGraduation();
        assertTrue(pool.graduationFinalized(), "viable launch failed to finalize");
    }

    /// @notice The counter to the griefer: a V2 pair's ratio can be pushed back
    ///         to the launch ratio by donating the scarce side and calling
    ///         sync(), which on a dust pair costs dust. Anyone who wants the
    ///         launch to live repairs the pair and finalises — and that closes
    ///         the door on refund mode.
    function test_AnyoneCanRepairAGriefedPairAndFinalize() public {
        _buy(attacker, 1 ether);
        _graduate();
        // A cheap grief: 1000 tokens against 1 wei — wildly off ratio, and it
        // costs the griefer next to nothing. It costs a supporter next to
        // nothing to undo, which is the point.
        MiniPair pair = _seedPair(attacker, 1000e18, 1);
        vm.warp(block.timestamp + pool.GRADUATION_RESCUE_DELAY() + 1);

        // Refund is available right now...
        uint256 snap = vm.snapshotState();
        pool.enterRefundMode();
        assertTrue(pool.refundMode(), "refund unavailable on a griefed pair");
        vm.revertToState(snap);

        // ...unless a supporter donates the missing native side and syncs.
        uint256 pairTokens = token.balanceOf(address(pair));
        uint256 targetNative = (pairTokens * pool.nativeRaised()) / TOKEN_FOR_LP;
        uint256 topUp = targetNative - weth.balanceOf(address(pair));
        assertLt(topUp, 1 ether, "repair cost is not dust on a dust pair");

        vm.deal(address(this), topUp);
        weth.deposit{value: topUp}();
        weth.transfer(address(pair), topUp);
        pair.sync();

        // Refund is now off the table and migration works.
        vm.expectRevert(MagnetaCurvePool.GraduationStillViable.selector);
        pool.enterRefundMode();

        pool.finalizeGraduation();
        assertTrue(pool.graduationFinalized(), "repaired pair did not finalize");
        assertGt(pair.balanceOf(DEAD), pair.MINIMUM_LIQUIDITY(), "LP not burned");
    }

    /*//////////////////////////////////////////////////////////////
                5. THE GRADUATION GATE COUNTS REAL MONEY
    //////////////////////////////////////////////////////////////*/

    /// @notice A buy/sell round-trip used to credit the gate with the full buy
    ///         leg every time, while only the ~2% round-trip fee stayed behind.
    ///         The gate is now the high-water mark of nativeRaised, so a
    ///         round-trip adds nothing.
    function test_Gate_RoundTripDoesNotInflateTheBarrier() public {
        uint256 out = _buy(buyer, 10 ether);
        uint256 peakAfterBuy = pool.peakNativeRaised();
        assertEq(peakAfterBuy, pool.nativeRaised(), "gate != raise after a single buy");

        // Round-trip: sell it straight back. (99%, not 100%: quoteSell rounds
        // the payout up by a wei-scale dust, so a full unwind trips the pool's
        // own "insufficient curve native" solvency guard.)
        vm.startPrank(buyer);
        token.approve(address(pool), out);
        pool.sell((out * 99) / 100, 0);
        vm.stopPrank();

        assertLt(pool.nativeRaised(), peakAfterBuy, "sell did not lower the raise");
        assertEq(pool.peakNativeRaised(), peakAfterBuy, "gate moved on a sell");

        // Nine more round-trips: 100 ETH of buy legs in total, exactly the
        // threshold. The old cumulative gate would have closed the curve here
        // on a pool holding ~1 ETH; the high-water mark does not.
        for (uint256 i = 0; i < 9; ++i) {
            uint256 o = _buy(buyer, 10 ether);
            vm.startPrank(buyer);
            token.approve(address(pool), o);
            pool.sell((o * 99) / 100, 0);
            vm.stopPrank();
        }

        assertFalse(pool.graduated(), "round-trips closed the curve on money the pool never held");
        assertLt(pool.peakNativeRaised(), THRESHOLD, "gate credited more than the pool ever held");
        // The gate stays near the single largest amount the pool ever held
        // (~9.9 ETH plus the ~1% of each trip the seller left behind).
        assertLe(pool.peakNativeRaised(), 20 ether, "gate drifted above the true high-water mark");
    }

    /// @notice The F84 property the old cumulative gate existed for is kept: a
    ///         whale cannot sell to walk the gate back below the threshold.
    function test_Gate_StaysMonotonicUnderSelling() public {
        uint256 out = _buy(buyer, 95 ether);
        uint256 peak = pool.peakNativeRaised();
        assertFalse(pool.graduated(), "closed too early");

        vm.startPrank(buyer);
        token.approve(address(pool), out);
        pool.sell((out * 80) / 100, 0);
        vm.stopPrank();

        assertLt(pool.nativeRaised(), peak, "raise did not fall");
        assertEq(pool.peakNativeRaised(), peak, "gate fell with the raise");

        // Topping the high-water mark past the threshold closes the curve. It
        // now takes REAL money to do so: the dump gave most of the raise back,
        // so the gate only moves once the pool genuinely holds 100 ETH again.
        _buy(attacker, 120 ether);
        assertGe(pool.peakNativeRaised(), THRESHOLD, "gate did not reach the threshold");
        assertTrue(pool.graduated(), "curve did not close on a genuine high-water mark");
    }

    /// @notice graduate() reads the same gate and refuses below it.
    function test_Graduate_RefusesBelowTheGate() public {
        _buy(buyer, 10 ether);
        vm.expectRevert(MagnetaCurvePool.BelowThreshold.selector);
        pool.graduate();
    }

    /*//////////////////////////////////////////////////////////////
                        6. NO FLOOR IS EVER ZERO
    //////////////////////////////////////////////////////////////*/

    /// @notice Exhaustive over the two surviving deposit paths: the router is
    ///         never handed a zero slippage floor. This is the invariant the
    ///         CRITICAL violated.
    function test_FloorsAreNeverZero_OnEitherPath() public {
        // Empty-pair path.
        _graduate();
        pool.finalizeGraduation();
        assertTrue(router.floorsSeen(), "router never called");
        assertGt(router.lastAmountETHMin(), 0, "empty-pair ETH floor was zero");
        assertGt(router.lastAmountTokenMin(), 0, "empty-pair token floor was zero");

        // Seeded in-band path, on a fresh fixture.
        setUp();
        _graduate();
        _seedAtLaunchRatio(buyer, token.balanceOf(buyer) / 100);
        pool.finalizeGraduation();
        assertGt(router.lastAmountETHMin(), 0, "seeded ETH floor was zero");
        assertGt(router.lastAmountTokenMin(), 0, "seeded token floor was zero");
    }

    /// @notice The floors are tight against what the router will really take,
    ///         not against the pool's desired amounts. With a pair seeded at
    ///         the launch ratio the two coincide to within the band; the point
    ///         is that the ETH floor is derived from the PAIR, so it no longer
    ///         over-shoots and blows up on INSUFFICIENT_B_AMOUNT.
    function test_Floors_TrackWhatTheRouterActuallyTakes() public {
        _graduate();
        uint256 raise = pool.nativeRaised();
        MiniPair pair = _seedAtLaunchRatio(buyer, token.balanceOf(buyer) / 100);

        (uint112 r0, uint112 r1, ) = pair.getReserves();
        (uint256 reserveNative, uint256 reserveToken) = address(token) < address(weth)
            ? (uint256(r1), uint256(r0))
            : (uint256(r0), uint256(r1));
        uint256 nativeOptimal = (TOKEN_FOR_LP * reserveNative) / reserveToken;

        pool.finalizeGraduation();

        uint256 expectedEthFloor = nativeOptimal <= raise ? nativeOptimal : raise;
        assertGe(router.lastAmountETHMin(), (expectedEthFloor * 97) / 100, "floor far below the deposit");
        assertLe(router.lastAmountETHMin(), expectedEthFloor, "floor above what the router takes");
    }
}
