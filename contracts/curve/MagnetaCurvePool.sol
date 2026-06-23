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
    ///         decide whether the V2 pair is empty (we set the price with 99%
    ///         mins) or pre-seeded (we deposit at its ratio with mins = 0
    ///         instead of hard-reverting, which would brick graduation).
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

    /// @notice Permanent burn destination for graduation LP tokens.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ─── Wired contracts ─────────────────────────────────────────────────

    IERC20 public immutable token;
    IUniswapV2Router02 public immutable router;
    address public immutable feeVault;
    address public immutable wnative;

    // ─── Mutable state ───────────────────────────────────────────────────

    /// @notice Native (in wei) raised on the curve so far, net of sells +
    ///         net of fees. Used to detect graduation.
    uint256 public nativeRaised;

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
        if (nativeRaised >= graduationThreshold && !graduated) {
            graduated = true;
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

    /// @notice Manually close the curve once `nativeRaised` is at or above the
    ///         threshold. Permissionless. Does NOT migrate liquidity itself —
    ///         that is the separate, retryable finalizeGraduation() step.
    function graduate() external nonReentrant {
        if (graduated) revert AlreadyGraduated();
        require(nativeRaised >= graduationThreshold, "below threshold");
        graduated = true;
        emit GraduationReady(nativeRaised, tokensSold);
    }

    /// @notice Migrate the curve's liquidity to the V2 DEX and burn the LP.
    ///         Permissionless and retryable: callable once the curve has closed
    ///         (`graduated`). Tolerant of a pre-seeded / dust-griefed V2 pair —
    ///         it never hard-reverts on existing reserves (that was the
    ///         graduation-DoS vector). For an empty pair it sets the price with
    ///         99% mins; for a pre-seeded pair it deposits at the pair's current
    ///         ratio (mins = 0) and cleans up the leftover so nothing is left
    ///         ambiguously stranded.
    function finalizeGraduation() external nonReentrant {
        if (!graduated) revert NotReadyToGraduate();
        if (graduationFinalized) revert AlreadyFinalized();
        graduationFinalized = true;

        // Native to migrate = everything we hold (already net of fees).
        uint256 nativeForLp = address(this).balance;
        // Token allocation reserved for graduation = total supply - curveAlloc.
        uint256 tokenForLp = totalSupplyToken - curveAllocation;

        // Burn any unsold curve tokens so they don't dilute LP value.
        uint256 unsoldCurve = tokenReserve();
        if (unsoldCurve > 0) {
            token.safeTransfer(DEAD, unsoldCurve);
        }

        // Detect a pre-existing pair WITH reserves. We no longer hard-revert on
        // it (a frontrunner could pre-create a dust pair and brick graduation
        // forever). Instead: empty pair → we set the price (99% mins); seeded
        // pair → deposit at its ratio (mins = 0) and burn/forward the leftover.
        address existingPair = IUniswapV2Factory(router.factory()).getPair(address(token), wnative);
        bool emptyPair = existingPair == address(0);
        if (!emptyPair) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(existingPair).getReserves();
            emptyPair = (r0 == 0 && r1 == 0);
        }

        token.forceApprove(address(router), tokenForLp);

        uint256 amountTokenMin = emptyPair ? (tokenForLp * 99) / 100 : 0;
        uint256 amountETHMin   = emptyPair ? (nativeForLp * 99) / 100 : 0;

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
        // leftover tokens, forward leftover native to the FeeVault.
        uint256 leftoverToken = tokenForLp - usedToken;
        if (leftoverToken > 0) {
            token.safeTransfer(DEAD, leftoverToken);
        }
        uint256 leftoverNative = nativeForLp - usedNative;
        if (leftoverNative > 0) {
            (bool ok, ) = payable(feeVault).call{value: leftoverNative}("");
            require(ok, "leftover native transfer failed");
        }

        emit Graduated(pair, usedNative, usedToken, lp);
    }

    // ─── Receive — accept native top-ups (used by router callbacks etc.) ──

    receive() external payable {}
}
