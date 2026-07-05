// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// ⚠️ NOT FOR PRODUCTION ⚠️
///
/// MagnetaStakingFactory is V1.1+ scope — staking is outside V1 launch.
/// Sentinelle Multi-AI 2026-05-22 returned CAUTION 62/100 with:
///   - MEDIUM SC05 FACT-2: createPool() lacks zero-address validation
///     on stakingToken and rewardsToken, can produce permanently
///     bricked pools.
/// Add createPool input validation and transfer ownership to a Safe
/// before any production use.

import { Ownable2Step }         from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard }      from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Pausable }             from "@openzeppelin/contracts/security/Pausable.sol";
import { MagnetaStakingRewards } from "./MagnetaStakingRewards.sol";

/**
 * @title MagnetaStakingFactory
 * @notice Permissionless factory for `MagnetaStakingRewards` pools.
 *         Anyone can deploy a staking pool for any (stakingToken, rewardsToken)
 *         pair. The deployer becomes the pool's owner — they are responsible
 *         for funding rewards via `notifyRewardAmount`.
 *
 *         The factory pays a small per-deploy fee (`createFee`, default 0)
 *         to `feeVault`. V1 ships at zero so anyone can spin up a pool; the
 *         operator can flip the fee on later via `setCreateFee`.
 *
 *         Bookkeeping: `userPools[creator]` and `allPools[]` so the frontend
 *         can list the user's pools and an explorer-side global feed.
 */
contract MagnetaStakingFactory is Ownable2Step, ReentrancyGuard, Pausable {
    /// @notice Magneta FeeVault — receives `createFee` per pool created.
    address public feeVault;

    /// @notice Per-pool creation fee in native wei. Default 0.
    uint256 public createFee;

    /// @notice Per-creator list of pools deployed by them.
    mapping(address => address[]) public userPools;

    /// @notice Flat list of every pool created, in deploy order.
    address[] public allPools;

    event StakingPoolCreated(
        address indexed creator,
        address indexed pool,
        address indexed stakingToken,
        address rewardsToken
    );
    event CreateFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeVaultUpdated(address oldVault, address newVault);
    event PauserAdded(address indexed account);
    event PauserRemoved(address indexed account);

    /// @notice Multi-pauser set. Any address with isPauser[addr] == true may
    ///         call {pause}. UNPAUSE remains owner-only.
    mapping(address => bool) public isPauser;

    modifier onlyOwnerOrPauser() {
        require(
            msg.sender == owner() || isPauser[msg.sender],
            "MagnetaStakingFactory: not owner or pauser"
        );
        _;
    }

    constructor(address _feeVault, address initialOwner) {
        require(_feeVault != address(0) && initialOwner != address(0), "zero address");
        feeVault = _feeVault;
        if (initialOwner != msg.sender) {
            _transferOwnership(initialOwner);
        }
    }

    function setCreateFee(uint256 _createFee) external onlyOwner {
        emit CreateFeeUpdated(createFee, _createFee);
        createFee = _createFee;
    }

    function setFeeVault(address _feeVault) external onlyOwner {
        require(_feeVault != address(0), "zero vault");
        emit FeeVaultUpdated(feeVault, _feeVault);
        feeVault = _feeVault;
    }

    /**
     * @notice Deploy a new staking pool. The caller pays `createFee` in native
     *         (msg.value), which is forwarded to `feeVault`. Excess refunded.
     *         The new pool is owned by msg.sender — they fund rewards directly.
     */
    function createStakingPool(
        address stakingToken,
        address rewardsToken
    ) external payable nonReentrant whenNotPaused returns (address pool) {
        require(msg.value >= createFee, "insufficient fee");

        MagnetaStakingRewards p = new MagnetaStakingRewards(
            msg.sender,        // pool owner = creator
            stakingToken,
            rewardsToken
        );
        pool = address(p);

        userPools[msg.sender].push(pool);
        allPools.push(pool);

        // Forward fee + refund excess
        if (createFee > 0) {
            (bool ok, ) = payable(feeVault).call{value: createFee}("");
            require(ok, "fee transfer failed");
        }
        uint256 refund = msg.value - createFee;
        if (refund > 0) {
            (bool ok2, ) = payable(msg.sender).call{value: refund}("");
            require(ok2, "refund failed");
        }

        emit StakingPoolCreated(msg.sender, pool, stakingToken, rewardsToken);
    }

    // ─── Views ────────────────────────────────────────────────────────────

    function getUserPools(address user) external view returns (address[] memory) {
        return userPools[user];
    }

    function getPoolCount() external view returns (uint256) {
        return allPools.length;
    }

    // ─── Emergency pause ──────────────────────────────────────────────────

    /// @notice Pause new pool creation. Does not affect any already-deployed
    ///         `MagnetaStakingRewards` pool — each is independently owned and
    ///         paused (see that contract's own pause controls).
    function pause() external onlyOwnerOrPauser {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Grant an address the pauser role. Owner-only.
    function addPauser(address account) public onlyOwner {
        require(account != address(0), "MagnetaStakingFactory: zero pauser");
        isPauser[account] = true;
        emit PauserAdded(account);
    }

    /// @notice Revoke an address's pauser role. Owner-only.
    function removePauser(address account) external onlyOwner {
        require(account != address(0), "MagnetaStakingFactory: zero pauser");
        isPauser[account] = false;
        emit PauserRemoved(account);
    }
}
