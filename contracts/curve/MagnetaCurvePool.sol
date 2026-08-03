// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title MagnetaCurvePool
 * @notice Bonding-curve liquidity pool for a single token. Pump.fun-style
 *         constant-product virtual reserves: `k = (vNative + native) ×
 *         (vToken - tokensSold)`. Anyone can buy or sell at any time without
 *         prior LP — the curve mathematically guarantees execution.
 *
 *         Fee model:
 *           - 1% on every buy + sell, taken in native and forwarded to the
 *             Magneta FeeVault on the same tx (no admin claim needed).
 *           - LP fees on V2 pool ROUNDS (post-graduation) accrue to LP holders
 *             on the destination DEX, not back to this contract.
 *
 *         Graduation:
 *           - Triggered automatically inside `buy()` when `nativeRaised >=
 *             GRADUATION_THRESHOLD`. Permissionless: anyone can also call
 *             `graduate()` directly to push it through, but `buy()` covers
 *             the happy path.
 *           - On graduation: the pool sends its remaining native + a
 *             fixed allocation of token reserves to the configured V2 router,
 *             receives LP tokens back, then burns those LP at `dead`. This
 *             permanently locks liquidity on the destination DEX — no rug.
 *           - If a griefer keeps the destination V2 pair at a price the
 *             migration cannot honour, the pool never deposits blind: past a
 *             grace window it can be put into REFUND mode instead, where every
 *             holder burns their tokens for their share of the raise at the
 *             curve terminal price. No LP is created and no admin is involved.
 *
 *         Critically, the pool holds NO admin keys. Once deployed, fee bps,
 *         router address, and graduation parameters are immutable. Magneta's
 *         only mutable tie is the FeeVault destination, which is also
 *         immutable here for V1.
 */

