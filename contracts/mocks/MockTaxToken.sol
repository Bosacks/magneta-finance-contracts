// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// Stand-in for a Magneta auto-liquidity token that collects transfer taxes.
/// Unit tests don't exercise the tax accrual path itself — they need to see
/// that TaxClaimModule can: (a) read marketingWallet, (b) call withdrawFees()
/// to pull pre-seeded tokens here, (c) then swap them. So `withdrawFees` just
/// moves a `pendingFees` balance from this contract to `marketingWallet`.
contract MockTaxToken is ERC20, Ownable {
    address public marketingWallet;
    uint256 public pendingFees;

    event MarketingWalletSet(address w);
    event FeesWithdrawn(address to, uint256 amount);

    constructor(string memory n, string memory s) ERC20(n, s) {}

    function setMarketingWallet(address w) external onlyOwner {
        marketingWallet = w;
        emit MarketingWalletSet(w);
    }

    /// Seed pending tax balance on the token (mint to self).
    function seedPending(uint256 amount) external {
        _mint(address(this), amount);
        pendingFees += amount;
    }

    function withdrawFees() external {
        require(marketingWallet != address(0), "no marketingWallet");
        uint256 amt = pendingFees;
        pendingFees = 0;
        _transfer(address(this), marketingWallet, amt);
        emit FeesWithdrawn(marketingWallet, amt);
    }
}
