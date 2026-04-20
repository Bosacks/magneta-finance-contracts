// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// Interface for MagnetaPool positions
interface IMagnetaPool {
    function positions(uint256 tokenId) external view returns (
        uint256 poolId,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 fee0,
        uint256 fee1
    );
}

/**
 * @title MagnetaFarm
 * @dev Farm contract for staking LP tokens (ERC20 or ERC721 positions) and earning rewards
 */
contract MagnetaFarm is Ownable2Step, ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeERC20 for IERC20;

    // Farm pool structure
    struct PoolInfo {
        address lpToken; // Address of LP token contract (ERC20 or ERC721)
        uint256 allocPoint; // Allocation points for this pool
        uint256 lastRewardBlock; // Last block number that rewards distribution occurs
        uint256 accRewardPerShare; // Accumulated rewards per share, times 1e12
        uint256 totalLiquidity; // Total liquidity staked in this pool
        bool isNFTPool; // Whether this pool uses NFT positions
        bool exists;
    }

    // User staking info
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided
        uint256 rewardDebt; // Reward debt
        uint256 pendingRewards; // Pending rewards to claim
    }

    // Reward token
    IERC20 public rewardToken;

    // Reward per block
    uint256 public rewardPerBlock;

    // Total allocation points
    uint256 public totalAllocPoint;

    // Start block
    uint256 public startBlock;

    // Mapping: lpToken => boolean (to prevent duplicate pools)
    mapping(address => bool) public lpTokenRegistered;

    // Mapping: poolId => PoolInfo
    mapping(uint256 => PoolInfo) public poolInfo;

    // Mapping: poolId => user => UserInfo
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Mapping: poolId => user => array of staked tokenId
    mapping(uint256 => mapping(address => uint256[])) public userNFTs;

    // Mapping: tokenId => user (to track who owns which staked NFT)
    // tokenId is assumed unique across different pools (as MagnetaPool handles multiple pools)
    mapping(uint256 => address) public nftOwners;

    // Total pools
    uint256 public poolCount;

    // Events
    event PoolAdded(uint256 indexed poolId, address indexed lpToken, uint256 allocPoint, bool isNFTPool);
    event PoolUpdated(uint256 indexed poolId, uint256 allocPoint);
    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount);
    event NFTDeposit(address indexed user, uint256 indexed poolId, uint256 tokenId, uint256 liquidity);
    event NFTWithdraw(address indexed user, uint256 indexed poolId, uint256 tokenId, uint256 liquidity);

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
    event RewardClaimed(address indexed user, uint256 indexed poolId, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed poolId, uint256 amount);

    constructor(
        address _owner,
        address _rewardToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock
    ) {
        require(_owner != address(0), "MagnetaFarm: invalid owner");
        require(_rewardToken != address(0), "MagnetaFarm: invalid reward token");
        _transferOwnership(_owner);
        rewardToken = IERC20(_rewardToken);
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        totalAllocPoint = 0;
    }

    /**
     * @dev Add a new pool
     * @param _lpToken LP token address
     * @param _allocPoint Allocation points for this pool
     * @param _withUpdate Whether to update all pools
     */
    function addPool(
        address _lpToken,
        uint256 _allocPoint,
        bool _isNFTPool,
        bool _withUpdate
    ) external onlyOwner {
        require(_lpToken != address(0), "MagnetaFarm: invalid LP token");
        require(!lpTokenRegistered[_lpToken], "MagnetaFarm: pool already exists");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;

        uint256 poolId = poolCount++;
        poolInfo[poolId] = PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRewardPerShare: 0,
            totalLiquidity: 0,
            isNFTPool: _isNFTPool,
            exists: true
        });

        lpTokenRegistered[_lpToken] = true;
        emit PoolAdded(poolId, _lpToken, _allocPoint, _isNFTPool);
    }

    /**
     * @dev Update pool allocation points
     * @param _poolId Pool ID
     * @param _allocPoint New allocation points
     * @param _withUpdate Whether to update all pools
     */
    function setPool(uint256 _poolId, uint256 _allocPoint, bool _withUpdate) external onlyOwner {
        require(poolInfo[_poolId].exists, "MagnetaFarm: pool does not exist");
        if (_withUpdate) {
            massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint - poolInfo[_poolId].allocPoint + _allocPoint;
        poolInfo[_poolId].allocPoint = _allocPoint;

        emit PoolUpdated(_poolId, _allocPoint);
    }

    /**
     * @dev Update reward variables for a pool
     * @param _poolId Pool ID
     */
    function updatePool(uint256 _poolId) public {
        PoolInfo storage pool = poolInfo[_poolId];
        require(pool.exists, "MagnetaFarm: pool does not exist");

        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        if (pool.totalLiquidity == 0 || totalAllocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = block.number - pool.lastRewardBlock;
        uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;

        pool.accRewardPerShare += (reward * 1e12) / pool.totalLiquidity;
        pool.lastRewardBlock = block.number;
    }

    /**
     * @dev Update all pools
     */
    function massUpdatePools() public {
        for (uint256 i = 0; i < poolCount; i++) {
            if (poolInfo[i].exists) {
                updatePool(i);
            }
        }
    }

    /**
     * @dev Deposit LP tokens to farm
     * @param _poolId Pool ID
     * @param _amount Amount of LP tokens to deposit
     */
    function deposit(uint256 _poolId, uint256 _amount) external nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        PoolInfo storage pool = poolInfo[_poolId];
        require(pool.exists, "MagnetaFarm: pool does not exist");
        require(!pool.isNFTPool, "MagnetaFarm: use depositNFT for this pool");
        UserInfo storage user = userInfo[_poolId][msg.sender];

        updatePool(_poolId);

        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        if (_amount > 0) {
            user.amount += _amount;
            pool.totalLiquidity += _amount;
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;

        if (_amount > 0) {
            IERC20(pool.lpToken).safeTransferFrom(msg.sender, address(this), _amount);
        }

        emit Deposit(msg.sender, _poolId, _amount);
    }

    /**
     * @dev Withdraw LP tokens from farm
     * @param _poolId Pool ID
     * @param _amount Amount of LP tokens to withdraw
     */
    function withdraw(uint256 _poolId, uint256 _amount) external nonReentrant {
        require(msg.sender != address(0), "Invalid sender");
        PoolInfo storage pool = poolInfo[_poolId];
        require(pool.exists, "MagnetaFarm: pool does not exist");
        require(!pool.isNFTPool, "MagnetaFarm: use withdrawNFT for this pool");
        UserInfo storage user = userInfo[_poolId][msg.sender];
        require(user.amount >= _amount, "MagnetaFarm: insufficient balance");

        updatePool(_poolId);

        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        if (_amount > 0) {
            user.amount -= _amount;
            pool.totalLiquidity -= _amount;
        }
        
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;

        if (_amount > 0) {
            IERC20(pool.lpToken).safeTransfer(msg.sender, _amount);
        }

        emit Withdraw(msg.sender, _poolId, _amount);
    }

    /**
     * @dev Claim rewards
     * @param _poolId Pool ID
     */
    function claimRewards(uint256 _poolId) external nonReentrant {
        require(msg.sender != address(0), "Invalid sender");
        PoolInfo storage pool = poolInfo[_poolId];
        require(pool.exists, "MagnetaFarm: pool does not exist");
        UserInfo storage user = userInfo[_poolId][msg.sender];

        updatePool(_poolId);

        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        uint256 totalPending = user.pendingRewards;
        if (totalPending > 0) {
            user.pendingRewards = 0;
            user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;

            rewardToken.safeTransfer(msg.sender, totalPending);
            emit RewardClaimed(msg.sender, _poolId, totalPending);
        }
    }

    /**
     * @dev Deposit NFT position to farm
     */
    function depositNFT(uint256 _poolId, uint256 _tokenId) external nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        PoolInfo storage pool = poolInfo[_poolId];
        require(pool.exists, "MagnetaFarm: pool does not exist");
        require(pool.isNFTPool, "MagnetaFarm: pool is not an NFT pool");
        
        updatePool(_poolId);
        
        UserInfo storage user = userInfo[_poolId][msg.sender];
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }
        
        // Get liquidity from MagnetaPool
        // NOTE: Aderyn flags this as a CEI violation, but evaluating position before state change is standard.
        // The function is protected by the nonReentrant modifier.
        (, uint256 liquidity,,,,) = IMagnetaPool(pool.lpToken).positions(_tokenId);
        require(liquidity > 0, "MagnetaFarm: zero liquidity position");
        
        // Update user info
        user.amount += liquidity;
        pool.totalLiquidity += liquidity;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        
        // Track NFT
        userNFTs[_poolId][msg.sender].push(_tokenId);
        nftOwners[_tokenId] = msg.sender;
        
        // Transfer NFT
        IERC721(pool.lpToken).safeTransferFrom(msg.sender, address(this), _tokenId);
        
        emit NFTDeposit(msg.sender, _poolId, _tokenId, liquidity);
    }

    /**
     * @dev Withdraw NFT position from farm
     */
    function withdrawNFT(uint256 _poolId, uint256 _tokenId) external nonReentrant {
        require(msg.sender != address(0), "Invalid sender");
        PoolInfo storage pool = poolInfo[_poolId];
        require(pool.exists, "MagnetaFarm: pool does not exist");
        require(pool.isNFTPool, "MagnetaFarm: pool is not an NFT pool");
        require(nftOwners[_tokenId] == msg.sender, "MagnetaFarm: not the owner of this NFT");
        
        updatePool(_poolId);
        
        UserInfo storage user = userInfo[_poolId][msg.sender];
        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }
        
        // NOTE: Aderyn flags this as a CEI violation, but evaluating position before state change is standard.
        // The function is protected by the nonReentrant modifier.
        (, uint256 liquidity,,,,) = IMagnetaPool(pool.lpToken).positions(_tokenId);
        
        // Remove NFT from tracking
        _removeNFTFromUser(_poolId, msg.sender, _tokenId);
        delete nftOwners[_tokenId];
        
        user.amount -= liquidity;
        pool.totalLiquidity -= liquidity;
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        
        // Transfer NFT back
        IERC721(pool.lpToken).safeTransferFrom(address(this), msg.sender, _tokenId);
        
        emit NFTWithdraw(msg.sender, _poolId, _tokenId, liquidity);
    }

    function _removeNFTFromUser(uint256 _pid, address _user, uint256 _tokenId) internal {
        uint256[] storage nfts = userNFTs[_pid][_user];
        for (uint256 i = 0; i < nfts.length; i++) {
            if (nfts[i] == _tokenId) {
                nfts[i] = nfts[nfts.length - 1];
                nfts.pop();
                break;
            }
        }
    }

    /**
     * @dev Get pending rewards for a user
     * @param _poolId Pool ID
     * @param _user User address
     * @return Pending reward amount
     */
    function pendingRewards(uint256 _poolId, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_poolId];
        require(pool.exists, "MagnetaFarm: pool does not exist");
        UserInfo storage user = userInfo[_poolId][_user];

        uint256 accRewardPerShare = pool.accRewardPerShare;

        if (block.number > pool.lastRewardBlock && pool.totalLiquidity != 0) {
            uint256 multiplier = block.number - pool.lastRewardBlock;
            uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            accRewardPerShare += (reward * 1e12) / pool.totalLiquidity;
        }

        return user.pendingRewards + (user.amount * accRewardPerShare) / 1e12 - user.rewardDebt;
    }

    /**
     * @dev Emergency withdraw (forfeit rewards)
     * @param _poolId Pool ID
     */
    function emergencyWithdraw(uint256 _poolId) external nonReentrant {
        require(msg.sender != address(0), "Invalid sender");
        PoolInfo storage pool = poolInfo[_poolId];
        require(pool.exists, "MagnetaFarm: pool does not exist");
        UserInfo storage user = userInfo[_poolId][msg.sender];

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;
        pool.totalLiquidity -= amount;

        uint256[] memory nfts;
        if (pool.isNFTPool) {
            nfts = userNFTs[_poolId][msg.sender];
            delete userNFTs[_poolId][msg.sender];
            for (uint256 i = 0; i < nfts.length; i++) {
                delete nftOwners[nfts[i]];
            }
        }

        emit EmergencyWithdraw(msg.sender, _poolId, amount);

        if (pool.isNFTPool) {
            for (uint256 i = 0; i < nfts.length; i++) {
                IERC721(pool.lpToken).safeTransferFrom(address(this), msg.sender, nfts[i]);
            }
        } else {
            IERC20(pool.lpToken).safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @dev Update reward per block
     * @param _rewardPerBlock New reward per block
     */
    function setRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        massUpdatePools();
        rewardPerBlock = _rewardPerBlock;
    }

    /**
     * @dev Emergency withdraw reward tokens (only owner)
     * @param _amount Amount to withdraw
     */
    function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
        rewardToken.safeTransfer(owner(), _amount);
    }

    // Emergency pause — withdraw/emergencyWithdraw/claimRewards stay unpaused so users can always exit.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}