interface IUniswapV2Router02 {
    function WETH() external view returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function factory() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IUniswapV2Pair {
    /// @notice Reserves of the pair at the latest sync. Read at graduation to
    ///         decide whether the V2 pair is empty (we set the launch price
    ///         ourselves) or pre-seeded (we must deposit at ITS ratio, so both
    ///         the band check and the slippage floors are derived from these
    ///         reserves). Never used to justify a zero floor.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract MagnetaCurvePool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants (set at deploy, immutable) ────────────────────────────

    /// @notice Total token supply minted to this pool at creation. The
    ///         constructor doesn't mint itself — `MagnetaCurveFactory`
    ///         deploys the token with `initialHolder = address(this)`.
    uint256 public immutable totalSupplyToken;

    /// @notice Tokens reserved on the curve. The remaining supply (=
    ///         totalSupplyToken - curveAllocation) is set aside for the
    ///         post-graduation V2 LP. Default split mirrors pump.fun:
    ///         80% on curve, 20% reserved for graduation LP.
    uint256 public immutable curveAllocation;

    /// @notice Virtual native reserve at deployment. Sets the starting
    ///         price = vNative / vToken. With pump.fun-equivalent values
    ///         (vNative = 1.6 ETH-equiv, vToken = 80% of supply) the
    ///         starting market cap is ~$5-10k for a 1B-token launch.
    uint256 public immutable virtualNativeReserve;

    /// @notice Virtual token reserve. Equal to `curveAllocation` at deploy.
    uint256 public immutable virtualTokenReserve;

    /// @notice Native (in wei) the pool must accumulate before graduation
    ///         fires. Default ~13 ETH-equivalent → roughly $40k market
    ///         cap on launch chain. Configurable per-launch.
    uint256 public immutable graduationThreshold;

    /// @notice Fee in basis points charged on each buy AND sell.
    uint256 public constant FEE_BPS = 100; // 1%

    /// @notice Tolerance band (in basis points) applied at graduation. Both
    ///         the addLiquidityETH slippage mins and the pre-seeded-pair ratio
    ///         check derive from the curve terminal price with this band (F82).
    ///         200 bps = 2%: tight enough that a manipulated launch price is
    ///         rejected, loose enough to absorb integer-division rounding on
    ///         the curve terminal ratio.
    uint256 public constant GRADUATION_TOLERANCE_BPS = 200; // 2%

    /// @notice Permanent burn destination for graduation LP tokens.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ─── Wired contracts ─────────────────────────────────────────────────

    IERC20 public immutable token;
    IUniswapV2Router02 public immutable router;
    address public immutable feeVault;
    address public immutable wnative;

    // ─── Mutable state ───────────────────────────────────────────────────

    /// @notice Native (in wei) raised on the curve so far, net of sells +
    ///         net of fees. Drives PRICING only — NOT graduation. Because
    ///         sell() decrements it, using it for the graduation gate let a
    ///         whale sell near the threshold to suppress graduation (F84).
    uint256 public nativeRaised;

    /// @notice HIGH-WATER MARK of `nativeRaised`: the largest amount the curve
    ///         has ever actually held at one instant. Monotonic by construction
    ///         (it only ever moves up, in buy()), which is what the F84
    ///         graduation gate needs — a whale cannot sell to walk the gate back
    ///         below the line.
    ///
    ///         It replaces the previous CUMULATIVE `totalNativeBought`, which
    ///         summed every buy and was never decremented by sell(). That sum
    ///         credited the gate for money the curve no longer held: a buy/sell
    ///         round-trip fed the gate its full buy leg again and again while
    ///         only ~2% (the round-trip fee) actually stayed. A curve could
    ///         therefore close at a fraction of its advertised raise (measured:
    ///         gate at 0.1188 ETH for 0.0198 ETH truly raised, i.e. the launch
    ///         shipped on 17% of the money it promised). A high-water mark
    ///         credits only native the pool genuinely held, and is still
    ///         monotonic, so F84 is preserved.
    uint256 public peakNativeRaised;

    /// @notice Tokens sold from the curve allocation. Net of buys − sells.
    uint256 public tokensSold;

    /// @notice True once the curve has CLOSED (threshold reached). All
    ///         buy/sell calls revert after this. Set atomically in buy()/
    ///         graduate() so trading always closes cleanly.
    bool public graduated;

    /// @notice True once liquidity has been migrated to the V2 DEX and the LP
    ///         burned. Separated from `graduated` (Sentinelle F-1): the LP
    ///         migration is a retryable permissionless step so a pre-seeded /
    ///         dust-griefed V2 pair can never brick trading or graduation.
    bool public graduationFinalized;

    /// @notice Timestamp at which the curve closed (`graduated` set true). Used
    ///         to time-gate the graduation rescue: within GRADUATION_RESCUE_DELAY
    ///         the strict price band is enforced, after it a persistently
    ///         out-of-band (griefed) pair no longer bricks migration.
    uint256 public graduatedAt;

    /// @notice True once `enterRefundMode()` has been called: LP migration is
    ///         abandoned for good and holders redeem their tokens against the
    ///         raise instead. One-way — nothing ever clears it.
    bool public refundMode;

    /// @notice Native (wei) set aside for refunds when refund mode opened —
    ///         a snapshot of `nativeRaised`. Frozen so a partially-drained pot
    ///         cannot reprice the holders who claim last.
    /// @notice Block at which the destination pair was last observed out of
    ///         band. Refund mode needs an observation strictly older than the
    ///         block it is entered in, so the manipulation cannot be atomic.
    uint256 public outOfBandFlaggedAt;

    uint256 public refundNativePot;

    /// @notice Tokens outstanding in holders' hands when refund mode opened —
    ///         a snapshot of `tokensSold`. Denominator of every refund share.
    uint256 public refundTokenPot;

    /// @notice Grace window after graduation during which finalizeGraduation is
    ///         the only exit. Once it elapses AND the destination pair is still
    ///         off the launch ratio, anyone may open refund mode instead, so a
    ///         griefer can no longer lock buyer funds forever (H-1). Migration
    ///         is NEVER performed at a manipulated ratio: the alternative to a
    ///         correct LP is giving the money back, not depositing blind.
    uint256 public constant GRADUATION_RESCUE_DELAY = 7 days;

    // ─── Events ──────────────────────────────────────────────────────────

    event Trade(
        address indexed trader,
        bool    isBuy,
        uint256 nativeIn,
        uint256 tokensOut,
        uint256 feeNative,
        uint256 newPriceNumerator,
        uint256 newPriceDenominator
    );

    event Graduated(
        address indexed pair,
        uint256 nativeMigrated,
        uint256 tokensMigrated,
        uint256 lpBurned
    );

    /// @notice Emitted when the launch is abandoned and holders may redeem.
    ///         `nativePot / tokenPot` is the fixed redemption price.
    event RefundModeEntered(address indexed pair, uint256 nativePot, uint256 tokenPot);
    event PairFlaggedOutOfBand(uint256 blockNumber);

    /// @notice Emitted on each holder redemption in refund mode.
    event Refunded(address indexed holder, uint256 tokensBurned, uint256 nativeOut);

    /// @notice Emitted when the curve closes and is ready for LP migration.
    ///         A keeper (or anyone) then calls finalizeGraduation().
    event GraduationReady(uint256 nativeRaised, uint256 tokensSold);

    // ─── Errors ──────────────────────────────────────────────────────────

    error AlreadyGraduated();
    error NotEnoughTokensInCurve();
    error InvalidAmount();
    error SlippageBuy(uint256 expected, uint256 received);
    error SlippageSell(uint256 expected, uint256 received);
    error NotReadyToGraduate();
    error AlreadyFinalized();
    /// @notice The pre-existing V2 pair's spot ratio deviates from the LAUNCH
    ///         ratio (`nativeForLp / tokenForLp` — the very ratio this pool
    ///         would have created on an empty pair) beyond
    ///         GRADUATION_TOLERANCE_BPS. Migrating into it would seed the V2
    ///         launch at a manipulated price, so we refuse. There is no
    ///         "deposit anyway" branch; the escape hatch is refund mode.
    error PairRatioOutOfBand(uint256 pairNativePerToken, uint256 launchNativePerToken);
    error BelowThreshold();
    /// @notice Refund mode is only reachable once the grace window has closed.
    error RescueDelayNotElapsed();
    /// @notice Refund mode refused: finalizeGraduation() would succeed right
    ///         now (pair empty or already within band), so the launch is not
    ///         stuck and must not be torn down.
    error GraduationStillViable();
    /// @dev Refund mode was requested without a prior out-of-band observation.
    error PairNotFlagged();
    /// @dev The out-of-band observation is from this block; it must be older so
    ///      a repair has somewhere to happen.
    error FlagTooRecent();
    error NotRefunding();
    error RefundTransferFailed();

    constructor(
        address token_,
        address router_,
        address feeVault_,
        uint256 totalSupply_,
        uint256 curveAllocation_,
        uint256 virtualNativeReserve_,
        uint256 graduationThreshold_
    ) {
        require(token_ != address(0)    && router_ != address(0) &&
                feeVault_ != address(0),                                  "zero address");
        require(curveAllocation_ < totalSupply_,                          "curve > supply");
        require(virtualNativeReserve_ > 0 && graduationThreshold_ > 0,    "zero param");

        token                = IERC20(token_);
        router               = IUniswapV2Router02(router_);
        feeVault             = feeVault_;
        wnative              = router.WETH();
        totalSupplyToken     = totalSupply_;
        curveAllocation      = curveAllocation_;
        virtualNativeReserve = virtualNativeReserve_;
        virtualTokenReserve  = curveAllocation_;
        graduationThreshold  = graduationThreshold_;
    }

    // ─── Pricing math ────────────────────────────────────────────────────

    /// @notice Effective native reserve = virtual + actual raised so far.
    function nativeReserve() public view returns (uint256) {
        return virtualNativeReserve + nativeRaised;
    }

    /// @notice Effective token reserve = virtual − tokens sold.
    function tokenReserve() public view returns (uint256) {
        return virtualTokenReserve - tokensSold;
    }

    /// @notice Spot price = (native reserve) / (token reserve), expressed
    ///         as a (numerator, denominator) pair so the caller can do
    ///         arbitrary-precision math without floats.
    function spotPrice() external view returns (uint256 numerator, uint256 denominator) {
        return (nativeReserve(), tokenReserve());
    }

    /// @dev Quote the amount of tokens received for `nativeIn` (after fee).
    ///      Returns (tokensOut, feeNative) — fee is the 1% taken off-curve.
    function quoteBuy(uint256 nativeIn) public view returns (uint256 tokensOut, uint256 feeNative) {
        if (nativeIn == 0) return (0, 0);
        feeNative = (nativeIn * FEE_BPS) / 10_000;
        uint256 nativeForCurve = nativeIn - feeNative;

        uint256 r0 = nativeReserve();
        uint256 r1 = tokenReserve();
        // (r0 + Δ) × (r1 − tokensOut) = r0 × r1
        // tokensOut = r1 − (r0 × r1) / (r0 + Δ)
        uint256 newR0 = r0 + nativeForCurve;
        uint256 newR1 = (r0 * r1) / newR0;
        tokensOut    = r1 - newR1;
    }

    /// @dev Quote the amount of native returned for `tokensIn` (after fee).
    function quoteSell(uint256 tokensIn) public view returns (uint256 nativeOut, uint256 feeNative) {
        if (tokensIn == 0) return (0, 0);
        uint256 r0 = nativeReserve();
        uint256 r1 = tokenReserve();
        uint256 newR1 = r1 + tokensIn;
        uint256 newR0 = (r0 * r1) / newR1;
        uint256 grossNative = r0 - newR0;
        feeNative = (grossNative * FEE_BPS) / 10_000;
        nativeOut = grossNative - feeNative;
    }

    // ─── Trading ─────────────────────────────────────────────────────────

    /// @notice Buy `tokensOut` tokens by sending `msg.value` native.
    ///         `minTokensOut` protects against price moves between quote
    ///         and tx mining. Reverts if pool has graduated.
    function buy(uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        if (graduated) revert AlreadyGraduated();
        if (msg.value == 0) revert InvalidAmount();

        uint256 feeNative;
        (tokensOut, feeNative) = quoteBuy(msg.value);
        if (tokensOut < minTokensOut) revert SlippageBuy(minTokensOut, tokensOut);
        if (tokensOut > tokenReserve()) revert NotEnoughTokensInCurve();

        // Update state
        uint256 nativeForCurve = msg.value - feeNative;
        nativeRaised += nativeForCurve;
        tokensSold   += tokensOut;
        // Graduation gate (F84): high-water mark of what the curve ACTUALLY
        // held, not the sum of the buy legs. Monotonic, so sells still cannot
        // walk the gate back, but a buy/sell round-trip no longer credits the
        // gate with money the pool gave straight back.
        if (nativeRaised > peakNativeRaised) peakNativeRaised = nativeRaised;

        // Transfer fee to FeeVault
        if (feeNative > 0) {
            (bool ok, ) = payable(feeVault).call{value: feeNative}("");
            require(ok, "fee transfer failed");
        }

        // Pay out tokens to buyer
        token.safeTransfer(msg.sender, tokensOut);

        emit Trade(msg.sender, true, msg.value, tokensOut, feeNative, nativeReserve(), tokenReserve());

        // Close the curve when the threshold is crossed. The LP migration is a
        // separate retryable step (finalizeGraduation) so a pre-seeded V2 pair
        // can never make this buy revert.
        if (peakNativeRaised >= graduationThreshold && !graduated) {
            graduated = true;
            graduatedAt = block.timestamp;
            emit GraduationReady(nativeRaised, tokensSold);
        }
    }

    /// @notice Sell `tokensIn` tokens for native. Caller must have approved
    ///         the pool first. `minNativeOut` protects against slippage.
    function sell(uint256 tokensIn, uint256 minNativeOut) external nonReentrant returns (uint256 nativeOut) {
        if (graduated) revert AlreadyGraduated();
        if (tokensIn == 0) revert InvalidAmount();

        uint256 feeNative;
        (nativeOut, feeNative) = quoteSell(tokensIn);
        if (nativeOut < minNativeOut) revert SlippageSell(minNativeOut, nativeOut);
        // The native side of the curve must have enough actual liquidity to
        // cover the payout. Sells in the early life of a curve can fail for
        // this reason — the buyer didn't put enough native in yet to cover
        // a large round-trip. The caller can sell smaller chunks.
        require(nativeOut + feeNative <= nativeRaised, "insufficient curve native");

        // Update state
        nativeRaised -= (nativeOut + feeNative);
        tokensSold   -= tokensIn;

        // Pull tokens from seller, push native + fee out
        token.safeTransferFrom(msg.sender, address(this), tokensIn);
        if (feeNative > 0) {
            (bool ok1, ) = payable(feeVault).call{value: feeNative}("");
            require(ok1, "fee transfer failed");
        }
        (bool ok2, ) = payable(msg.sender).call{value: nativeOut}("");
        require(ok2, "native transfer failed");

        emit Trade(msg.sender, false, nativeOut, tokensIn, feeNative, nativeReserve(), tokenReserve());
    }

    // ─── Graduation ──────────────────────────────────────────────────────

    /// @notice Manually close the curve once the gate (`peakNativeRaised`) is at
    ///         or above the threshold. Permissionless. Does NOT migrate
    ///         liquidity itself — that is the separate, retryable
    ///         finalizeGraduation() step.
    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        if (peakNativeRaised < graduationThreshold) revert BelowThreshold();
        graduated = true;
        graduatedAt = block.timestamp;
        emit GraduationReady(nativeRaised, tokensSold);
    }

