// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal deflationary / fee-on-transfer ERC20 for tests: burns a fixed
///         basis-point fee on every transfer, so the recipient receives less than
///         the amount sent. Used to verify Multisender rejects such tokens.
contract MockFeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps; // e.g. 1000 = 10%

    constructor(uint256 supply, uint256 feeBps_) ERC20("FeeOnTransfer", "FOT") {
        feeBps = feeBps_;
        _mint(msg.sender, supply);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mint/burn (from==0 || to==0) pass through untouched; regular transfers
        // burn `feeBps` of the amount so `to` receives less than `value`.
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee > 0) {
                super._update(from, address(0), fee); // burn the fee
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}
