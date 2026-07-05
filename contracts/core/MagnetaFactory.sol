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
    function removePauser(address account) external onlyOwner {
        require(account != address(0), "MagnetaFactory: zero pauser");
        isPauser[account] = false;
        emit PauserRemoved(account);
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