    /// @notice Migrate the curve's liquidity to the V2 DEX and burn the LP.
    ///         Permissionless and retryable: callable once the curve has closed
    ///         (`graduated`). It does not hard-revert merely because a V2 pair
    ///         already exists (a frontrunner could pre-create one and brick
    ///         graduation forever).
    ///
    ///         Two cases, ONE launch price in both:
    ///           - empty pair  → we set the price ourselves at the launch ratio
    ///             `nativeForLp / tokenForLp`, floors = that ratio minus the
    ///             tolerance band;
    ///           - seeded pair → the router will deposit at the PAIR's ratio, so
    ///             we require that ratio to sit within the band of the launch
    ///             ratio and we derive the floors from the amounts the router
    ///             will actually take given those reserves.
    ///
    ///         Deriving the floors from the pair is what makes the honest path
    ///         reachable at all. Previously the band was measured against the
    ///         curve TERMINAL price (nativeRaised / tokensSold) while the floors
    ///         were 98% of the pool's DESIRED amounts (nativeForLp / tokenForLp)
    ///         — two different ratios, off by tokensSold / tokenForLp. A pair
    ///         sitting perfectly inside the band still blew up the deposit on
    ///         INSUFFICIENT_B_AMOUNT, which left the "forced" branch as the only
    ///         way out of any seeded pair. Both sides now speak of the same
    ///         ratio, the one an empty pair would have been given.
    ///
    ///         There is no branch that relaxes the floors to zero. A pair that
    ///         stays out of band is handled by enterRefundMode(), not by
    ///         depositing at whatever price the griefer chose.
    function finalizeGraduation() external nonReentrant {
        if (!graduated) revert NotReadyToGraduate();
        if (graduationFinalized) revert AlreadyFinalized();
        graduationFinalized = true;

        // Native to migrate = the ACCOUNTED curve native (already net of fees).
        // We deliberately do NOT read address(this).balance: receive() rejects
        // unsolicited ETH, but anchoring on the accounted value rather than the
        // raw balance keeps any stray native (e.g. a self-destruct push, which
        // bypasses receive()) from inflating the migrated native and distorting
        // the V2 launch price (F83).
        uint256 nativeForLp = nativeRaised;
        // Token allocation reserved for graduation = total supply - curveAlloc.
        uint256 tokenForLp = totalSupplyToken - curveAllocation;
        // A zero-native migration cannot be given a non-zero ETH floor and
        // cannot mint meaningful LP. Refuse; enterRefundMode() covers it.
        if (nativeForLp == 0) revert InvalidAmount();

        // Burn any unsold curve tokens so they don't dilute LP value.
        uint256 unsoldCurve = tokenReserve();
        if (unsoldCurve > 0) {
            token.safeTransfer(DEAD, unsoldCurve);
        }

        // Detect a pre-existing pair WITH reserves. We don't hard-revert merely
        // because a pair exists (a frontrunner could pre-create a dust pair),
        // but we DO refuse to deposit into a pair whose spot ratio deviates from
        // the launch ratio beyond the tolerance band: doing so would seed the V2
        // launch at a price the griefer picked, and — because the router only
        // takes the two sides in the pair's proportion — would dump the rest of
        // the raise into the leftover sweep below.
        (, uint256 reserveNative, uint256 reserveToken) = _pairReserves();
        bool seededPair = (reserveNative | reserveToken) != 0;

        uint256 amountTokenMin;
        uint256 amountETHMin;
        if (seededPair) {
            if (!_withinBand(reserveNative, reserveToken, nativeForLp, tokenForLp)) {
                revert PairRatioOutOfBand(
                    reserveToken == 0
                        ? type(uint256).max
                        : (reserveNative * 1e18) / reserveToken,
                    (nativeForLp * 1e18) / tokenForLp
                );
            }
            // Mirror UniswapV2Router._addLiquidity: the router keeps whichever
            // side is scarcer at the PAIR's ratio and quotes the other from the
            // reserves. Floors track those two amounts, so they are tight
            // against the deposit that is actually about to happen instead of
            // against amounts the router was never going to take.
            // _withinBand guarantees both reserves are non-zero here.
            uint256 nativeOptimal = (tokenForLp * reserveNative) / reserveToken;
            if (nativeOptimal <= nativeForLp) {
                amountTokenMin = _floorWithBand(tokenForLp);
                amountETHMin   = _floorWithBand(nativeOptimal);
            } else {
                amountTokenMin = _floorWithBand((nativeForLp * reserveToken) / reserveNative);
                amountETHMin   = _floorWithBand(nativeForLp);
            }
        } else {
            // Empty pair: we set the launch price, so the floors are simply the
            // desired amounts minus the band.
            amountTokenMin = _floorWithBand(tokenForLp);
            amountETHMin   = _floorWithBand(nativeForLp);
        }

        token.forceApprove(address(router), tokenForLp);

        (uint256 usedToken, uint256 usedNative, uint256 lp) = router.addLiquidityETH{value: nativeForLp}(
            address(token),
            tokenForLp,
            amountTokenMin,
            amountETHMin,
            address(this),
            block.timestamp
        );

        // Burn the LP so liquidity is permanently locked — no rug.
        address pair = IUniswapV2Factory(router.factory()).getPair(address(token), wnative);
        IERC20(pair).safeTransfer(DEAD, lp);

        // Clean up any deposit leftover from a pre-seeded pair's ratio: burn
        // leftover tokens, forward leftover native to the FeeVault. Both sides
        // are now bounded by the tolerance band (the pair had to be within band
        // to get here), so this sweep only ever handles dust — it can no longer
        // carry the bulk of a launch's raise to the vault.
        uint256 leftoverToken = tokenForLp - usedToken;
        if (leftoverToken > 0) {
            token.safeTransfer(DEAD, leftoverToken);
        }
        uint256 leftoverNative = nativeForLp - usedNative;
        if (leftoverNative > 0) {
            (bool ok, ) = payable(feeVault).call{value: leftoverNative}("");
            require(ok, "leftover native transfer failed");
        }

        // Report 21: every wei counted by `nativeRaised` has just left — into
        // the LP, or swept to the feeVault. Leaving the figure standing made
        // `nativeReserve()` keep quoting a balance the pool no longer holds, so
        // any integrator reading it after graduation was told a number that had
        // stopped being true. Trading is closed by then, so nothing inside this
        // contract acted on it; a getter that lies is a defect on its own.
        nativeRaised = 0;

        emit Graduated(pair, usedNative, usedToken, lp);
    }

