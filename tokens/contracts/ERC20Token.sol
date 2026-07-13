// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";

/**
 * @title ERC20Token
 * @dev Token ERC-20 personnalisable avec options de revoke
 */
contract ERC20Token is ERC20, ERC20Burnable, Ownable2Step, ERC20Pausable {
    // Options de revoke
    bool public revokeUpdateEnabled;
    bool public revokeFreezeEnabled;
    bool public revokeMintEnabled;
    
    // Métadonnées (non modifiables si revokeUpdateEnabled)
    string private _tokenURI;

    // Blacklist mapping
    mapping(address => bool) public isBlacklisted;

    // Tax configuration
    uint256 public taxFee; // Basis points (e.g., 100 = 1%)

    /// @notice Tax fees collected in `_update` awaiting `withdrawFees()`.
    ///         Tracked separately from `balanceOf(address(this))` so tokens
    ///         accidentally sent to this contract are NOT swept to the
    ///         marketing wallet (Sentinelle HIGH SC02 2026-05-22, Venus
    ///         Protocol $2M+ pattern).
    uint256 public accumulatedTaxFees;
    address public marketingWallet;

    // Events
    event MetadataUpdated(string newURI);
    event RevokeUpdateEnabled();
    event RevokeFreezeEnabled();
    event RevokeMintEnabled();
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event TaxFeeUpdated(uint256 newFee);
    event MarketingWalletUpdated(address newWallet);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor(
        string memory name,
        string memory symbol,
        string memory initialURI,
        uint256 totalSupply,
        address initialOwner,
        bool _revokeUpdate,
        bool _revokeFreeze,
        bool _revokeMint
    ) ERC20(name, symbol) Ownable(initialOwner) {
        // Mint les tokens initiaux au créateur
        _mint(initialOwner, totalSupply);
        
        // Définir l'URI initial
        _tokenURI = initialURI;
        emit MetadataUpdated(initialURI);
        
        // Configurer les options de revoke
        revokeUpdateEnabled = _revokeUpdate;
        revokeFreezeEnabled = _revokeFreeze;
        revokeMintEnabled = _revokeMint;
        
        if (_revokeUpdate) {
            emit RevokeUpdateEnabled();
        }
        if (_revokeFreeze) {
            emit RevokeFreezeEnabled();
        }
        if (_revokeMint) {
            emit RevokeMintEnabled();
        }
    }

    /**
     * @dev Mettre à jour les métadonnées (seulement si revokeUpdateEnabled = false)
     */
    function updateMetadata(string memory newURI) public onlyOwner {
        require(!revokeUpdateEnabled, "ERC20Token: Update has been revoked");
        _tokenURI = newURI;
        emit MetadataUpdated(newURI);
    }

    /**
     * @dev Activer revoke update (irréversible)
     */
    function enableRevokeUpdate() public onlyOwner {
        require(!revokeUpdateEnabled, "ERC20Token: Already revoked");
        revokeUpdateEnabled = true;
        emit RevokeUpdateEnabled();
    }

    /**
     * @dev Activer revoke freeze (irréversible)
     */
    function enableRevokeFreeze() public onlyOwner {
        require(!revokeFreezeEnabled, "ERC20Token: Already revoked");
        revokeFreezeEnabled = true;
        emit RevokeFreezeEnabled();
    }

    /**
     * @dev Activer revoke mint (irréversible)
     */
    function enableRevokeMint() public onlyOwner {
        require(!revokeMintEnabled, "ERC20Token: Already revoked");
        revokeMintEnabled = true;
        emit RevokeMintEnabled();
    }

    /**
     * @dev Mint de nouveaux tokens (seulement si revokeMintEnabled = false)
     */
    function mint(address to, uint256 amount) public onlyOwner {
        require(!revokeMintEnabled, "ERC20Token: Minting has been revoked");
        _mint(to, amount);
    }

    /**
     * @dev Pause le token globalement (seulement si revokeFreezeEnabled = false)
     * Utiliser blacklist() pour geler des comptes spécifiques.
     */
    function pause() public onlyOwner {
        require(!revokeFreezeEnabled, "ERC20Token: Freezing has been revoked");
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /// @dev Block `renounceOwnership` while the contract is paused. Without
    ///      this guard, a compromised owner could pause then renounce in two
    ///      tx, permanently freezing all transfers with no recovery path
    ///      (Sentinelle HIGH SC10 pattern on the AutoLiquidity variant —
    ///      applied here for parity). Owner must call `unpause()` first.
    function renounceOwnership() public virtual override onlyOwner {
        require(!paused(), "ERC20Token: cannot renounce while paused");
        super.renounceOwnership();
    }

    /**
     * @dev Gère la blacklist d'un compte
     */
    function blacklist(address account, bool value) external onlyOwner {
        // Freeze-revocation immutability (INV-7): once freezing is revoked the
        // owner can no longer FREEZE individual accounts, mirroring the global
        // `pause()` guard (Sentinelle F-107). Un-freezing (value=false) stays
        // allowed so already-frozen accounts can still be released.
        if (value) require(!revokeFreezeEnabled, "ERC20Token: Freezing has been revoked");
        // Never blacklist the zero address — it is the from/to of mint/burn, so
        // blacklisting it would brick minting and burning (Sentinelle F-7).
        require(account != address(0), "ERC20Token: zero address");
        isBlacklisted[account] = value;
        emit BlacklistUpdated(account, value);
    }

    /**
     * @dev Définit les frais de taxe (en basis points, max 25%)
     */
    function setTaxFee(uint256 newFee) external onlyOwner {
        require(newFee <= 2500, "ERC20Token: Fee cannot exceed 25%");
        taxFee = newFee;
        emit TaxFeeUpdated(newFee);
    }

    /**
     * @dev Définit le wallet marketing pour recevoir les frais
     */
    function setMarketingWallet(address newWallet) external onlyOwner {
        marketingWallet = newWallet;
        emit MarketingWalletUpdated(newWallet);
    }

    /**
     * @dev Withdraw accumulated tax fees to marketing wallet (or owner if
     *      marketingWallet is unset). Uses the tracked `accumulatedTaxFees`
     *      counter rather than `balanceOf(this)` so tokens accidentally sent
     *      to this contract are NOT swept here. Recover those via off-chain
     *      ops only (Sentinelle HIGH SC02 2026-05-22).
     */
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedTaxFees;
        require(amount > 0, "No fees to withdraw");
        accumulatedTaxFees = 0;
        address recipient = marketingWallet != address(0) ? marketingWallet : owner();
        emit FeesWithdrawn(recipient, amount);
        _transfer(address(this), recipient, amount);
    }

    /**
     * @dev Récupérer l'URI des métadonnées
     */
    function tokenURI() public view returns (string memory) {
        return _tokenURI;
    }

    // Override required by Solidity to implement custom logic
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        // Check blacklist
        require(!isBlacklisted[from] && !isBlacklisted[to], "ERC20Token: Account is blacklisted");

        // Tax Logic: Apply fee if configured and not an owner/internal transfer
        uint256 finalValue = value;
        if (taxFee > 0 && from != address(0) && to != address(0) && from != owner() && to != owner() && from != address(this)) {
            uint256 feeAmount = (value * taxFee) / 10000;
            if (feeAmount > 0) {
                // Send fee to contract address to be withdrawn later
                super._update(from, address(this), feeAmount);
                accumulatedTaxFees += feeAmount;
                finalValue = value - feeAmount;
            }
        }

        super._update(from, to, finalValue);
    }
}
