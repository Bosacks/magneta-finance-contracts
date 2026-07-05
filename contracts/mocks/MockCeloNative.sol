// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only stand-in for Celo's GoldToken precompile at
///         0x471EcE3750Da237f93B8E339c536989b8978a438, which UbeswapCeloAdapter
///         treats as an ERC20 view over the chain's native CELO balance.
///
///         On real Celo, native CELO and its ERC20 balance are the SAME
///         underlying state — there is no separate ledger. A plain Hardhat
///         network cannot reproduce that duality (it isn't Celo), so this
///         mock approximates it: every `transfer`/`transferFrom` that moves
///         the ERC20 ledger ALSO forwards the same amount of real native
///         value out of this contract's own reserve. Pre-fund this contract
///         with native ETH (and mint ledger balance to whichever party needs
///         it) in test setup so both sides stay consistent.
///
///         Caveat documented in the adapter's test suite: this only makes
///         the "CELO flows OUT of the adapter" direction fully stateless in
///         native terms. Payable entrypoints where the *test* sends raw
///         `msg.value` directly to the adapter (addLiquidityETH,
///         swapExactETHForTokens) still require a manual `mint()` to seed the
///         adapter's ledger balance, and the raw `msg.value` used to satisfy
///         that call remains stuck as real balance on the adapter — an
///         artifact of not being able to run this on genuine Celo, not a bug
///         in the adapter.
contract MockCeloNative is ERC20 {
    constructor() ERC20("Celo", "CELO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _forwardNative(to, amount);
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _forwardNative(to, amount);
        return ok;
    }

    function _forwardNative(address to, uint256 amount) internal {
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "MockCeloNative: native forward failed");
    }

    receive() external payable {}
}
