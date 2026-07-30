// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./MagnetaPool.sol";
import "./MagnetaMultiPool.sol";
import "./MagnetaDLMM.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title MagnetaFactory
 * @dev Factory contract to deploy and track different types of Magneta Finance liquidity pools.
 */
contract MagnetaFactory is Ownable2Step, Pausable {
    // Registry of all deployed pools
    address[] public multiPools;
    address[] public dlmmPools;

    // Existing singleton pool manager for standard V2-style pools
    MagnetaPool public standardPoolManager;

    /// @notice Canonical human guardian (back-compat view). Kept in sync with
    ///         {isPauser} by {setPauseGuardian}. Prefer {addPauser}/{removePauser}.
    address public pauseGuardian;

    /// @notice Multi-pauser set. Any address with isPauser[addr] == true may
    ///         call {pause}. UNPAUSE remains owner-only.
    mapping(address => bool) public isPauser;

    /// @notice Upper bound for `swapFee` accepted by `createMultiPool`. The
    ///         `MagnetaMultiPool` constructor stores the fee but does not
    ///         cap it; without this check a deployer could create a pool
    ///         with a 50% or 99% swap fee that would trap LP funds
    ///         (the swap math at MagnetaMultiPool:152 uses 1e18-scaled
    ///         fees, so 1e17 = 10%).
    uint256 public constant MAX_SWAP_FEE_WAD = 1e17; // 10%

    /// @notice Upper bound for the combined `lpFeeBps + protocolFeeBps` accepted
    ///         by `createDLMMPool`. Mirrors MagnetaDLMM's own constructor cap
    ///         (`DLMM: total fee > 10%`) so a bad call fails fast at the
    ///         factory with a clear reason instead of reverting deep inside
    ///         the pool's constructor, and stays correct even if MagnetaDLMM's
    ///         internal check is ever weakened (F-14).
    uint16 public constant MAX_DLMM_TOTAL_FEE_BPS = 1000; // 10%

    /// @notice Upper bound for `binStep` accepted by `createDLMMPool`. Mirrors
    ///         MagnetaDLMM's own constructor cap (F-14).
    uint16 public constant MAX_DLMM_BIN_STEP = 500;

    /// @notice Gate for {createMultiPool}. Disabled by default so that even
    ///         after the MagnetaMultiPool reserve-accounting rework a
    ///         governance review must explicitly enable multi-pool creation
    ///         per deployment. Closes the gap where MagnetaMultiPool's header
    ///         claimed a factory-level gate that did not actually exist.
    bool public multiPoolCreationEnabled;

    event MultiPoolCreationEnabledSet(bool enabled);
    event MultiPoolCreated(address indexed pool, address[] tokens, uint256[] weights, address creator);
    event DLMMPoolCreated(address indexed pool, address tokenX, address tokenY, uint16 binStep, address creator);
    event StandardPoolCreated(uint256 indexed poolId, address token0, address token1, uint24 fee);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event PauserAdded(address indexed account);
    event PauserRemoved(address indexed account);

    modifier onlyOwnerOrPauser() {
        require(
            msg.sender == owner() || isPauser[msg.sender],
            "MagnetaFactory: not owner or pauser"
        );
        _;
    }

    constructor(address _standardPoolManager, address _owner) {
        require(_standardPoolManager != address(0), "Invalid pool manager");
        require(_owner != address(0), "Invalid owner");
        standardPoolManager = MagnetaPool(_standardPoolManager);
        _transferOwnership(_owner);
    }

    /**
     * @dev Deploys a new multi-token liquidity pool.
     */
    function createMultiPool(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory weights,
        uint256 swapFee
    ) external whenNotPaused returns (address pool) {
        require(multiPoolCreationEnabled, "MagnetaFactory: multipool creation disabled");
        // Factory-level fee cap. Token/weight invariants are enforced by
        // MagnetaMultiPool's constructor (length match, no zero/duplicate,
        // weights sum to 1e18) and we let those reverts bubble up.
        require(swapFee <= MAX_SWAP_FEE_WAD, "MagnetaFactory: swapFee too high");
        pool = address(new MagnetaMultiPool(name, symbol, tokens, weights, swapFee, msg.sender));
        multiPools.push(pool);
        emit MultiPoolCreated(pool, tokens, weights, msg.sender);
    }

    /**
     * @dev Deploys a new DLMM (Dynamic Liquidity Market Maker) pool.
     *
     * F-14: MagnetaDLMM's constructor already reverts on most of these bad
     * inputs, but that check happens after CREATE has already started
     * running, deep inside the pool's own logic. Validating here makes the
     * factory fail fast with a factory-level reason and keeps the guard in
     * place even if MagnetaDLMM's own checks are ever changed. `binStep` is
     * bounded rather than merely nonzero because MagnetaDLMM's constructor
     * itself caps it at 500 (5%) — passing it through unchecked here would
     * just move the revert one frame deeper, not remove the risk.
     * `initialActiveId` (uint24) needs no extra bound: BinHelper.getPriceFromId
     * clamps the number of steps walked from BASE_ID to MAX_STEPS internally
     * for any binId, so no value of initialActiveId can blow up gas or price
     * math.
     */
    function createDLMMPool(
        address tokenX,
        address tokenY,
        uint16 binStep,
        uint16 lpFeeBps,
        uint16 protocolFeeBps,
        uint24 initialActiveId,
        address feeRecipient
    ) external whenNotPaused returns (address pool) {
        require(tokenX != address(0) && tokenY != address(0), "MagnetaFactory: zero token");
        require(tokenX != tokenY, "MagnetaFactory: identical tokens");
        require(feeRecipient != address(0), "MagnetaFactory: zero fee recipient");
        require(binStep > 0 && binStep <= MAX_DLMM_BIN_STEP, "MagnetaFactory: binStep out of range");
        require(uint256(lpFeeBps) + protocolFeeBps <= MAX_DLMM_TOTAL_FEE_BPS, "MagnetaFactory: dlmm fee too high");
        pool = address(new MagnetaDLMM(tokenX, tokenY, binStep, lpFeeBps, protocolFeeBps, initialActiveId, msg.sender, feeRecipient));
        dlmmPools.push(pool);
        emit DLMMPoolCreated(pool, tokenX, tokenY, binStep, msg.sender);
    }

    /**
     * @dev Wrapper to create a standard pool in the existing manager.
     */
    function createStandardPool(
        address token0,
        address token1,
        uint24 fee
    ) external whenNotPaused returns (uint256 poolId) {
        // MagnetaPool.createPool enforces token0 != token1 and a valid fee
        // tier but does NOT check zero addresses — close that gap here.
        require(token0 != address(0) && token1 != address(0), "MagnetaFactory: zero token");
        poolId = standardPoolManager.createPool(token0, token1, fee);
        emit StandardPoolCreated(poolId, token0, token1, fee);
    }

    /// @notice Enable or disable {createMultiPool}. Owner-only. Kept off until
    ///         a governance review clears the reworked MagnetaMultiPool.
    function setMultiPoolCreationEnabled(bool enabled) external onlyOwner {
        multiPoolCreationEnabled = enabled;
        emit MultiPoolCreationEnabledSet(enabled);
    }

    // Emergency controls
    function pause() external onlyOwnerOrPauser {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Grant an address the pauser role. Owner-only.
    function addPauser(address account) public onlyOwner {
        require(account != address(0), "MagnetaFactory: zero pauser");
        isPauser[account] = true;
        emit PauserAdded(account);
    }

    /// @notice Revoke an address's pauser role. Owner-only.
    /// @dev Sentinelle rescan-15 F-32: if the removed account is the
    ///      canonical {pauseGuardian}, clear that view too — otherwise
    ///      monitoring reads a guardian address that can no longer pause.
    ///      Mirrors the pattern already applied in MagnetaLending.
    function removePauser(address account) external onlyOwner {
        require(account != address(0), "MagnetaFactory: zero pauser");
        isPauser[account] = false;
        emit PauserRemoved(account);
        if (account == pauseGuardian) {
            pauseGuardian = address(0);
            emit PauseGuardianUpdated(account, address(0));
        }
    }

    /// @notice Deprecated single-guardian setter, retained for back-compat.
    ///         Rotates the canonical {pauseGuardian} within {isPauser}.
    function setPauseGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "MagnetaFactory: zero guardian");
        address old = pauseGuardian;
        if (old != address(0)) {
            isPauser[old] = false;
            emit PauserRemoved(old);
        }
        pauseGuardian = _guardian;
        isPauser[_guardian] = true;
        emit PauserAdded(_guardian);
        emit PauseGuardianUpdated(old, _guardian);
    }

    /**
     * @dev Returns total counts of deployed pools.
     */
    function getPoolCounts() external view returns (uint256 multiCount, uint256 dlmmCount) {
        return (multiPools.length, dlmmPools.length);
    }
}