    // ─── Refund mode — the only escape from a permanently griefed pair ───

    /// @notice Abandon the LP migration and let every holder redeem instead.
    ///
    ///         Permissionless, but deliberately hard to reach: it needs the
    ///         grace window to have elapsed AND the destination pair to be
    ///         out of band AT THE MOMENT OF THE CALL. That last condition is
    ///         what defuses the obvious abuse — seed the pair off-ratio, wait
    ///         seven days, then tear the launch down. A V2 pair's ratio can be
    ///         moved back toward any target by donating the scarce side and
    ///         calling sync(), which for a dust-seeded pair costs dust; so
    ///         anyone who wants the launch to live can, in a single tx, fix the
    ///         pair and call finalizeGraduation(), and that tx invalidates the
    ///         refund call (they become mutually exclusive by construction —
    ///         in band, only migration is legal; out of band, only refund is).
    ///         Refund therefore only wins when nobody at all is willing to
    ///         spend dust to save the launch, i.e. when it is already dead. A
    ///         griefer who instead seeds the pair large enough to make the fix
    ///         expensive has to lock up that capital at his own risk, and still
    ///         gains nothing here: refunds pay holders, not him.
    ///
    ///         Preferring refund over "deposit at whatever price the griefer
    ///         set" is the whole point: the old forced path handed the raise to
    ///         whoever owned the pair, or swept it to the feeVault. Here the
    ///         money goes back to the people who paid it.
    ///
    ///         One-way. Graduation is closed for good once this succeeds.
    function flagPairOutOfBand() external nonReentrant {
        if (!graduated) revert NotReadyToGraduate();
        if (graduationFinalized) revert AlreadyFinalized();
        if (block.timestamp <= graduatedAt + GRADUATION_RESCUE_DELAY) revert RescueDelayNotElapsed();

        (, uint256 reserveNative, uint256 reserveToken) = _pairReserves();
        if ((reserveNative | reserveToken) == 0) revert GraduationStillViable();
        if (_withinBand(reserveNative, reserveToken, nativeRaised, totalSupplyToken - curveAllocation)) {
            revert GraduationStillViable();
        }

        outOfBandFlaggedAt = block.number;
        emit PairFlaggedOutOfBand(block.number);
    }

