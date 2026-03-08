// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IMagnetaSwap.sol";

/**
 * @title MagnetaSwap
 * @dev Swap router for Magneta Finance DEX — delegates AMM logic to MagnetaPool.
 * Adds a protocol fee layer on top of the pool's own AMM fee.
 */
// Interface for MagnetaPool
interface IMagnetaPoolSwap {
    function getPool(address token0, address token1, uint24 fee) external view returns (uint256);
    function swap(uint256 poolId, address tokenIn, uint256 amountIn, uint256 amountOutMin, address to, uint256 deadline) external returns (uint256);
    function getAmountOut(uint256 poolId, address tokenIn, uint256 amountIn) external view returns (uint256);
}

contract MagnetaSwap is IMagnetaSwap, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IMagnetaPoolSwap public poolContract;

    // Fee in basis points (100 = 1%)
    uint256 public constant FEE_BPS = 30; // 0.3%
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    // Fee recipient
    address public feeRecipient;

    // Mapping to track if a token is whitelisted
    mapping(address => bool) public whitelistedTokens;

    // Mapping to track token reserves (balance accounting)
    mapping(address => uint256) public tokenReserves;

    // Paused state
    bool public paused;

    event TokenWhitelisted(address indexed token, bool whitelisted);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event Paused(address account);
    event Unpaused(address account);
    event LiquidityDeposited(address indexed token, uint256 amount, address indexed depositor);
    event LiquidityWithdrawn(address indexed token, uint256 amount, address indexed recipient);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed caller);

    modifier whenNotPaused() {
        require(!paused, "MagnetaSwap: paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "MagnetaSwap: not paused");
        _;
    }

    constructor(address _feeRecipient, address _poolContract) {
        require(_feeRecipient != address(0), "MagnetaSwap: invalid fee recipient");
        require(_poolContract != address(0), "MagnetaSwap: invalid pool contract");
        feeRecipient = _feeRecipient;
        poolContract = IMagnetaPoolSwap(_poolContract);
    }

    /**
     * @dev Execute a token swap
     * 
     * @notice WARNING: This function is NOT production-ready. It requires proper AMM or pool 
     * integration before use with real funds. The current implementation uses simplified pricing 
     * and requires explicit liquidity deposits via `depositLiquidity`.
     * 
     * @param tokenIn Address of the input token
     * @param tokenOut Address of the output token
     * @param amountIn Amount of input tokens
     * @param amountOutMin Minimum amount of output tokens (slippage protection)
     * @param to Address to receive output tokens
     * @param deadline Transaction deadline
     * @return amountOut Amount of output tokens received
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline
    ) external override nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(block.timestamp <= deadline, "MagnetaSwap: deadline exceeded");
        require(tokenIn != tokenOut, "MagnetaSwap: identical tokens");
        require(amountIn > 0, "MagnetaSwap: invalid amount");
        require(whitelistedTokens[tokenIn] && whitelistedTokens[tokenOut], "MagnetaSwap: token not whitelisted");

        // Transfer tokens from user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Take contract-level fee
        uint256 fee = (amountIn * FEE_BPS) / 10000;
        if (fee > 0) {
            IERC20(tokenIn).safeTransfer(feeRecipient, fee);
        }
        uint256 amountToSwap = amountIn - fee;

        // Find pool (defaulting to 0.3% fee tier)
        uint256 poolId = poolContract.getPool(tokenIn, tokenOut, 30);
        require(poolId > 0, "MagnetaSwap: no corresponding pool found");

        // Approve pool (forceApprove resets then sets, safe for tokens that require 0 first)
        IERC20(tokenIn).forceApprove(address(poolContract), amountToSwap);

        // Execute swap
        amountOut = poolContract.swap(
            poolId,
            tokenIn,
            amountToSwap,
            amountOutMin,
            to,
            deadline
        );

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, to);
        return amountOut;
    }

    /**
     * @dev Get the amount of output tokens for a given input (delegates to pool CPMM pricing)
     */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public view override returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        if (!whitelistedTokens[tokenIn] || !whitelistedTokens[tokenOut]) return 0;
        
        // Take contract-level fee
        uint256 fee = (amountIn * FEE_BPS) / 10000;
        uint256 amountToSwap = amountIn - fee;

        uint256 poolId = poolContract.getPool(tokenIn, tokenOut, 30);
        if (poolId == 0) return 0;

        return poolContract.getAmountOut(poolId, tokenIn, amountToSwap);
    }

    /**
     * @dev Whitelist a token
     * @param token Address of the token
     * @param whitelisted Whether to whitelist or remove from whitelist
     */
    function setWhitelistedToken(address token, bool whitelisted) external onlyOwner {
        require(token != address(0), "MagnetaSwap: invalid token");
        whitelistedTokens[token] = whitelisted;
        emit TokenWhitelisted(token, whitelisted);
    }

    /**
     * @dev Update fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "MagnetaSwap: invalid fee recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @dev Deposit liquidity for a token (only owner or authorized pool contract)
     * @notice This function allows the owner to seed the contract with tokens for swaps.
     * Tokens must be approved for transfer to this contract before calling.
     * @param token Address of the token to deposit
     * @param amount Amount of tokens to deposit
     */
    function depositLiquidity(address token, uint256 amount) external nonReentrant onlyOwner {
        require(token != address(0), "MagnetaSwap: invalid token");
        require(amount > 0, "MagnetaSwap: invalid amount");
        require(whitelistedTokens[token], "MagnetaSwap: token not whitelisted");
        
        // Transfer tokens from caller
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update reserves
        tokenReserves[token] += amount;
        
        emit LiquidityDeposited(token, amount, msg.sender);
    }

    /**
     * @dev Withdraw liquidity for a token (only owner)
     * @notice This function allows the owner to withdraw excess tokens from the contract.
     * @param token Address of the token to withdraw
     * @param amount Amount of tokens to withdraw
     */
    function withdrawLiquidity(address token, uint256 amount) external nonReentrant onlyOwner {
        require(token != address(0), "MagnetaSwap: invalid token");
        require(amount > 0, "MagnetaSwap: invalid amount");
        
        // Check contract balance
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        require(contractBalance >= amount, "MagnetaSwap: insufficient balance");
        
        // Check reserves
        require(tokenReserves[token] >= amount, "MagnetaSwap: insufficient reserves");
        
        // Update reserves
        tokenReserves[token] -= amount;
        
        // Transfer tokens to owner
        IERC20(token).safeTransfer(owner(), amount);
        
        emit LiquidityWithdrawn(token, amount, owner());
    }

    /**
     * @dev Emergency withdraw tokens (only owner, only when paused)
     * 
     * @notice EMERGENCY FUNCTION - This function can only be called when the contract is paused.
     * This is a critical security measure to prevent abuse and misconfiguration.
     * 
     * @notice Expected Emergency Process:
     * 1. Owner detects a critical issue or vulnerability
     * 2. Owner calls `pause()` to halt all swap operations
     * 3. Owner calls `emergencyWithdraw()` to recover funds if necessary
     * 4. After investigation and fixes, owner calls `unpause()` to resume operations
     * 
     * @notice This function does NOT update token reserves, making it suitable only for 
     * emergency recovery scenarios. For normal operations, use `withdrawLiquidity()` instead.
     * 
     * @notice Security Considerations:
     * - Uses `Ownable2Step` for two-step ownership transfer, reducing risk of compromised deployer key
     * - Requires contract to be paused, preventing use during normal operations
     * - Emits `EmergencyWithdraw` event for off-chain monitoring and traceability
     * - Only owner can call this function
     * 
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external nonReentrant onlyOwner whenPaused {
        require(token != address(0), "MagnetaSwap: invalid token");
        require(amount > 0, "MagnetaSwap: invalid amount");
        
        // Check contract balance
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        require(contractBalance >= amount, "MagnetaSwap: insufficient balance");
        
        // Transfer tokens to owner
        IERC20(token).safeTransfer(owner(), amount);
        
        // Emit event for off-chain traceability
        emit EmergencyWithdraw(token, amount, msg.sender);
        
        // Note: This does not update reserves - use only in emergencies
    }
}

