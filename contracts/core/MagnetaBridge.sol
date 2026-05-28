// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title MagnetaBridge (DEPRECATED)
 * @dev This placeholder contract is superseded by:
 *      - MagnetaBridgeOApp.sol  — direct token bridging via LayerZero v2 OApp
 *      - MagnetaGateway.sol     — cross-chain op dispatch (LP, swap, token ops)
 *
 *      Kept only so existing deploy scripts and ABIs don't break during migration.
 *      Do NOT deploy this contract on new chains.
 */
contract MagnetaBridge {
    constructor() {
        revert("MagnetaBridge: deprecated - use MagnetaBridgeOApp or MagnetaGateway");
    }
}