    function enterRefundMode() external nonReentrant {
        if (!graduated) revert NotReadyToGraduate();
        if (graduationFinalized) revert AlreadyFinalized();
        if (block.timestamp <= graduatedAt + GRADUATION_RESCUE_DELAY) revert RescueDelayNotElapsed();

        // Report 21: the out-of-band condition must have been observed in an
        // EARLIER block. Reading it only here let an attacker skew the pair and
        // liquidate the launch in one transaction, leaving no instant in which
        // anyone could repair the pair — the claim that others could step in was
        // an economic hope, not something the code enforced. Requiring the
        // manipulation to survive a block boundary makes the repair window real,
        // and repairing makes the band check below revert.
        if (outOfBandFlaggedAt == 0) revert PairNotFlagged();
        if (block.number <= outOfBandFlaggedAt) revert FlagTooRecent();

        uint256 nativePot = nativeRaised;
        uint256 tokenPot  = tokensSold;
        // Nothing raised or nothing outstanding ⇒ no refund to distribute, and
        // tokenPot is the redemption denominator, so it must not be zero.
        if (nativePot == 0 || tokenPot == 0) revert InvalidAmount();

        (address pair, uint256 reserveNative, uint256 reserveToken) = _pairReserves();
        // An empty pair, or one already at the launch ratio, means
        // finalizeGraduation() would go through right now. Do not let anyone
        // liquidate a launch that is not actually stuck.
        if ((reserveNative | reserveToken) == 0) revert GraduationStillViable();
        if (_withinBand(reserveNative, reserveToken, nativePot, totalSupplyToken - curveAllocation)) {
            revert GraduationStillViable();
        }

        refundMode          = true;
        graduationFinalized = true; // closes finalizeGraduation() for good
        refundNativePot     = nativePot;
        refundTokenPot      = tokenPot;

        emit RefundModeEntered(pair, nativePot, tokenPot);
    }

