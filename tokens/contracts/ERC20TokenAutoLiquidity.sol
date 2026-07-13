// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";

/**
 * @title ERC20TokenAutoLiquidity
 * @dev Token ERC-20 avec taxe de 2% et liquidité brûlée pour le mode gratuit (auto-liquidity)
 * 
 * Ce contrat est utilisé quand l'utilisateur crée un token sans payer de frais.
 * En échange, le token a une taxe de transfert de 2% qui va au trésor.
 */
contract ERC20TokenAutoLiquidity is ERC20, ERC20Burnable, Ownable2Step, ERC20Pausable {
    // Taxe de transfert (2% = 200 basis points)
    uint256 public constant TRANSFER_TAX_BPS = 200; // 2%
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    // Adresse du trésor qui reçoit les taxes
    address public treasuryAddress;
    
    // Liquidity brûlée (stockée pour référence)
    uint256 public initialLiquidityBurned;
    
    // Adresses exemptées de taxe (owner, pools, etc.)
    mapping(address => bool) public isTaxExempt;
    
    // Métadonnées
    string private _tokenURI;
    
    // Events
    event MetadataUpdated(string newURI);
    event TaxCollected(address indexed from, address indexed to, uint256 taxAmount);
    event TaxExemptionUpdated(address indexed account, bool exempt);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event LiquidityBurned(uint256 amount);

    constructor(
        string memory name,
        string memory symbol,
        string memory initialURI,
        uint256 totalSupply,
        address initialOwner,
        address _treasuryAddress,
        uint256 liquidityToBurn
    ) ERC20(name, symbol) Ownable(initialOwner) {
        require(_treasuryAddress != address(0), "Treasury cannot be zero address");
        
        treasuryAddress = _treasuryAddress;
        _tokenURI = initialURI;
        
        // Mint les tokens au créateur
        _mint(initialOwner, totalSupply);

        // Owner and treasury are tax exempt — must be set BEFORE the liquidity burn
        // transfer so that the burn itself is not subject to the 2% tax
        isTaxExempt[initialOwner] = true;
        isTaxExempt[_treasuryAddress] = true;

        // Brûler la liquidité initiale si spécifiée
        if (liquidityToBurn > 0 && liquidityToBurn <= totalSupply) {
            // Transfer to dead address (0x000...dead) to "burn" liquidity
            _transfer(initialOwner, address(0xdead), liquidityToBurn);
            initialLiquidityBurned = liquidityToBurn;
            emit LiquidityBurned(liquidityToBurn);
        }
        
        emit MetadataUpdated(initialURI);
    }

    /**
     * @dev Override _update to implement transfer tax
     */
    function _update(address from, address to, uint256 amount) internal virtual override(ERC20, ERC20Pausable) {
        // Skip tax for minting, burning, or exempt addresses
        if (from == address(0) || to == address(0) || isTaxExempt[from] || isTaxExempt[to]) {
            super._update(from, to, amount);
            return;
        }
        
        // Calculate 2% tax
        uint256 taxAmount = (amount * TRANSFER_TAX_BPS) / BPS_DENOMINATOR;
        uint256 transferAmount = amount - taxAmount;
        
        // Transfer tax to treasury
        if (taxAmount > 0) {
            super._update(from, treasuryAddress, taxAmount);
            emit TaxCollected(from, to, taxAmount);
        }
        
        // Transfer remaining to recipient
        super._update(from, to, transferAmount);
    }

    /**
     * @dev Set tax exemption for an address
     */
    function setTaxExempt(address account, bool exempt) external onlyOwner {
        isTaxExempt[account] = exempt;
        emit TaxExemptionUpdated(account, exempt);
    }

    /**
     * @dev Update treasury address. Revokes the old treasury's tax-exempt
     *      status so historical addresses don't accumulate permanent
     *      privileged-trading rights after rotation (Sentinelle MEDIUM SC03
     *      2026-05-22).
     */
    function setTreasuryAddress(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Treasury cannot be zero address");
        address oldTreasury = treasuryAddress;
        // Never strip the owner's own exemption (set independently at
        // construction) in the edge config where treasury == owner.
        if (oldTreasury != address(0) && oldTreasury != newTreasury && oldTreasury != owner()) {
            isTaxExempt[oldTreasury] = false;
            emit TaxExemptionUpdated(oldTreasury, false);
        }
        treasuryAddress = newTreasury;
        isTaxExempt[newTreasury] = true;
        emit TaxExemptionUpdated(newTreasury, true);
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @dev Get token URI (metadata)
     */
    function tokenURI() public view returns (string memory) {
        return _tokenURI;
    }

    /// @notice Update the metadata URI. The constructor emits
    ///         `MetadataUpdated` implying mutability; this setter honours
    ///         that contract (Sentinelle MEDIUM SC03 2026-05-22 — same as
    ///         the OFT-AL variant).
    function setTokenURI(string memory newURI) external onlyOwner {
        _tokenURI = newURI;
        emit MetadataUpdated(newURI);
    }

    /**
     * @dev Pause all transfers
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause all transfers
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /// @dev Block `renounceOwnership` while the contract is paused.
    ///      Without this guard, an owner can pause then renounce in two
    ///      transactions, permanently freezing all transfers (kills DEX
    ///      trading, all user exits) with no recovery path. Sentinelle
    ///      HIGH SC10 2026-05-22 (CVSS 7.5).
    function renounceOwnership() public virtual override onlyOwner {
        require(!paused(), "ERC20TokenAL: cannot renounce while paused");
        super.renounceOwnership();
    }

    /**
     * @dev Calculate tax for a given amount
     */
    function calculateTax(uint256 amount) public pure returns (uint256) {
        return (amount * TRANSFER_TAX_BPS) / BPS_DENOMINATOR;
    }

    /**
     * @dev Get effective transfer amount after tax
     */
    function getAmountAfterTax(uint256 amount) public pure returns (uint256) {
        return amount - calculateTax(amount);
    }
}
