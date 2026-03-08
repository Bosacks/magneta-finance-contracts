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
 */
library BinHelper {
    uint256 internal constant PRICE_PRECISION = 1e18;
    uint24  internal constant BASE_ID         = 8_388_608; // 2^23
    uint24  internal constant MAX_STEPS       = 4_096;

    /**
     * @dev Compute the price (in PRICE_PRECISION units) at `binId` given `binStep` bps.
     */
    function getPriceFromId(uint24 binId, uint16 binStep) internal pure returns (uint256 price) {
        price = PRICE_PRECISION;

        if (binId >= BASE_ID) {
            uint24 steps = binId - BASE_ID;
            if (steps > MAX_STEPS) steps = MAX_STEPS;
            for (uint24 i = 0; i < steps; ++i) {
                price = price * (10_000 + binStep) / 10_000;
            }
        } else {
            uint24 steps = BASE_ID - binId;
            if (steps > MAX_STEPS) steps = MAX_STEPS;
            for (uint24 i = 0; i < steps; ++i) {
                price = price * 10_000 / (10_000 + binStep);
            }
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
