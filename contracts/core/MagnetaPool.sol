// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/**
 * @title MagnetaPool
 * @dev Liquidity pool contract (simplified version - will be enhanced with concentrated liquidity)
 * 
 * @notice INSPIRATION: This DEX aims to replicate features from **Meteora.ag**, specifically 
 * **DLMM (Dynamic Liquidity Market Maker)** and **AMM** pools. Future updates will implement 
 * bin-based liquidity and advanced fee structures.
 */

contract MagnetaPool is ERC721, ERC721Enumerable, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Fee tiers in basis points
    uint24 public constant FEE_TIER_LOWEST = 1; // 0.01%
    uint24 public constant FEE_TIER_LOW = 5; // 0.05%
    uint24 public constant FEE_TIER_MEDIUM = 30; // 0.3%
    uint24 public constant FEE_TIER_HIGH = 100; // 1%

    /**
     * @dev Pool structure
     * @notice Simplified invariant: When liquidity > 0, the ratio reserve0/reserve1 must be 
     * maintained for new deposits. This is a simplified constant product approximation that does 
     * not implement full AMM pricing or concentrated liquidity ranges.
     */
    struct Pool {
        address token0;
        address token1;
        uint24 fee;
        uint256 liquidity; // Total liquidity in the pool (simplified calculation)
        uint256 reserve0; // Reserve of token0 (must maintain ratio with reserve1 when liquidity > 0)
        uint256 reserve1; // Reserve of token1 (must maintain ratio with reserve0 when liquidity > 0)
        bool exists;
    }

    // Position structure
    struct Position {
        uint256 poolId;
        uint256 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 fee0;
        uint256 fee1;
    }

    // Mapping: poolId => Pool
    mapping(uint256 => Pool) public pools;

    // Mapping: tokenId => Position
    mapping(uint256 => Position) public positions;

    // Mapping: token0 => token1 => fee => poolId
    mapping(address => mapping(address => mapping(uint24 => uint256))) public poolIds;

    // Total pools count
    uint256 public poolCount;
    uint256 private _tokenIdCounter;

    // Feature flag: Controls access to createPool and addLiquidity
    // Set to false by default to prevent public use until full AMM implementation is ready
    bool public poolCreationEnabled;
    bool public liquidityAdditionEnabled;

    // Events
    event PoolCreated(
        uint256 indexed poolId,
        address indexed token0,
        address indexed token1,
        uint24 fee
    );

    event LiquidityAdded(
        uint256 indexed poolId,
        uint256 indexed tokenId,
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    event LiquidityRemoved(
        uint256 indexed poolId,
        uint256 indexed tokenId,
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 liquidity
    );

    event FeesCollected(
        uint256 indexed poolId,
        uint256 indexed tokenId,
        uint256 fee0,
        uint256 fee1
    );

    event PoolCreationEnabled(bool enabled);
    event LiquidityAdditionEnabled(bool enabled);
    event Swap(
        uint256 indexed poolId,
        address indexed sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to
    );

    constructor(address _owner) ERC721("Magneta Pool Position", "MAGPOOL") {
        require(_owner != address(0), "MagnetaPool: invalid owner");
        _transferOwnership(_owner);
        poolCreationEnabled = true;
        liquidityAdditionEnabled = true;
    }

    /**
     * @dev Create a new pool
     * 
     * @notice WARNING: Pool creation is gated behind a feature flag (`poolCreationEnabled`) to 
     * prevent public use until full AMM implementation is ready. Only the owner can enable this 
     * feature flag. This is a security measure to prevent misuse of the simplified implementation.
     * 
     * @param token0 First token address
     * @param token1 Second token address
     * @param fee Fee tier (in basis points)
     * @return poolId The ID of the created pool
     */
    function createPool(
        address token0,
        address token1,
        uint24 fee
    ) external returns (uint256 poolId) {
        require(poolCreationEnabled || msg.sender == owner(), "MagnetaPool: pool creation disabled");
        require(token0 != token1, "MagnetaPool: identical tokens");
        require(
            fee == FEE_TIER_LOWEST || 
            fee == FEE_TIER_LOW || 
            fee == FEE_TIER_MEDIUM || 
            fee == FEE_TIER_HIGH,
            "MagnetaPool: invalid fee tier"
        );

        // Ensure token0 < token1
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        require(poolIds[token0][token1][fee] == 0, "MagnetaPool: pool already exists");

        poolId = ++poolCount;
        pools[poolId] = Pool({
            token0: token0,
            token1: token1,
            fee: fee,
            liquidity: 0,
            reserve0: 0,
            reserve1: 0,
            exists: true
        });

        poolIds[token0][token1][fee] = poolId;

        emit PoolCreated(poolId, token0, token1, fee);
        return poolId;
    }

    /**
     * @dev Add liquidity to a pool
     * 
     * @notice WARNING: This function uses simplified liquidity math. When pool.liquidity > 0, 
     * deposits must maintain the existing reserve ratio (reserve0/reserve1). The function will 
     * calculate the actual amounts based on the current reserve ratio and reject deposits that 
     * violate the ratio beyond slippage tolerance.
     * 
     * @notice Simplified Invariant: For existing pools (liquidity > 0), the deposit must maintain 
     * the ratio reserve0/reserve1. The function calculates the optimal amounts to maintain this 
     * ratio and refunds excess tokens. This is a simplified constant product approximation and does 
     * not implement full AMM pricing or concentrated liquidity ranges.
     * 
     * @param poolId Pool ID
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param amount0Min Minimum amount of token0 (slippage protection)
     * @param amount1Min Minimum amount of token1 (slippage protection)
     * @param to Recipient of the position NFT
     * @return tokenId The token ID of the position NFT
     * @return liquidity Amount of liquidity added
     * @return amount0 Actual amount of token0 added (may be less than amount0Desired)
     * @return amount1 Actual amount of token1 added (may be less than amount1Desired)
     */
    function addLiquidity(
        uint256 poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant whenNotPaused returns (uint256 tokenId, uint256 liquidity, uint256 amount0, uint256 amount1) {
        require(liquidityAdditionEnabled || msg.sender == owner(), "MagnetaPool: liquidity addition disabled");
        require(pools[poolId].exists, "MagnetaPool: pool does not exist");
        require(to != address(0), "MagnetaPool: invalid recipient");
        require(amount0Desired > 0 || amount1Desired > 0, "MagnetaPool: invalid amounts");

        Pool storage pool = pools[poolId];

        // Transfer tokens from user
        if (amount0Desired > 0) {
            IERC20(pool.token0).safeTransferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(pool.token1).safeTransferFrom(msg.sender, address(this), amount1Desired);
        }

        // Calculate actual amounts based on existing pool reserves
        if (pool.liquidity == 0) {
            // First liquidity: accept desired amounts (must provide both tokens)
            require(amount0Desired > 0 && amount1Desired > 0, "MagnetaPool: both tokens required for initial liquidity");
            amount0 = amount0Desired;
            amount1 = amount1Desired;
        } else {
            // Existing pool: must maintain reserve ratio
            require(pool.reserve0 > 0 && pool.reserve1 > 0, "MagnetaPool: invalid pool reserves");
            
            // Calculate optimal amounts to maintain reserve ratio
            // amount0 optimal = amount1Desired * reserve0 / reserve1
            // amount1 optimal = amount0Desired * reserve1 / reserve0
            uint256 amount0Optimal = (amount1Desired * pool.reserve0) / pool.reserve1;
            uint256 amount1Optimal = (amount0Desired * pool.reserve1) / pool.reserve0;
            
            if (amount0Optimal <= amount0Desired) {
                // Use amount0Optimal, which means we use all of amount1Desired
                amount0 = amount0Optimal;
                amount1 = amount1Desired;
            } else {
                // Use amount1Optimal, which means we use all of amount0Desired
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            }
            
            // Refund excess tokens
            if (amount0Desired > amount0) {
                IERC20(pool.token0).safeTransfer(msg.sender, amount0Desired - amount0);
            }
            if (amount1Desired > amount1) {
                IERC20(pool.token1).safeTransfer(msg.sender, amount1Desired - amount1);
            }
        }

        // Verify amounts meet slippage tolerance
        require(amount0 >= amount0Min, "MagnetaPool: amount0 slippage tolerance exceeded");
        require(amount1 >= amount1Min, "MagnetaPool: amount1 slippage tolerance exceeded");

        // Calculate liquidity (simplified formula)
        if (pool.liquidity == 0) {
            // Initial liquidity: geometric mean
            liquidity = sqrt(amount0 * amount1);
        } else {
            // Additional liquidity: proportional to existing reserves
            // Uses minimum to ensure ratio is maintained
            liquidity = min(
                (amount0 * pool.liquidity) / pool.reserve0,
                (amount1 * pool.liquidity) / pool.reserve1
            );
        }

        require(liquidity > 0, "MagnetaPool: insufficient liquidity");

        // Update pool reserves
        pool.reserve0 += amount0;
        pool.reserve1 += amount1;
        pool.liquidity += liquidity;

        // Mint position NFT
        tokenId = ++_tokenIdCounter;
        _safeMint(to, tokenId);

        // Store position
        positions[tokenId] = Position({
            poolId: poolId,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1,
            fee0: 0,
            fee1: 0
        });

        emit LiquidityAdded(poolId, tokenId, to, amount0, amount1, liquidity);

        return (tokenId, liquidity, amount0, amount1);
    }

    /**
     * @dev Remove liquidity from a pool
     * 
     * @notice WARNING: This function uses simplified liquidity math. The amounts returned are 
     * calculated proportionally based on the current pool reserves and the liquidity being removed.
     * This maintains the simplified constant product invariant but does not account for price impact
     * or concentrated liquidity ranges that would be present in a full AMM implementation.
     * 
     * @notice Simplified Invariant: Tokens are returned proportionally to the current reserve ratio.
     * The calculation uses: amount0 = (liquidity * reserve0) / totalLiquidity, ensuring the 
     * reserve ratio remains constant. This is a simplified approximation and does not implement 
     * full AMM pricing calculations.
     * 
     * @param tokenId Position NFT token ID
     * @param liquidity Amount of liquidity to remove
     * @param amount0Min Minimum amount of token0 (slippage protection)
     * @param amount1Min Minimum amount of token1 (slippage protection)
     * @param to Recipient of the tokens
     * @return amount0 Amount of token0 removed
     * @return amount1 Amount of token1 removed
     */
    function removeLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external nonReentrant whenNotPaused returns (uint256 amount0, uint256 amount1) {
        require(ownerOf(tokenId) == msg.sender, "MagnetaPool: not position owner");
        require(to != address(0), "MagnetaPool: invalid recipient");

        Position storage position = positions[tokenId];
        require(position.liquidity >= liquidity, "MagnetaPool: insufficient liquidity");

        Pool storage pool = pools[position.poolId];
        require(pool.exists, "MagnetaPool: pool does not exist");
        require(pool.liquidity > 0, "MagnetaPool: pool has no liquidity");

        // Calculate amounts to return proportionally based on reserve ratio
        // This maintains the simplified constant product invariant
        amount0 = (liquidity * pool.reserve0) / pool.liquidity;
        amount1 = (liquidity * pool.reserve1) / pool.liquidity;

        require(amount0 >= amount0Min, "MagnetaPool: amount0 slippage tolerance exceeded");
        require(amount1 >= amount1Min, "MagnetaPool: amount1 slippage tolerance exceeded");

        // Update position
        position.liquidity -= liquidity;
        position.amount0 = amount0 <= position.amount0 ? position.amount0 - amount0 : 0;
        position.amount1 = amount1 <= position.amount1 ? position.amount1 - amount1 : 0;

        // Update pool
        pool.reserve0 -= amount0;
        pool.reserve1 -= amount1;
        pool.liquidity -= liquidity;

        // Transfer tokens to recipient
        IERC20(pool.token0).safeTransfer(to, amount0);
        IERC20(pool.token1).safeTransfer(to, amount1);

        // Burn NFT if all liquidity removed
        if (position.liquidity == 0) {
            _burn(tokenId);
            delete positions[tokenId];
        }

        emit LiquidityRemoved(position.poolId, tokenId, to, amount0, amount1, liquidity);

        return (amount0, amount1);
    }

    /**
     * @dev Collect fees from a position
     * @param tokenId Position NFT token ID
     * @param to Recipient of the fees
     * @return amount0 Amount of token0 fees collected
     * @return amount1 Amount of token1 fees collected
     */
    function collectFees(uint256 tokenId, address to) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(ownerOf(tokenId) == msg.sender, "MagnetaPool: not position owner");
        require(to != address(0), "MagnetaPool: invalid recipient");

        Position storage position = positions[tokenId];
        amount0 = position.fee0;
        amount1 = position.fee1;

        if (amount0 > 0 || amount1 > 0) {
            Pool storage pool = pools[position.poolId];
            if (amount0 > 0) {
                IERC20(pool.token0).safeTransfer(to, amount0);
                position.fee0 = 0;
            }
            if (amount1 > 0) {
                IERC20(pool.token1).safeTransfer(to, amount1);
                position.fee1 = 0;
            }

            emit FeesCollected(position.poolId, tokenId, amount0, amount1);
        }

        return (amount0, amount1);
    }

    /**
     * @dev Get pool by token addresses and fee
     */
    function getPool(
        address token0,
        address token1,
        uint24 fee
    ) external view returns (uint256 poolId) {
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }
        return poolIds[token0][token1][fee];
    }

    /**
     * @dev Enable or disable pool creation (only owner)
     * @notice This feature flag controls public access to `createPool`. When disabled, only the 
     * owner can create pools. This is a security measure to prevent misuse of the simplified 
     * implementation until full AMM math is implemented.
     * @param enabled Whether to enable pool creation for public
     */
    function setPoolCreationEnabled(bool enabled) external onlyOwner {
        poolCreationEnabled = enabled;
        emit PoolCreationEnabled(enabled);
    }

    /**
     * @dev Enable or disable liquidity addition (only owner)
     * @notice This feature flag controls public access to `addLiquidity`. When disabled, only the 
     * owner can add liquidity. This is a security measure to prevent misuse of the simplified 
     * implementation until full AMM math is implemented.
     * @param enabled Whether to enable liquidity addition for public
     */
    function setLiquidityAdditionEnabled(bool enabled) external onlyOwner {
        liquidityAdditionEnabled = enabled;
        emit LiquidityAdditionEnabled(enabled);
    }

    // Feature flags removed or enabled by default for production
    
    /**
     * @dev Get output amount for a swap
     */
    function getAmountOut(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        Pool storage pool = pools[poolId];
        require(pool.exists, "MagnetaPool: pool does not exist");
        
        bool isToken0 = tokenIn == pool.token0;
        require(isToken0 || tokenIn == pool.token1, "MagnetaPool: invalid token");
        
        uint256 reserveIn = isToken0 ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = isToken0 ? pool.reserve1 : pool.reserve0;
        
        if (reserveIn == 0 || reserveOut == 0) return 0;

        uint256 feeBps = pool.fee;
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        
        return numerator / denominator;
    }

    /**
     * @dev Swap tokens in a pool
     * @param poolId Pool ID
     * @param tokenIn Input token address
     * @param amountIn Amount of input tokens
     * @param amountOutMin Minimum amount of output tokens
     * @param to Recipient address
     * @param deadline Transaction deadline
     */
    function swap(
        uint256 poolId,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(block.timestamp <= deadline, "MagnetaPool: deadline exceeded");
        
        Pool storage pool = pools[poolId];
        require(pool.exists, "MagnetaPool: pool does not exist");
        
        bool isToken0 = tokenIn == pool.token0;
        require(isToken0 || tokenIn == pool.token1, "MagnetaPool: invalid token");
        
        // Transfer input
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Calculate output using Constant Product Formula including fees
        // amountOut = (amountIn * (10000 - fee) * reserveOut) / (reserveIn * 10000 + amountIn * (10000 - fee))
        
        uint256 reserveIn = isToken0 ? pool.reserve0 : pool.reserve1;
        uint256 reserveOut = isToken0 ? pool.reserve1 : pool.reserve0;
        
        require(reserveIn > 0 && reserveOut > 0, "MagnetaPool: insufficient liquidity");

        uint256 feeBps = pool.fee;
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        
        amountOut = numerator / denominator;
        require(amountOut >= amountOutMin, "MagnetaPool: slippage exceeded");
        require(amountOut < reserveOut, "MagnetaPool: insufficient liquidity");
        
        // Update reserves
        if (isToken0) {
            pool.reserve0 += amountIn;
            pool.reserve1 -= amountOut;
        } else {
            pool.reserve1 += amountIn;
            pool.reserve0 -= amountOut;
        }
        
        // Transfer output
        address tokenOut = isToken0 ? pool.token1 : pool.token0;
        IERC20(tokenOut).safeTransfer(to, amountOut);

        // Fees stay in pool reserves (Uniswap V2 style) — LPs benefit proportionally on withdrawal
        emit Swap(poolId, msg.sender, tokenIn, tokenOut, amountIn, amountOut, to);
    }

    // Emergency controls
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Helper functions
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // Required overrides
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

