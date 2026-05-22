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

    IMagnetaPoolSwap public immutable poolContract;

    // Fee in basis points (100 = 1%). FEE_BPS is the immutable router fee.
    uint256 public constant FEE_BPS = 30; // 0.3%

    // Fee recipient
    address public feeRecipient;

    // Mapping to track if a token is whitelisted
    mapping(address => bool) public whitelistedTokens;

    // Addresses exempt from swap fee (e.g. LPModule for cross-chain conversions)
    mapping(address => bool) public feeExempt;

    // Paused state
    bool public paused;

    address public pauseGuardian;

    event TokenWhitelisted(address indexed token, bool whitelisted);
    event FeeExemptUpdated(address indexed addr, bool exempt);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
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
     * @dev Execute a token swap via MagnetaPool (CPMM). Protocol fee (0.3%) is taken
     *      before routing to the pool. Fee-exempt addresses (e.g. LPModule) skip the fee.
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
        require(to != address(0), "MagnetaSwap: invalid recipient");
        require(whitelistedTokens[tokenIn] && whitelistedTokens[tokenOut], "MagnetaSwap: token not whitelisted");

        // Transfer tokens from user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Take contract-level fee (skip for exempt addresses like LPModule)
        uint256 fee = feeExempt[msg.sender] ? 0 : (amountIn * FEE_BPS) / 10000;
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

        // Match swap()'s fee handling: exempt addresses (LPModule etc.) get
        // a quote computed on the full amountIn — otherwise their on-chain
        // slippage checks would be biased low (we under-quoted them).
        uint256 fee = feeExempt[msg.sender] ? 0 : (amountIn * FEE_BPS) / 10000;
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

    function whitelistTokenBatch(address[] calldata tokens, bool whitelisted) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "MagnetaSwap: invalid token");
            whitelistedTokens[tokens[i]] = whitelisted;
            emit TokenWhitelisted(tokens[i], whitelisted);
        }
    }

    function setFeeExempt(address addr, bool exempt) external onlyOwner {
        require(addr != address(0), "MagnetaSwap: invalid address");
        feeExempt[addr] = exempt;
        emit FeeExemptUpdated(addr, exempt);
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

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == pauseGuardian,
            "MagnetaSwap: not owner or guardian"
        );
        _;
    }

    function pause() external onlyOwnerOrGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setPauseGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "MagnetaSwap: zero guardian");
        address old = pauseGuardian;
        pauseGuardian = _guardian;
        emit PauseGuardianUpdated(old, _guardian);
    }

    /**
     * @dev Emergency: recover tokens stuck in the router (only when paused).
     *      MagnetaSwap should never hold tokens — all swaps route through MagnetaPool.
     *      This covers edge cases like failed transfers or accidental sends.
     */
    function emergencyWithdraw(address token, uint256 amount) external nonReentrant onlyOwner whenPaused {
        require(token != address(0) && amount > 0, "MagnetaSwap: invalid");
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal >= amount, "MagnetaSwap: insufficient balance");
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdraw(token, amount, msg.sender);
    }
}

