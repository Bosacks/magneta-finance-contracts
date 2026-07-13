// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// ⚠️ NOT FOR PRODUCTION ⚠️
///
/// MagnetaETF is V1.1+ scope — ETF basket is outside V1 launch.
/// Sentinelle Multi-AI 2026-05-22 returned CAUTION 52/100 with:
///   - HIGH SC02 ACC-1: mint(), redeem(), previewMint(), previewRedeem()
///     all use `balanceOf(address(this))` for exchange-rate pricing,
///     making them trivially manipulable via direct ERC20 donations
///     (Venus Protocol March 2026 $2M+ pattern).
///   - MEDIUM SC08: read-only reentrancy on previewRedeem (callable
///     during ERC4626-style integrator callbacks).
/// Replace balanceOf with per-component internal accounting and add
/// read-only-reentrancy guards on preview functions before any
/// production deployment.

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MagnetaETF
 * @dev On-chain ETF (Exchange-Traded Fund) — an ERC-20 token backed by a
 *      basket of underlying ERC-20 assets held in this contract's vault.
 *
 *      Features:
 *      - Configurable asset basket with target weights (basis points)
 *      - Two bootstrap modes: Creator (owner funds first) or Community (first minter funds)
 *      - Proportional mint/redeem against the vault
 *      - Rugpull protection: time-lock on creator redemptions
 *      - Rebalancing: owner can update target weights (manual / weekly / monthly)
 *      - Optional ETF closure with proportional asset distribution
 */
