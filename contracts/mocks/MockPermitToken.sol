// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev Minimal EIP-2612 token for testing LPModule's `_applyPermit` one-click
///      flow. Plain OZ ERC20Permit (4.9.6) — no transfer tax, no fee-on-transfer
///      quirks, so the permit behaviour is isolated from unrelated token
///      mechanics.
contract MockPermitToken is ERC20, ERC20Permit {
    constructor() ERC20("Permit Token", "PMT") ERC20Permit("Permit Token") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
