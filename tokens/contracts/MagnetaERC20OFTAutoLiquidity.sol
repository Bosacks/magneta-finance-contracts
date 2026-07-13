// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Pausable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MagnetaERC20OFTAutoLiquidity
/// @notice OFT-compatible variant of `ERC20TokenAutoLiquidity`. Same 2% transfer
///         tax to a configurable treasury, same tax exemptions, same optional
///         initial liquidity burn — but the token is bridgeable cross-chain
///         via LayerZero OFT (no liquidity pool required, mint/burn pattern).
///
///         Used when the creator opts for "free token creation" (no upfront
///         create fee) — the protocol earns through the 2% transfer tax forever.
///
/// @dev    DEX COMPATIBILITY: This is a fee-on-transfer token. The 2% tax
///         debits `amount` from the sender but credits only `amount - tax`
///         to the recipient. Standard Uniswap-V2/V3 routers assume balance
///         delta equals input amount and can mis-account in `swapExactTokens
///         ForTokens` paths, producing systematic LP-drain by arbitrage bots
///         on the paired asset (WETH/USDC). Mitigation: before adding
///         liquidity, the deployer MUST call `setTaxExempt(router, true)`
///         and `setTaxExempt(pair, true)` for every DEX where this token is
///         listed. Magneta's first-party MagnetaSwap path handles this in
///         the auto-LP factory; third-party listings require manual exempt.
///         See Sentinelle finding SC02 (CVSS 7.2) for full attack pattern.
/// @dev    GOVERNANCE: The constructor wires `initialOwner` as both Ownable
///         owner AND LayerZero OFT delegate. For production deployments the
///         owner MUST be transferred to a Safe multisig immediately post-
///         deploy and the LZ delegate role assigned to a separate hardware-
///         key-secured address. The contract code does not enforce this
///         because user-deployed launchpad tokens cannot be forced to
///         multisig governance. See Sentinelle CRITICAL CVSS 9.1.
contract MagnetaERC20OFTAutoLiquidity is OFT, ERC20Burnable, ERC20Pausable {
    // ─── Tax config ─────────────────────────────────────────────────────────

    uint256 public constant TRANSFER_TAX_BPS = 200;   // 2%
    uint256 public constant BPS_DENOMINATOR  = 10_000;

    // ─── State ──────────────────────────────────────────────────────────────

    address public treasuryAddress;
    uint256 public initialLiquidityBurned;
    mapping(address => bool) public isTaxExempt;
    string private _tokenURI;

    // ─── Events ─────────────────────────────────────────────────────────────

    event MetadataUpdated(string newURI);
    event TaxCollected(address indexed from, address indexed to, uint256 taxAmount);
    event TaxExemptionUpdated(address indexed account, bool exempt);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event LiquidityBurned(uint256 amount);

    /// @param name_              ERC20 name
    /// @param symbol_            ERC20 symbol
    /// @param initialURI         Initial metadata URI
    /// @param totalSupply_       Tokens minted to `initialOwner` at construction
    /// @param initialOwner       Token admin + LayerZero delegate
    /// @param _treasuryAddress   Where the 2% tax flows
    /// @param liquidityToBurn    Tokens to immediately send to 0xdead (e.g. 50% of supply for "fair launch")
    /// @param _lzEndpoint        LayerZero V2 endpoint for the chain
    constructor(
        string memory name_,
        string memory symbol_,
        string memory initialURI,
        uint256 totalSupply_,
        address initialOwner,
        address _treasuryAddress,
        uint256 liquidityToBurn,
        address _lzEndpoint
    )
        OFT(name_, symbol_, _lzEndpoint, initialOwner)
        Ownable(initialOwner)
    {
        require(_treasuryAddress != address(0), "MagnetaERC20OFTAL: treasury 0");

        treasuryAddress = _treasuryAddress;
        _tokenURI = initialURI;

        if (totalSupply_ > 0) {
            _mint(initialOwner, totalSupply_);
        }

        // Tax exemptions BEFORE the burn so the burn itself isn't taxed
        isTaxExempt[initialOwner] = true;
        isTaxExempt[_treasuryAddress] = true;

        if (liquidityToBurn > 0) {
            // Explicit guard: the previous `liquidityToBurn <= totalSupply_`
            // bound is implicit-safe today (full supply minted to initialOwner
            // immediately above), but the invariant is fragile to constructor
            // refactors. Assert the actual balance to keep the burn correct
            // under any reorder of statements (Sentinelle INFO 2026-05-22).
            require(
                liquidityToBurn <= balanceOf(initialOwner),
                "MagnetaERC20OFTAL: burn exceeds balance"
            );
            _transfer(initialOwner, address(0xdead), liquidityToBurn);
            initialLiquidityBurned = liquidityToBurn;
            emit LiquidityBurned(liquidityToBurn);
        }

        emit MetadataUpdated(initialURI);
    }

    // ─── Hook: 2% tax + pause check on every transfer ───────────────────────

    /// @dev Skips tax for mint/burn (from == 0 || to == 0), exempt addresses
    ///      (owner, treasury, pools added via `setTaxExempt`), and OFT cross-
    ///      chain transfers (which always involve mint or burn on one side).
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Pausable)
    {
        if (from == address(0) || to == address(0) || isTaxExempt[from] || isTaxExempt[to]) {
            super._update(from, to, amount);
            return;
        }

        uint256 taxAmount = (amount * TRANSFER_TAX_BPS) / BPS_DENOMINATOR;
        uint256 transferAmount = amount - taxAmount;

        if (taxAmount > 0) {
            super._update(from, treasuryAddress, taxAmount);
            emit TaxCollected(from, to, taxAmount);
        }
        super._update(from, to, transferAmount);
    }

    // ─── Admin ──────────────────────────────────────────────────────────────

    function setTaxExempt(address account, bool exempt) external onlyOwner {
        isTaxExempt[account] = exempt;
        emit TaxExemptionUpdated(account, exempt);
    }

    function setTreasuryAddress(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "MagnetaERC20OFTAL: treasury 0");
        address old = treasuryAddress;
        // Revoke the rotated-out treasury's tax exemption so a former treasury
        // cannot keep transacting tax-free indefinitely (Sentinelle L-2, parity
        // with ERC20TokenAutoLiquidity.setTreasuryAddress). Never strip the
        // owner's own exemption (set independently in the constructor) in the
        // edge config where the treasury was pointed at the owner.
        if (old != address(0) && old != newTreasury && old != owner()) {
            isTaxExempt[old] = false;
            emit TaxExemptionUpdated(old, false);
        }
        treasuryAddress = newTreasury;
        isTaxExempt[newTreasury] = true;
        emit TaxExemptionUpdated(newTreasury, true);
        emit TreasuryUpdated(old, newTreasury);
    }

    function tokenURI() external view returns (string memory) {
        return _tokenURI;
    }

    /// @notice Update the token metadata URI. The constructor emits
    ///         `MetadataUpdated` implying mutability; this setter
    ///         honours that contract (Sentinelle LOW 2026-05-22).
    function setTokenURI(string memory newURI) external onlyOwner {
        _tokenURI = newURI;
        emit MetadataUpdated(newURI);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled — renouncing ownership would permanently freeze pause,
    ///         metadata and auto-liquidity admin (Sentinelle F-3). Transfer
    ///         ownership to a multisig instead of renouncing.
    function renounceOwnership() public override onlyOwner {
        revert("renounce disabled");
    }

    // ─── View helpers ───────────────────────────────────────────────────────

    function calculateTax(uint256 amount) external pure returns (uint256) {
        return (amount * TRANSFER_TAX_BPS) / BPS_DENOMINATOR;
    }

    function getAmountAfterTax(uint256 amount) external pure returns (uint256) {
        return amount - ((amount * TRANSFER_TAX_BPS) / BPS_DENOMINATOR);
    }
}