contract MagnetaETF is ERC20, ERC20Burnable, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ── Types ────────────────────────────────────────────────────────────

    struct Asset {
        address token;         // ERC-20 address
        uint16  targetWeight;  // basis points (10000 = 100%)
    }

    enum BootstrapMode      { Creator, Community }
    enum RebalanceFrequency { Manual, Weekly, Monthly }

    // ── State ────────────────────────────────────────────────────────────

    Asset[] private _assets;

    BootstrapMode       public bootstrapMode;
    RebalanceFrequency  public rebalanceFrequency;

    uint8   private _decimals;
    uint256 public  initialSupply;

    bool    public  isBootstrapped;
    bool    public  isClosed;
    bool    public  closeEnabled;

    uint256 public  lockEndTime;        // 0 = none, type(uint256).max = permanent
    uint256 public  lastRebalanceTime;
    address public  immutable creator;

    // ── Timelock ─────────────────────────────────────────────────────────

    uint256 public constant TIMELOCK_WEIGHTS  = 24 hours;
    uint256 public constant TIMELOCK_CLOSE    = 48 hours;

    /// @dev Maps action hash → timestamp when it becomes executable (0 = not queued)
    mapping(bytes32 => uint256) public pendingActions;

    // ── Events ───────────────────────────────────────────────────────────

    event Bootstrapped(address indexed depositor, uint256 etfAmount);
    event Minted(address indexed user, uint256 etfAmount);
    event Redeemed(address indexed user, uint256 etfAmount);
    event WeightsUpdated(uint16[] newWeights);
    event RebalanceExecuted(uint256 timestamp);
    event ETFClosed(address indexed closer);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionExecuted(bytes32 indexed actionId);
    event ActionCancelled(bytes32 indexed actionId);

    // ── Constructor ──────────────────────────────────────────────────────

    constructor(
        string memory   name_,
        string memory   symbol_,
        uint8           decimals_,
        uint256         totalSupply_,
        address         creator_,
        Asset[] memory  assets_,
        BootstrapMode       bootstrapMode_,
        uint256             lockDuration_,
        RebalanceFrequency  rebalanceFrequency_,
        bool                closeEnabled_
    ) ERC20(name_, symbol_) Ownable(creator_) {
        require(assets_.length >= 2,  "MagnetaETF: need >= 2 assets");
        require(assets_.length <= 20, "MagnetaETF: max 20 assets");
        require(totalSupply_ > 0,     "MagnetaETF: zero supply");

        uint256 totalWeight;
        for (uint256 i = 0; i < assets_.length; i++) {
            require(assets_[i].token != address(0), "MagnetaETF: zero address");
            require(assets_[i].targetWeight > 0,    "MagnetaETF: zero weight");

            for (uint256 j = 0; j < i; j++) {
                require(assets_[i].token != assets_[j].token, "MagnetaETF: duplicate");
            }

            _assets.push(assets_[i]);
            totalWeight += assets_[i].targetWeight;
        }
        require(totalWeight == 10000, "MagnetaETF: weights != 10000");

        _decimals          = decimals_;
        initialSupply      = totalSupply_;
        creator            = creator_;
        bootstrapMode      = bootstrapMode_;
        rebalanceFrequency = rebalanceFrequency_;
        closeEnabled       = closeEnabled_;
        lastRebalanceTime  = block.timestamp;

        if (lockDuration_ == type(uint256).max) {
            lockEndTime = type(uint256).max;
        } else if (lockDuration_ > 0) {
            lockEndTime = block.timestamp + lockDuration_;
        }
    }

    // ── ERC-20 override ──────────────────────────────────────────────────

    function decimals() public view override returns (uint8) {
        return _decimals;
    }


    function _update(address from, address to, uint256 value) internal override {
        if (from == creator && to != address(0) && lockEndTime > 0 && block.timestamp < lockEndTime) {
            revert("MagnetaETF: creator transfer locked");
        }
        super._update(from, to, value);
    }

    // ── Bootstrap ────────────────────────────────────────────────────────

    /**
     * @dev Initial deposit that capitalises the vault and mints `initialSupply`
     *      ETF tokens to the depositor.
     *      - Creator mode  → only the owner may call.
     *      - Community mode → anyone may call (first depositor becomes initial holder).
     * @param amounts Array of token amounts matching `_assets` order.
     */
    function bootstrap(uint256[] calldata amounts) external nonReentrant whenNotPaused {
        require(!isBootstrapped, "MagnetaETF: already bootstrapped");

        if (bootstrapMode == BootstrapMode.Creator) {
            require(msg.sender == owner(), "MagnetaETF: only creator");
        }

        require(amounts.length == _assets.length, "MagnetaETF: length mismatch");

        for (uint256 i = 0; i < _assets.length; i++) {
            require(amounts[i] > 0, "MagnetaETF: zero amount");
            IERC20(_assets[i].token).safeTransferFrom(msg.sender, address(this), amounts[i]);
        }

        _mint(msg.sender, initialSupply);
        isBootstrapped = true;

        emit Bootstrapped(msg.sender, initialSupply);
    }

    // ── Mint ─────────────────────────────────────────────────────────────

    /**
     * @dev Mint new ETF tokens by depositing underlying assets proportionally
     *      to the current vault composition.
     * @param etfAmount Number of ETF tokens to mint.
     */
    function mint(uint256 etfAmount) external nonReentrant whenNotPaused {
        require(isBootstrapped, "MagnetaETF: not bootstrapped");
        require(!isClosed,      "MagnetaETF: closed");
        require(etfAmount > 0,  "MagnetaETF: zero amount");

        uint256 supply = totalSupply();
        require(supply > 0, "MagnetaETF: empty pool");

        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 vaultBalance = IERC20(_assets[i].token).balanceOf(address(this));
            // Round up so the vault is never underfunded
            uint256 required = (etfAmount * vaultBalance + supply - 1) / supply;
            require(required > 0, "MagnetaETF: deposit too small");
            IERC20(_assets[i].token).safeTransferFrom(msg.sender, address(this), required);
        }

        _mint(msg.sender, etfAmount);
        emit Minted(msg.sender, etfAmount);
    }

    /**
     * @dev Preview how many underlying tokens are needed to mint `etfAmount`.
     */
    function previewMint(uint256 etfAmount) external view returns (uint256[] memory required) {
        uint256 supply = totalSupply();
        required = new uint256[](_assets.length);
        if (supply == 0) return required;

        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 vaultBalance = IERC20(_assets[i].token).balanceOf(address(this));
            required[i] = (etfAmount * vaultBalance + supply - 1) / supply;
        }
    }

    // ── Redeem ───────────────────────────────────────────────────────────

    /**
     * @dev Burn ETF tokens and receive proportional underlying assets.
     *      The owner cannot redeem while the lock is active (rugpull protection).
     * @param etfAmount Number of ETF tokens to redeem.
     */
    function redeem(uint256 etfAmount) external nonReentrant whenNotPaused {
        require(etfAmount > 0,                         "MagnetaETF: zero amount");
        require(balanceOf(msg.sender) >= etfAmount,    "MagnetaETF: insufficient balance");

        // Rugpull protection: lock applies only to the owner
        if (msg.sender == creator && lockEndTime > 0) {
            require(block.timestamp >= lockEndTime, "MagnetaETF: locked");
        }

        uint256 supply = totalSupply();

        // Burn first (Checks-Effects-Interactions)
        _burn(msg.sender, etfAmount);

        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 vaultBalance = IERC20(_assets[i].token).balanceOf(address(this));
            // Round down — vault keeps any dust
            uint256 amount = (etfAmount * vaultBalance) / supply;
            if (amount > 0) {
                IERC20(_assets[i].token).safeTransfer(msg.sender, amount);
            }
        }

        emit Redeemed(msg.sender, etfAmount);
    }

    /**
     * @dev Preview how many underlying tokens are returned for `etfAmount`.
     */
    function previewRedeem(uint256 etfAmount) external view returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        amounts = new uint256[](_assets.length);
        if (supply == 0) return amounts;

        for (uint256 i = 0; i < _assets.length; i++) {
            uint256 vaultBalance = IERC20(_assets[i].token).balanceOf(address(this));
            amounts[i] = (etfAmount * vaultBalance) / supply;
        }
    }

    // ── Rebalancing ──────────────────────────────────────────────────────

    /**
     * @dev Queue a weight update. The new weights will be executable after
     *      TIMELOCK_WEIGHTS (24 h). This gives holders time to exit if they
     *      disagree with the rebalance.
     */
    function queueUpdateWeights(uint16[] calldata newWeights) external onlyOwner {
        require(!isClosed, "MagnetaETF: closed");
        require(newWeights.length == _assets.length, "MagnetaETF: length mismatch");

        // Validate weights up front so a bad payload cannot be queued
        uint256 totalWeight;
        for (uint256 i = 0; i < newWeights.length; i++) {
            require(newWeights[i] > 0, "MagnetaETF: zero weight");
            totalWeight += newWeights[i];
        }
        require(totalWeight == 10000, "MagnetaETF: weights != 10000");

        bytes32 actionId = keccak256(abi.encode("updateWeights", newWeights));
        uint256 executeAfter = block.timestamp + TIMELOCK_WEIGHTS;
        pendingActions[actionId] = executeAfter;

        emit ActionQueued(actionId, executeAfter);
    }

    /**
     * @dev Execute a previously queued weight update once the timelock has
     *      elapsed. Also enforces the rebalance frequency constraint.
     */
    function executeUpdateWeights(uint16[] calldata newWeights) external onlyOwner {
        require(!isClosed, "MagnetaETF: closed");

        bytes32 actionId = keccak256(abi.encode("updateWeights", newWeights));
        uint256 executeAfter = pendingActions[actionId];
        require(executeAfter != 0,                "MagnetaETF: not queued");
        require(block.timestamp >= executeAfter,  "MagnetaETF: timelock active");

        // Enforce rebalance cadence
        if (rebalanceFrequency == RebalanceFrequency.Weekly) {
            require(block.timestamp >= lastRebalanceTime + 7 days, "MagnetaETF: too soon");
        } else if (rebalanceFrequency == RebalanceFrequency.Monthly) {
            require(block.timestamp >= lastRebalanceTime + 30 days, "MagnetaETF: too soon");
        }

        // Clear pending action before state mutation
        delete pendingActions[actionId];

        // Apply weights (already validated at queue time, but re-check length)
        require(newWeights.length == _assets.length, "MagnetaETF: length mismatch");
        for (uint256 i = 0; i < newWeights.length; i++) {
            _assets[i].targetWeight = newWeights[i];
        }

        lastRebalanceTime = block.timestamp;

        emit ActionExecuted(actionId);
        emit WeightsUpdated(newWeights);
        emit RebalanceExecuted(block.timestamp);
    }

    // ── Closure ──────────────────────────────────────────────────────────

    /**
     * @dev Queue ETF closure. Executable after TIMELOCK_CLOSE (48 h).
     *      Gives holders time to redeem before the ETF is frozen.
     */
    function queueCloseETF() external onlyOwner {
        require(closeEnabled, "MagnetaETF: closure disabled");
        require(!isClosed,    "MagnetaETF: already closed");

        bytes32 actionId = keccak256(abi.encode("closeETF"));
        uint256 executeAfter = block.timestamp + TIMELOCK_CLOSE;
        pendingActions[actionId] = executeAfter;

        emit ActionQueued(actionId, executeAfter);
    }

    /**
     * @dev Execute a previously queued ETF closure.
     */
    function executeCloseETF() external onlyOwner {
        require(closeEnabled, "MagnetaETF: closure disabled");
        require(!isClosed,    "MagnetaETF: already closed");

        bytes32 actionId = keccak256(abi.encode("closeETF"));
        uint256 executeAfter = pendingActions[actionId];
        require(executeAfter != 0,                "MagnetaETF: not queued");
        require(block.timestamp >= executeAfter,  "MagnetaETF: timelock active");

        delete pendingActions[actionId];

        isClosed = true;

        emit ActionExecuted(actionId);
        emit ETFClosed(msg.sender);
    }

    // ── Cancel queued action ─────────────────────────────────────────────

    /**
     * @dev Cancel any queued timelock action. Allows the owner to abort a
     *      queued weight change or closure if circumstances change.
     */
    function cancelAction(bytes32 actionId) external onlyOwner {
        require(pendingActions[actionId] != 0, "MagnetaETF: not queued");
        delete pendingActions[actionId];
        emit ActionCancelled(actionId);
    }

    // ── Pause (emergency — NO timelock) ──────────────────────────────────

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    // ── View helpers ─────────────────────────────────────────────────────

    function getAssetCount() external view returns (uint256) {
        return _assets.length;
    }

    function getAsset(uint256 index)
        external view
        returns (address token, uint16 targetWeight, uint256 vaultBalance)
    {
        require(index < _assets.length, "MagnetaETF: out of bounds");
        Asset storage a = _assets[index];
        return (a.token, a.targetWeight, IERC20(a.token).balanceOf(address(this)));
    }

    function getAllAssets() external view returns (Asset[] memory) {
        return _assets;
    }

    function getVaultBalances() external view returns (uint256[] memory balances) {
        balances = new uint256[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            balances[i] = IERC20(_assets[i].token).balanceOf(address(this));
        }
    }

    function isLocked() external view returns (bool) {
        if (lockEndTime == 0) return false;
        return block.timestamp < lockEndTime;
    }

    function getLockEndTime() external view returns (uint256) {
        return lockEndTime;
    }
}