    /// @notice Burn `tokensIn` tokens for their share of the raise at the curve
    ///         terminal price: `refundNativePot × tokensIn / refundTokenPot`.
    ///         Caller must have approved the pool. Tokens go to DEAD, so a
    ///         share can never be claimed twice.
    ///
    ///         Solvency: `refundTokenPot` is exactly the supply held outside
    ///         this pool when refund mode opened, and the pool releases no
    ///         further tokens afterwards (buy() is closed), so the claims can
    ///         never sum past the pot. Rounding is down, in the pool's favour.
    function claimRefund(uint256 tokensIn) external nonReentrant returns (uint256 nativeOut) {
        if (!refundMode) revert NotRefunding();
        if (tokensIn == 0) revert InvalidAmount();

        nativeOut = (refundNativePot * tokensIn) / refundTokenPot;
        if (nativeOut == 0) revert InvalidAmount();

        token.safeTransferFrom(msg.sender, DEAD, tokensIn);
        (bool ok, ) = payable(msg.sender).call{value: nativeOut}("");
        if (!ok) revert RefundTransferFailed();

        emit Refunded(msg.sender, tokensIn, nativeOut);
    }

    // ─── Pair helpers ────────────────────────────────────────────────────

    /// @dev The destination pair and its reserves mapped to (native, token)
    ///      regardless of token ordering — token0 is the lower address. Both
    ///      reserves read zero when the pair does not exist yet.
    function _pairReserves()
        internal
        view
        returns (address pair, uint256 reserveNative, uint256 reserveToken)
    {
        pair = IUniswapV2Factory(router.factory()).getPair(address(token), wnative);
        if (pair == address(0)) return (pair, 0, 0);
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        (reserveNative, reserveToken) =
            address(token) < wnative ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
    }

