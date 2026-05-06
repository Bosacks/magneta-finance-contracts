// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 }          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable }         from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title MagnetaStakingRewards
 * @notice Single-asset staking pool with linear rewards distribution.
 *         Synthetix StakingRewards V1 pattern — the gold standard for
 *         single-token staking (deployed thousands of times since 2020).
 *
 *         Owner funds the pool by transferring reward tokens here and
 *         calling `notifyRewardAmount`. Rewards stream linearly over the
 *         configured duration (typically 30-90 days). Stakers can stake/
 *         withdraw at any time and claim accumulated rewards.
 *
 *         Math (per the original Synthetix design):
 *           - rewardPerToken = sum over time of (rewardRate * dt) / totalSupply
 *           - earned[user]   = balance[user] * (rewardPerToken - userPaid[user]) + rewards[user]
 *
 *         Edge cases handled:
 *           - Empty pool (totalSupply == 0): rewardPerToken doesn't grow
 *           - Reward extension: notifyRewardAmount can be called at any time
 *             (mid-period adds remaining undistributed to the new amount)
 *           - Recovery: rescueERC20 lets the owner pull mistakenly-sent tokens
 *             EXCEPT the staking token (would let owner steal stakes)
 */
contract MagnetaStakingRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Wired tokens (immutable post-deploy) ─────────────────────────────

    /// @notice Token users stake here. Cannot be the same as `rewardsToken`
    ///         (would create gameable accounting via reward-as-stake).
    IERC20 public immutable stakingToken;

    /// @notice Token paid out as rewards. Owner funds this contract with
    ///         this token before calling notifyRewardAmount.
    IERC20 public immutable rewardsToken;

    // ─── Reward streaming state ───────────────────────────────────────────

    /// @notice Block timestamp at which the current reward period ends.
    uint256 public periodFinish;

    /// @notice Reward tokens per second distributed across all stakers.
    uint256 public rewardRate;

    /// @notice Default reward period in seconds. Owner can change via
    ///         setRewardsDuration (only when no active period).
    uint256 public rewardsDuration = 30 days;

    /// @notice Last block timestamp the running reward integral was updated.
    uint256 public lastUpdateTime;

    /// @notice Accumulated reward per staked token, scaled by 1e18.
    uint256 public rewardPerTokenStored;

    /// @notice Per-user paid checkpoint — used to compute earned() incrementally.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Pending rewards per user (claimable now).
    mapping(address => uint256) public rewards;

    // ─── Staking state ────────────────────────────────────────────────────

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    // ─── Events ───────────────────────────────────────────────────────────

    event RewardAdded(uint256 reward, uint256 newPeriodFinish);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);

    // ─── Constructor ──────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _stakingToken,
        address _rewardsToken
    ) {
        require(_stakingToken != address(0) && _rewardsToken != address(0), "zero token");
        require(_stakingToken != _rewardsToken, "same token");
        require(initialOwner != address(0), "zero owner");
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
        if (initialOwner != msg.sender) {
            _transferOwnership(initialOwner);
        }
    }

    // ─── Views ────────────────────────────────────────────────────────────

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return _balances[account]
            * (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18
            + rewards[account];
    }

    /// @notice Total rewards that will be distributed during the current period.
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    // ─── Mutators ─────────────────────────────────────────────────────────

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "zero amount");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "zero amount");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Withdraw entire stake AND claim all pending rewards in one tx.
    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    // ─── Owner functions ──────────────────────────────────────────────────

    /**
     * @notice Top up the reward pool. Caller must have transferred at least
     *         `reward` rewardsToken to this contract before calling. The new
     *         reward streams over `rewardsDuration` from now; if the previous
     *         period hasn't finished, its remaining rewards are added in.
     */
    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover  = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Sanity check — owner must have actually funded the contract
        uint256 balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance / rewardsDuration, "reward > balance");

        lastUpdateTime = block.timestamp;
        periodFinish   = block.timestamp + rewardsDuration;
        emit RewardAdded(reward, periodFinish);
    }

    /// @notice Change the period length. Only allowed when there's no active
    ///         period (otherwise it would mid-stream re-rate the existing pool).
    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(block.timestamp > periodFinish, "period active");
        require(_rewardsDuration > 0, "zero duration");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(_rewardsDuration);
    }

    /**
     * @notice Recover an ERC20 sent to the contract by mistake. Cannot be the
     *         staking token (would let owner steal stakes). Can be the rewards
     *         token only if the caller proves it's not part of the active
     *         reward stream — to keep the math invariant we require all staked
     *         users to have exited first (totalSupply == 0).
     */
    function rescueERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "cannot rescue staked");
        if (tokenAddress == address(rewardsToken)) {
            require(_totalSupply == 0 && block.timestamp >= periodFinish, "active rewards");
        }
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    // ─── Modifier ─────────────────────────────────────────────────────────

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime       = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account]                  = earned(account);
            userRewardPerTokenPaid[account]   = rewardPerTokenStored;
        }
        _;
    }
}
