// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20Pausable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MagnetaERC20OFT
/// @notice Magneta's standard token, OFT-compatible. Same feature set as the
///         legacy ERC20Token (revoke flags, blacklist, tax, marketing wallet,
///         metadata URI, pause) but bridgeable cross-chain via LayerZero V2 OFT
///         (mint/burn pattern — no liquidity pool required).
///
///         Ownership model: single-step Ownable inherited from OApp/OFT.
///         The owner is also the LayerZero "delegate" (can setPeer, setConfig,
///         etc.) — same person controls token admin and cross-chain config.
///         This is a deliberate departure from the legacy Ownable2Step pattern
///         because LZ peer wiring in a 19-chain mesh would otherwise require
///         342 acceptOwnership calls per token launch.
contract MagnetaERC20OFT is OFT, ERC20Burnable, ERC20Pausable {
    // ─── Revoke flags (one-way switches) ────────────────────────────────────

    bool public revokeUpdateEnabled;
    bool public revokeFreezeEnabled;
    bool public revokeMintEnabled;

    // ─── Token metadata + admin features ────────────────────────────────────

    string private _tokenURI;
    mapping(address => bool) public isBlacklisted;
    uint256 public taxFee;            // basis points (100 = 1%, capped at 25%)
    address public marketingWallet;

    // ─── Auto Freeze (Sprint 8) — permissionless sniper guard ──────────────
    //
    // The token owner sets a threshold; any caller can then invoke
    // `autoFreeze(buyer, amount)` on the contract to blacklist `buyer` IF
    // the on-chain conditions are met. The Magneta off-chain listener
    // watches `Transfer` events and calls this from the Magneta relayer
    // wallet when a buyer crosses the configured threshold — no user
    // private key is ever held server-side.
    //
    // Invariants:
    //   - Only the owner can configure rules (`setAutoFreezeRule`,
    //     `setAutoFreezeWhitelist`).
    //   - `autoFreeze` is permissionless and reverts unless rule.active +
    //     amount >= threshold + buyer not whitelisted + freeze not revoked.
    //   - Once `enableRevokeFreeze()` is called, `autoFreeze` reverts
    //     irreversibly (matches the semantics of `pause`/`blacklist` post-
    //     revoke).
    struct AutoFreezeRule {
        bool    active;
        uint256 threshold;        // in raw token units (10**decimals scaled)
        uint64  configuredAt;     // block timestamp at last setAutoFreezeRule
    }

    AutoFreezeRule public autoFreezeRule;
    mapping(address => bool) public isAutoFreezeWhitelisted;

    /// @notice Time window after `setAutoFreezeRule` during which `autoFreeze`
    ///         can fire. After this window, autoFreeze auto-disarms — the
    ///         owner must call `setAutoFreezeRule` again to re-arm. Defends
    ///         against the grief vector where any whale who crosses the
    ///         threshold weeks/months after launch can be permanently
    ///         blacklisted by any caller. Default 1 hour, capped at 7 days.
    uint256 public autoFreezeWindowSeconds = 1 hours;

    /// @notice Hard cap on `setAutoFreezeWhitelist` batch to bound gas usage.
    uint256 public constant AUTO_FREEZE_WHITELIST_BATCH_MAX = 200;

    // ─── Tax fee timelock (Sentinelle hardening) ───────────────────────────
    //
    // Tax fee INCREASES require a propose → apply flow with a block delay
    // to prevent the owner from front-running large trades by spiking
    // the fee instantly. DECREASES are still applied immediately because
    // they are strictly user-favourable.
    uint256 public constant TAX_FEE_INCREASE_DELAY_BLOCKS = 100; // ~20 min on Ethereum
    uint256 public pendingTaxFee;
    uint256 public pendingTaxFeeBlock;

    /// @notice Accumulated tax fees pulled into the contract by `_update`,
    ///         tracked separately from `balanceOf(address(this))` so that
    ///         tokens accidentally sent to the contract are not silently
    ///         routed to the marketing wallet by `withdrawFees`.
    uint256 public accumulatedTaxFees;

    // ─── Operator role (Sprint 9.5) — TokenOpsModule integration ───────────
    //
    // The creator owns the token (via Ownable) and can call every
    // management function directly. The Magneta `TokenOpsModule` is a
    // separate operator that can ALSO call mint/blacklist/updateMetadata/
    // enableRevoke* — this is what lets the Sprint 7 SDK collect a USDC fee
    // for ops dispatched via Gateway.executeOperation.
    //
    // Set once at construction by the OFT factory (which knows the local
    // TokenOpsModule address). The creator can later re-bind it via
    // `setTokenOpsModule(address)` — useful if Magneta migrates modules.
    // Setting it to address(0) effectively disables the module path,
    // leaving the creator as the sole authorized actor.
    address public tokenOpsModule;

    // ─── Events ─────────────────────────────────────────────────────────────

    event MetadataUpdated(string newURI);
    event RevokeUpdateEnabled();
    event RevokeFreezeEnabled();
    event RevokeMintEnabled();
    event BlacklistUpdated(address indexed account, bool isBlacklisted);
    event TaxFeeUpdated(uint256 newFee);
    event MarketingWalletUpdated(address newWallet);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event AutoFreezeRuleUpdated(bool active, uint256 threshold);
    event AutoFreezeWhitelistUpdated(address indexed account, bool isWhitelisted);
    event AutoFreezeTriggered(address indexed buyer, uint256 buyAmount, address indexed by);
    event AutoFreezeWindowUpdated(uint256 newWindowSeconds);
    event TokenOpsModuleUpdated(address indexed previous, address indexed current);
    event TaxFeeProposed(uint256 newFee, uint256 applyBlock);

    /// @param name_           ERC20 name
    /// @param symbol_         ERC20 symbol
    /// @param initialURI      Initial metadata URI (e.g. ipfs://...)
    /// @param totalSupply_    Tokens minted to `initialOwner` at construction (in token units, i.e. * 10**18)
    /// @param initialOwner    Token admin + LayerZero delegate
    /// @param _revokeUpdate   Lock metadata updates from day 1
    /// @param _revokeFreeze   Disable pause from day 1 (irreversible)
    /// @param _revokeMint     Disable additional minting from day 1 (irreversible)
    /// @param _lzEndpoint     LayerZero V2 endpoint address for the chain (see chainConfig.ts)
    /// @param _tokenOpsModule TokenOpsModule address that gets operator privileges
    ///                        (mint/blacklist/updateMetadata/enableRevoke*).
    ///                        May be address(0) on construction; owner can set later.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory initialURI,
        uint256 totalSupply_,
        address initialOwner,
        bool _revokeUpdate,
        bool _revokeFreeze,
        bool _revokeMint,
        address _lzEndpoint,
        address _tokenOpsModule
    )
        OFT(name_, symbol_, _lzEndpoint, initialOwner)
        Ownable(initialOwner)
    {
        if (totalSupply_ > 0) {
            _mint(initialOwner, totalSupply_);
        }

        _tokenURI = initialURI;
        emit MetadataUpdated(initialURI);

        revokeUpdateEnabled = _revokeUpdate;
        revokeFreezeEnabled = _revokeFreeze;
        revokeMintEnabled   = _revokeMint;

        if (_revokeUpdate) emit RevokeUpdateEnabled();
        if (_revokeFreeze) emit RevokeFreezeEnabled();
        if (_revokeMint)   emit RevokeMintEnabled();

        if (_tokenOpsModule != address(0)) {
            tokenOpsModule = _tokenOpsModule;
            emit TokenOpsModuleUpdated(address(0), _tokenOpsModule);
        }
    }

    /// @notice Authorizes both the creator (owner) and the bound TokenOpsModule
    ///         to call management functions. The module path lets Magneta
    ///         charge a USDC fee per op via the Gateway flow; the direct path
    ///         keeps the creator sovereign — they can mint/blacklist/etc.
    ///         without paying a Magneta fee or routing through any module.
    modifier onlyOwnerOrOpsModule() {
        require(
            msg.sender == owner() ||
            (tokenOpsModule != address(0) && msg.sender == tokenOpsModule),
            "MagnetaERC20OFT: not authorized"
        );
        _;
    }

    /// @notice Re-bind the TokenOpsModule address. Owner-only — used if
    ///         Magneta migrates modules or the creator wants to revoke the
    ///         module path entirely (set to address(0)).
    function setTokenOpsModule(address newModule) external onlyOwner {
        emit TokenOpsModuleUpdated(tokenOpsModule, newModule);
        tokenOpsModule = newModule;
    }

    // ─── Admin: metadata + revoke switches ──────────────────────────────────

    function updateMetadata(string memory newURI) external onlyOwnerOrOpsModule {
        require(!revokeUpdateEnabled, "MagnetaERC20OFT: update revoked");
        _tokenURI = newURI;
        emit MetadataUpdated(newURI);
    }

    function enableRevokeUpdate() external onlyOwnerOrOpsModule {
        require(!revokeUpdateEnabled, "MagnetaERC20OFT: already revoked");
        revokeUpdateEnabled = true;
        emit RevokeUpdateEnabled();
    }

    function enableRevokeFreeze() external onlyOwnerOrOpsModule {
        require(!revokeFreezeEnabled, "MagnetaERC20OFT: already revoked");
        revokeFreezeEnabled = true;
        emit RevokeFreezeEnabled();
    }

    function enableRevokeMint() external onlyOwnerOrOpsModule {
        require(!revokeMintEnabled, "MagnetaERC20OFT: already revoked");
        revokeMintEnabled = true;
        emit RevokeMintEnabled();
    }

    function tokenURI() external view returns (string memory) {
        return _tokenURI;
    }

    // ─── Admin: mint, pause, blacklist ──────────────────────────────────────

    function mint(address to, uint256 amount) external onlyOwnerOrOpsModule {
        require(!revokeMintEnabled, "MagnetaERC20OFT: minting revoked");
        _mint(to, amount);
    }

    function pause() external onlyOwner {
        require(!revokeFreezeEnabled, "MagnetaERC20OFT: freezing revoked");
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled — renouncing ownership would permanently freeze pause,
    ///         blacklist, metadata, tax/marketing admin AND the LayerZero
    ///         delegate (setPeer/setConfig), bricking the token cross-chain.
    ///         An owner could otherwise `pause()` then `renounceOwnership()`,
    ///         locking every holder out forever (Sentinelle H-2, parity with
    ///         the F-3 fix on MagnetaERC20OFTAutoLiquidity). Transfer ownership
    ///         to a multisig instead of renouncing.
    function renounceOwnership() public override onlyOwner {
        revert("renounce disabled");
    }

    /// @notice Add or remove an account from the blacklist. After
    ///         `enableRevokeFreeze` is called, NEW blacklist entries are
    ///         rejected (the revoke guarantee covers both `pause` and
    ///         manual `blacklist`), but DE-blacklisting (`value=false`)
    ///         remains permitted as a strict relaxation.
    ///
    ///         Blacklisting `address(0)` or `address(this)` would brick
    ///         mint/burn/OFT bridge flows and the tax-fee withdrawal path —
    ///         explicitly rejected.
    function blacklist(address account, bool value) external onlyOwnerOrOpsModule {
        if (value) {
            require(!revokeFreezeEnabled, "MagnetaERC20OFT: freezing revoked");
            require(account != address(0), "MagnetaERC20OFT: zero address");
            require(account != address(this), "MagnetaERC20OFT: self");
        }
        isBlacklisted[account] = value;
        emit BlacklistUpdated(account, value);
    }

    // ─── Admin: tax + marketing wallet ──────────────────────────────────────

    /// @notice Update the transfer tax fee. DECREASES apply instantly
    ///         (strictly user-favourable). INCREASES enter a propose/apply
    ///         flow with a `TAX_FEE_INCREASE_DELAY_BLOCKS` delay so the
    ///         owner cannot front-run large pending trades by spiking
    ///         the fee in the same mempool window. Cap remains 25%.
    function setTaxFee(uint256 newFee) external onlyOwner {
        require(newFee <= 2500, "MagnetaERC20OFT: fee > 25%");
        if (newFee <= taxFee) {
            taxFee = newFee;
            pendingTaxFee = 0;
            pendingTaxFeeBlock = 0;
            emit TaxFeeUpdated(newFee);
        } else {
            pendingTaxFee = newFee;
            pendingTaxFeeBlock = block.number + TAX_FEE_INCREASE_DELAY_BLOCKS;
            emit TaxFeeProposed(newFee, pendingTaxFeeBlock);
        }
    }

    /// @notice Activate a pending tax-fee increase after the timelock elapses.
    function applyTaxFee() external onlyOwner {
        require(pendingTaxFeeBlock > 0, "MagnetaERC20OFT: no pending fee");
        require(block.number >= pendingTaxFeeBlock, "MagnetaERC20OFT: timelock active");
        taxFee = pendingTaxFee;
        emit TaxFeeUpdated(pendingTaxFee);
        pendingTaxFee = 0;
        pendingTaxFeeBlock = 0;
    }

    function setMarketingWallet(address newWallet) external onlyOwner {
        marketingWallet = newWallet;
        emit MarketingWalletUpdated(newWallet);
    }

    /// @notice Withdraw accumulated tax fees to the marketing wallet (or
    ///         owner if the marketing wallet is unset). Uses the tracked
    ///         `accumulatedTaxFees` counter rather than `balanceOf(this)`
    ///         so tokens accidentally sent directly to the contract are
    ///         NOT swept here. Recover those via off-chain ops only.
    function withdrawFees() external onlyOwner {
        uint256 amount = accumulatedTaxFees;
        require(amount > 0, "MagnetaERC20OFT: no fees");
        accumulatedTaxFees = 0;
        address recipient = marketingWallet != address(0) ? marketingWallet : owner();
        emit FeesWithdrawn(recipient, amount);
        _transfer(address(this), recipient, amount);
    }

    // ─── Auto Freeze: rule config (owner) + permissionless trigger ──────────

    /// @notice Configure the auto-freeze rule. Only the owner can call this;
    ///         passing `active=false` disables auto-freeze without clearing
    ///         the threshold (handy for temporary deactivations).
    /// @param  active     Whether `autoFreeze` is currently armed
    /// @param  threshold  Min `buyAmount` (raw 10**decimals units) to trigger
    function setAutoFreezeRule(bool active, uint256 threshold) external onlyOwner {
        require(!revokeFreezeEnabled, "MagnetaERC20OFT: freezing revoked");
        // An active rule with threshold=0 would let anyone autoFreeze every
        // holder (including the LP pair) since every balance >= 0.
        require(!active || threshold > 0, "MagnetaERC20OFT: threshold must be > 0 when active");
        autoFreezeRule = AutoFreezeRule({
            active:        active,
            threshold:     threshold,
            configuredAt:  uint64(block.timestamp)
        });
        emit AutoFreezeRuleUpdated(active, threshold);
    }

    /// @notice Adjust the time window during which `autoFreeze` may fire
    ///         after a rule is configured. Capped at 7 days to bound the
    ///         attack surface.
    function setAutoFreezeWindow(uint256 newWindowSeconds) external onlyOwner {
        require(newWindowSeconds <= 7 days, "MagnetaERC20OFT: window too long");
        autoFreezeWindowSeconds = newWindowSeconds;
        emit AutoFreezeWindowUpdated(newWindowSeconds);
    }

    /// @notice Whitelist or de-whitelist a batch of accounts. Whitelisted
    ///         buyers are immune to `autoFreeze`. Liquidity pairs, marketing
    ///         wallets, and friendly partners should be whitelisted.
    ///         Batch size is capped to bound gas usage.
    function setAutoFreezeWhitelist(address[] calldata accounts, bool value) external onlyOwner {
        require(accounts.length <= AUTO_FREEZE_WHITELIST_BATCH_MAX, "MagnetaERC20OFT: batch too large");
        for (uint256 i; i < accounts.length; ++i) {
            isAutoFreezeWhitelisted[accounts[i]] = value;
            emit AutoFreezeWhitelistUpdated(accounts[i], value);
        }
    }

    /// @notice Permissionless: blacklists `buyer` if the auto-freeze rule is
    ///         active AND `buyAmount` meets the configured threshold AND
    ///         `buyer` is not whitelisted. Anyone can call this — typically
    ///         the Magneta off-chain listener observes a Transfer event and
    ///         relays the call from the Magneta relayer wallet, so no user
    ///         private key is ever stored server-side.
    /// @dev    `buyAmount` is supplied by the caller (from the observed
    ///         Transfer event) and re-checked against `balanceOf(buyer)` so
    ///         a malicious caller can't grief by passing inflated amounts.
    ///         The actual check is "buyer currently holds >= threshold" which
    ///         tolerates listener race conditions and prevents false-positives
    ///         when the buyer has already partly sold.
    function autoFreeze(address buyer, uint256 buyAmount) external {
        require(!revokeFreezeEnabled, "MagnetaERC20OFT: freezing revoked");
        AutoFreezeRule memory rule = autoFreezeRule;
        require(rule.active, "MagnetaERC20OFT: auto-freeze inactive");
        // Time-window guard: autoFreeze auto-disarms after the configured
        // window expires. Defends against the grief vector where any whale
        // crossing the threshold weeks/months after launch could be frozen
        // by any caller. Owner must re-arm via setAutoFreezeRule.
        require(
            block.timestamp <= uint256(rule.configuredAt) + autoFreezeWindowSeconds,
            "MagnetaERC20OFT: auto-freeze window expired"
        );
        require(buyer != address(0) && buyer != address(this), "MagnetaERC20OFT: invalid buyer");
        // Never freeze the owner or a CONTRACT. The DEX pair/router that holds the
        // bulk of the liquidity is a contract and crosses the threshold at launch,
        // so without this guard any caller could `autoFreeze(pair)` and blacklist
        // it — freezing all trading and LP removal (a griefing DoS). Snipers are
        // EOAs (code.length == 0), so the anti-bot purpose is preserved; a
        // contract-based sniper escaping the freeze is a far smaller harm than a
        // frozen pool. Excluding the owner protects the deployer's own holdings.
        require(buyer != owner(), "MagnetaERC20OFT: cannot freeze owner");
        require(buyer.code.length == 0, "MagnetaERC20OFT: cannot freeze contract");
        require(buyAmount >= rule.threshold, "MagnetaERC20OFT: below threshold");
        require(!isAutoFreezeWhitelisted[buyer], "MagnetaERC20OFT: whitelisted");
        require(balanceOf(buyer) >= rule.threshold, "MagnetaERC20OFT: holdings below threshold");
        require(!isBlacklisted[buyer], "MagnetaERC20OFT: already frozen");

        isBlacklisted[buyer] = true;
        emit BlacklistUpdated(buyer, true);
        emit AutoFreezeTriggered(buyer, buyAmount, msg.sender);
    }

    // ─── Hook: blacklist + tax + pause check on every transfer ──────────────

    /// @dev Three things happen on every state mutation:
    ///   1. Blacklist check (revert if either side is blacklisted)
    ///   2. Tax application (skip for mint/burn, owner, and self-transfers to
    ///      avoid taxing the fee withdrawal flow)
    ///   3. Pause check (delegated to ERC20Pausable._update via super)
    ///
    ///   OFT bridge ops trigger `_mint` / `_burn` which call `_update(0, to, x)`
    ///   or `_update(from, 0, x)` — `from == 0 || to == 0` short-circuits the
    ///   tax block, so cross-chain transfers preserve their full amount.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        require(!isBlacklisted[from] && !isBlacklisted[to], "MagnetaERC20OFT: blacklisted");

        uint256 finalValue = value;
        if (
            taxFee > 0 &&
            from != address(0) &&
            to != address(0) &&
            from != owner() &&
            to != owner() &&
            from != address(this)
        ) {
            uint256 feeAmount = (value * taxFee) / 10_000;
            if (feeAmount > 0) {
                super._update(from, address(this), feeAmount);
                accumulatedTaxFees += feeAmount;
                finalValue = value - feeAmount;
            }
        }

        super._update(from, to, finalValue);
    }
}
