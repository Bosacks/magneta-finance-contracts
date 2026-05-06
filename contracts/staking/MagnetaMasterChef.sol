// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }         from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title MagnetaMasterChef
 * @notice Multi-pool farm — single rewards token (MAG eventually) shared
 *         across N farming pools via allocation points. The classic SushiSwap
 *         MasterChef V1 design: one accumulator per pool, rewards distributed
 *         pro-rata to (allocPoint × elapsed × rewardPerSecond).
 *
 *         Owner adds pools (LP token + alloc points) and funds rewards by
 *         transferring rewards token to the contract. Stakers deposit LP
 *         tokens and claim rewards. Each pool has its own internal accountant.
 *
 *         Differences vs MasterChef V1:
 *           - Rewards rate is `rewardPerSecond` (not "rewards per block") —
 *             chain-agnostic (some chains have variable block times).
 *           - `endTime` cap so the farm has a finite lifetime — owner can
 *             extend by setting a new endTime.
 *           - massUpdatePools() callable by anyone, not just owner.
 *
 *         V1 simplification: no migrator (which was MasterChef V1's well-
 *         known weakness — owner could swap LP token mid-flight). V1.1
 *         could add a timelock + role-gated migrate path.
 */
contract MagnetaMasterChef is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct PoolInfo {
        IERC20  lpToken;          // staking LP token
        uint64  allocPoint;       // share of rewardsPerSecond
        uint64  lastRewardTime;   // last block.timestamp when accReward was updated
        uint128 accRewardPerShare;// accumulated rewards × 1e12 / totalStaked
        uint256 totalStaked;
    }

    struct UserInfo {
        uint256 amount;       // LP staked
        int256  rewardDebt;   // SushiSwap MCV1 pattern — earned() = amount * accRewardPerShare / 1e12 - rewardDebt
    }

    /// @notice Token paid out as farm rewards. Set once.
    IERC20 public immutable rewardsToken;

    /// @notice Total rewardsPerSecond shared across all pools (weighted by allocPoint).
    uint256 public rewardsPerSecond;

    /// @notice Sum of allocPoints across pools — denominator for the per-pool share.
    uint256 public totalAllocPoint;

    /// @notice Block timestamp at which farming stops. After that, accRewardPerShare
    ///         doesn't update anymore. Owner can extend with `setEndTime`.
    uint64 public endTime;

    /// @notice Per-pool config + accountant, in deploy order.
    PoolInfo[] public poolInfo;

    /// @notice Per-(pool, user) deposit + reward debt.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    event PoolAdded(uint256 indexed pid, address indexed lpToken, uint256 allocPoint);
    event PoolUpdated(uint256 indexed pid, uint256 oldAllocPoint, uint256 newAllocPoint);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardsFunded(uint256 newRewardsPerSecond, uint64 newEndTime);
    event RewardsRateUpdated(uint256 oldRate, uint256 newRate);
    event EndTimeUpdated(uint64 oldEnd, uint64 newEnd);

    constructor(
        address initialOwner,
        address _rewardsToken,
        uint256 _rewardsPerSecond,
        uint64  _endTime
    ) {
        require(_rewardsToken != address(0) && initialOwner != address(0), "zero");
        rewardsToken     = IERC20(_rewardsToken);
        rewardsPerSecond = _rewardsPerSecond;
        endTime          = _endTime;
        if (initialOwner != msg.sender) {
            _transferOwnership(initialOwner);
        }
    }

    // ─── Pool management ─────────────────────────────────────────────────

    /// @notice Add a new farm. Reverts if the same lpToken is already
    ///         added (avoid double-counting in totalAllocPoint).
    function addPool(uint64 _allocPoint, IERC20 _lpToken, bool _withUpdate) external onlyOwner {
        require(address(_lpToken) != address(0), "zero lp");
        for (uint256 i; i < poolInfo.length; i++) {
            require(address(poolInfo[i].lpToken) != address(_lpToken), "dup pool");
        }
        if (_withUpdate) massUpdatePools();
        uint64 startTime = uint64(block.timestamp > endTime ? endTime : block.timestamp);
        totalAllocPoint += _allocPoint;
        poolInfo.push(PoolInfo({
            lpToken:           _lpToken,
            allocPoint:        _allocPoint,
            lastRewardTime:    startTime,
            accRewardPerShare: 0,
            totalStaked:       0
        }));
        emit PoolAdded(poolInfo.length - 1, address(_lpToken), _allocPoint);
    }

    /// @notice Change a pool's alloc point. Always run massUpdatePools first
    ///         to settle the existing rate before swapping the share.
    function setPool(uint256 pid, uint64 _allocPoint, bool _withUpdate) external onlyOwner {
        if (_withUpdate) massUpdatePools();
        uint64 prev = poolInfo[pid].allocPoint;
        totalAllocPoint = totalAllocPoint - prev + _allocPoint;
        poolInfo[pid].allocPoint = _allocPoint;
        emit PoolUpdated(pid, prev, _allocPoint);
    }

    function setRewardsPerSecond(uint256 _rewardsPerSecond) external onlyOwner {
        massUpdatePools();
        emit RewardsRateUpdated(rewardsPerSecond, _rewardsPerSecond);
        rewardsPerSecond = _rewardsPerSecond;
    }

    function setEndTime(uint64 _endTime) external onlyOwner {
        emit EndTimeUpdated(endTime, _endTime);
        endTime = _endTime;
    }

    /// @notice Convenience for the operator: set a new schedule (rate +
    ///         endTime) in one call after transferring the budget in.
    function fundRewards(uint256 _rewardsPerSecond, uint64 _endTime) external onlyOwner {
        massUpdatePools();
        rewardsPerSecond = _rewardsPerSecond;
        endTime          = _endTime;
        emit RewardsFunded(_rewardsPerSecond, _endTime);
    }

    // ─── Views ────────────────────────────────────────────────────────────

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /// @notice Pending rewards for a user in a pool. Same math as the
    ///         on-chain accumulator but read-only.
    function pendingReward(uint256 pid, address account) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][account];
        uint256 acc = pool.accRewardPerShare;
        uint256 staked = pool.totalStaked;
        uint64  refTime = uint64(block.timestamp > endTime ? endTime : block.timestamp);
        if (refTime > pool.lastRewardTime && staked != 0 && totalAllocPoint != 0) {
            uint256 elapsed = refTime - pool.lastRewardTime;
            uint256 reward  = (elapsed * rewardsPerSecond * pool.allocPoint) / totalAllocPoint;
            acc += (reward * 1e12) / staked;
        }
        int256 owed = int256((user.amount * acc) / 1e12) - user.rewardDebt;
        return owed > 0 ? uint256(owed) : 0;
    }

    // ─── Mutators ─────────────────────────────────────────────────────────

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid; pid < length; pid++) updatePool(pid);
    }

    function updatePool(uint256 pid) public {
        PoolInfo storage pool = poolInfo[pid];
        uint64 refTime = uint64(block.timestamp > endTime ? endTime : block.timestamp);
        if (refTime <= pool.lastRewardTime) return;
        uint256 staked = pool.totalStaked;
        if (staked == 0 || totalAllocPoint == 0) {
            pool.lastRewardTime = refTime;
            return;
        }
        uint256 elapsed = refTime - pool.lastRewardTime;
        uint256 reward  = (elapsed * rewardsPerSecond * pool.allocPoint) / totalAllocPoint;
        pool.accRewardPerShare += uint128((reward * 1e12) / staked);
        pool.lastRewardTime = refTime;
    }

    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        updatePool(pid);

        // Pay out pending rewards first (Sushi-style rewardDebt math)
        if (user.amount > 0) {
            uint256 pending = uint256(int256((user.amount * pool.accRewardPerShare) / 1e12) - user.rewardDebt);
            if (pending > 0) {
                rewardsToken.safeTransfer(msg.sender, pending);
            }
        }

        if (amount > 0) {
            pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);
            user.amount       += amount;
            pool.totalStaked  += amount;
        }

        user.rewardDebt = int256((user.amount * pool.accRewardPerShare) / 1e12);
        emit Deposit(msg.sender, pid, amount);
    }

    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        require(user.amount >= amount, "withdraw > stake");

        updatePool(pid);

        uint256 pending = uint256(int256((user.amount * pool.accRewardPerShare) / 1e12) - user.rewardDebt);
        if (pending > 0) {
            rewardsToken.safeTransfer(msg.sender, pending);
        }

        if (amount > 0) {
            user.amount       -= amount;
            pool.totalStaked  -= amount;
            pool.lpToken.safeTransfer(msg.sender, amount);
        }
        user.rewardDebt = int256((user.amount * pool.accRewardPerShare) / 1e12);
        emit Withdraw(msg.sender, pid, amount);
    }

    /// @notice Withdraw without claiming pending rewards — emergency exit
    ///         in case the rewards pool is broken or out of funds.
    function emergencyWithdraw(uint256 pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.totalStaked -= amount;
        pool.lpToken.safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount);
    }
}
