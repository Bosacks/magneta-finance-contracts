// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Deflationary / fee-on-transfer ERC20 stand-in for testing that downstream
/// contracts measure actually-received amounts via a balance delta instead of
/// trusting the nominal transfer amount. Every transfer burns `feeBps` of the
/// moved amount, so the recipient is always credited less than `amount`.
contract MockFeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps; // e.g. 100 = 1%

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 feeBps_
    ) ERC20(name, symbol) {
        require(feeBps_ < 10000, "fee too high");
        feeBps = feeBps_;
        _mint(msg.sender, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// Skim a fee on every (non-mint/burn) transfer by burning it from `from`.
    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = (amount * feeBps) / 10000;
        if (fee > 0) {
            super._burn(from, fee);
        }
        super._transfer(from, to, amount - fee);
    }
}