    /// @dev True when the pair's spot ratio (native per token) sits within
    ///      GRADUATION_TOLERANCE_BPS of `refNative / refToken`. Compared via
    ///      cross-multiplication so there is no division-precision loss. A
    ///      single-sided pair can never match a finite ratio → false.
    ///
    ///      |rN/rT − refN/refT| / (refN/refT) ≤ tol
    ///        ⇔ |rN·refT − refN·rT| ≤ tol · refN · rT   (basis points)
    function _withinBand(
        uint256 reserveNative,
        uint256 reserveToken,
        uint256 refNative,
        uint256 refToken
    ) internal pure returns (bool) {
        if (reserveNative == 0 || reserveToken == 0 || refNative == 0 || refToken == 0) return false;
        uint256 lhs  = reserveNative * refToken;
        uint256 rhs  = refNative * reserveToken;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        return diff <= (rhs * GRADUATION_TOLERANCE_BPS) / 10_000;
    }

    /// @dev `amount` minus the tolerance band, rounded UP so a non-zero amount
    ///      never yields a zero floor. Ceiling of a value ≤ amount is still
    ///      ≤ amount, so the floor stays satisfiable.
    function _floorWithBand(uint256 amount) internal pure returns (uint256) {
        return (amount * (10_000 - GRADUATION_TOLERANCE_BPS) + 9_999) / 10_000;
    }

    // ─── Receive — reject unsolicited native ─────────────────────────────
    //
    // The pool's native accounting is driven entirely by buy()/sell() via
    // msg.value and the curve math; `nativeRaised` is the single source of
    // truth for the graduation migration (F83). Bare native transfers from
    // arbitrary senders must NOT be allowed to inflate the pool's native and
    // distort the V2 launch price, so we reject them. The only expected inbound
    // native is the graduation refund of the unused ETH side: the V2 router
    // refunds it directly (TransferHelper.safeTransferETH from the router), and
    // the WETH/wnative contract may unwrap to us along that path — both are
    // whitelisted. finalizeGraduation already sweeps any such leftover to the
    // FeeVault. (Native force-pushed via selfdestruct still bypasses this hook,
    // which is exactly why finalizeGraduation anchors on the accounted
    // `nativeRaised` rather than address(this).balance.)
    receive() external payable {
        require(msg.sender == address(router) || msg.sender == wnative, "unsolicited native");
    }
}
