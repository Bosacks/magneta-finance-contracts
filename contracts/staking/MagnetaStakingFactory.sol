// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable }              from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard }      from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
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
contract MagnetaStakingFactory is Ownable, ReentrancyGuard {
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
    ) external payable nonReentrant returns (address pool) {
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
}
