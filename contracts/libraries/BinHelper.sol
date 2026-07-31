// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BinHelper
 * @dev Geometric price math for DLMM bins.
 *
 * Price representation: price * PRICE_PRECISION (1e18 = 1.0)
 * At BASE_ID the price equals 1.0.
 * Each bin step UP multiplies by (10000 + binStep) / 10000.
 * Each bin step DOWN multiplies by 10000 / (10000 + binStep).
 *
 * Example: binStep = 25 (0.25%)
 *   price(BASE_ID + 1) = 1.0025
 *   price(BASE_ID - 1) = 0.9975...
 *
 * Gas note: limited to MAX_STEPS (4096) from BASE_ID.
 *
 * Representable range (free-scan 2026-07-31, C-1/H-1): MAX_STEPS is an upper
 * bound on the LOOP, not a guarantee that the price stays representable. The
 * usable range is narrower and depends on binStep:
 *   - downward, floor division drives the price to exactly 0 (binStep 100 bps
 *     → step 3760; 300 → 1302; 500 → 799), and 0 is catastrophic downstream:
 *     MagnetaDLMM.swap computes grossOut = amountIn * price / 1e18 == 0, hands
 *     the WHOLE input to the bin, returns 0, and passes `amountOut >=
 *     minAmountOut` because a frontend quoting from this same helper also
 *     derives minAmountOut == 0. The swapper loses everything, silently.
 *   - upward, price * (10_000 + binStep) overflows uint256 (binStep 500 bps →
 *     step 2599), which panics rather than mis-prices.
 * Both ends now REVERT with a named error instead of returning a poisoned
 * value or being silently clamped. Clamping was itself a bug: it made every
 * bin past the ceiling share one price, destroying the strict monotonicity a
 * DLMM depends on.
 */
library BinHelper {
    uint256 internal constant PRICE_PRECISION = 1e18;
    uint24  internal constant BASE_ID         = 8_388_608; // 2^23
    uint24  internal constant MAX_STEPS       = 4_096;

    /// @dev `binId` is further than MAX_STEPS from BASE_ID. Previously clamped,
    ///      which collapsed distinct bins onto one price.
    error BinTooFar(uint24 steps);
    /// @dev Repeated floor division drove the price to 0 — the bin is outside
    ///      the representable range for this binStep. Never return 0.
    error PriceUnderflow(uint24 binId, uint16 binStep);

    /**
     * @dev Compute the price (in PRICE_PRECISION units) at `binId` given `binStep` bps.
     *      Reverts rather than returning an unusable price — see the range note
     *      on the library.
     */
    function getPriceFromId(uint24 binId, uint16 binStep) internal pure returns (uint256 price) {
        price = PRICE_PRECISION;

        if (binId >= BASE_ID) {
            uint24 steps = binId - BASE_ID;
            if (steps > MAX_STEPS) revert BinTooFar(steps);
            for (uint24 i = 0; i < steps; ++i) {
                // Overflow past the representable range panics (0x11) — the
                // whole call reverts atomically, so no mis-priced state lands.
                price = price * (10_000 + binStep) / 10_000;
            }
        } else {
            uint24 steps = BASE_ID - binId;
            if (steps > MAX_STEPS) revert BinTooFar(steps);
            for (uint24 i = 0; i < steps; ++i) {
                price = price * 10_000 / (10_000 + binStep);
            }
            // Once the division floors to 0 it stays 0, so one check after the
            // loop is equivalent to checking every iteration, and far cheaper.
            if (price == 0) revert PriceUnderflow(binId, binStep);
        }
    }

    /**
     * @dev Find the bin ID closest to `price` given `binStep`.
     * Uses binary search approach via iterative approximation.
     */
    function getIdFromPrice(uint256 price, uint16 binStep) internal pure returns (uint24) {
        if (price == PRICE_PRECISION) return BASE_ID;
        if (price > PRICE_PRECISION) {
            uint24 id = BASE_ID;
            uint256 p = PRICE_PRECISION;
            while (p < price && id < BASE_ID + MAX_STEPS) {
                p = p * (10_000 + binStep) / 10_000;
                ++id;
            }
            return id;
        } else {
            uint24 id = BASE_ID;
            uint256 p = PRICE_PRECISION;
            while (p > price && id > BASE_ID - MAX_STEPS) {
                p = p * 10_000 / (10_000 + binStep);
                --id;
            }
            return id;
        }
    }
}
