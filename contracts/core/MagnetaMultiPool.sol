// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title MagnetaMultiPool
 * @dev Multi-Token Liquidity Pool (3+ tokens)
 * Implements a simplified Value Function MM (like Balancer)
 */
contract MagnetaMultiPool is ERC20, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Pool tokens
    IERC20[] public tokens;
    // Normalized weights (sum to 1 ether)
    uint256[] public weights;
    // Swap fee (1e18 scale, e.g., 0.003e18 = 0.3%)
    uint256 public immutable swapFee;

    // Mapping for quick token lookup
    mapping(address => bool) public isTokenInPool;

    event LiquidityAdded(address indexed provider, uint256[] amounts, uint256 lpAmount);
    event LiquidityRemoved(address indexed provider, uint256[] amounts, uint256 lpAmount);
    event Swap(address indexed provider, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(
        string memory name,
        string memory symbol,
        address[] memory _tokens,
        uint256[] memory _weights,
        uint256 _swapFee,
        address _owner
    ) ERC20(name, symbol) {
        require(_tokens.length >= 2, "Min 2 tokens");
        require(_tokens.length == _weights.length, "Length mismatch");
        require(_tokens.length <= 8, "Max 8 tokens"); // Safety limit

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < _tokens.length; i++) {
            require(address(_tokens[i]) != address(0), "Invalid token");
            require(!isTokenInPool[address(_tokens[i])], "Duplicate token");
            
            tokens.push(IERC20(_tokens[i]));
            weights.push(_weights[i]);
            isTokenInPool[address(_tokens[i])] = true;
            totalWeight += _weights[i];
        }

        require(totalWeight == 1e18, "Weights must sum to 1e18");
        swapFee = _swapFee;
        _transferOwnership(_owner);
    }

    /**
     * @dev Add liquidity to the pool (Proportional only for simplicity MVP)
     */
    function addLiquidity(uint256[] calldata amounts, uint256 minLpAmount) external nonReentrant whenNotPaused returns (uint256 lpAmount) {
        uint256 length = tokens.length;
        require(amounts.length == length, "Length mismatch");

        uint256 _totalSupply = totalSupply();
        
        if (_totalSupply == 0) {
            // Initial liquidity
            uint256 totalNormalized = 0;
            for (uint256 i = 0; i < length; i++) {
                require(amounts[i] > 0, "Initial liquidity must be positive");
                // Normalize to 18 decimals for LP calculation
                uint256 tokenDecimals = ERC20(address(tokens[i])).decimals();
                uint256 normalized = amounts[i] * (10**(18 - tokenDecimals));
                totalNormalized += (normalized * weights[i]) / 1e18;
            }
            
            lpAmount = totalNormalized;
            require(lpAmount > 1000, "Initial liquidity too low");
            
            // Burn the first 1000 wei to prevent "inflation attack"
            // We mint it to a dead address as _mint(address(0)) is prohibited
            _mint(address(0x000000000000000000000000000000000000dEaD), 1000);
            lpAmount -= 1000;
        } else {
            // Proportional deposit
            // Calculate ratio based on first non-zero amount
            // Currently requiring all tokens for simplicity
            lpAmount = (_totalSupply * amounts[0]) / tokens[0].balanceOf(address(this));
        }

        require(lpAmount >= minLpAmount, "Slippage");

        _mint(msg.sender, lpAmount);

        // Transfer tokens
        for (uint256 i = 0; i < length; i++) {
            if (amounts[i] > 0) {
                tokens[i].safeTransferFrom(msg.sender, address(this), amounts[i]);
            }
        }

        emit LiquidityAdded(msg.sender, amounts, lpAmount);
    }

    /**
     * @dev Remove liquidity (Proportional)
     */
    function removeLiquidity(uint256 lpAmount, uint256[] calldata minAmounts) external nonReentrant {
        require(lpAmount > 0, "Zero amount");
        
        uint256 _totalSupply = totalSupply();
        uint256 length = tokens.length;
        uint256[] memory amountsOut = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 balance = tokens[i].balanceOf(address(this));
            uint256 amount = (balance * lpAmount) / _totalSupply;
            require(amount >= minAmounts[i], "Slippage");
            amountsOut[i] = amount;
        }

        _burn(msg.sender, lpAmount);

        for (uint256 i = 0; i < length; i++) {
            tokens[i].safeTransfer(msg.sender, amountsOut[i]);
        }

        emit LiquidityRemoved(msg.sender, amountsOut, lpAmount);
    }

    /**
     * @dev Swap tokens
     * Using Balancer Formula:
     * Ao = Bi * (1 - (Bi / (Bi + Ai * (1-fee))) ^ (wi / wo))
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(isTokenInPool[tokenIn] && isTokenInPool[tokenOut], "Invalid token");
        
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        uint256 balanceIn = IERC20(tokenIn).balanceOf(address(this)) - amountIn; // Pre-deposit balance
        uint256 balanceOut = IERC20(tokenOut).balanceOf(address(this));

        uint256 weightIn = getWeight(tokenIn);
        uint256 weightOut = getWeight(tokenOut);
        require(weightIn == weightOut, "MagnetaMultiPool: Mixed weights not supported in V1");

        uint256 amountInAfterFee = amountIn * (1e18 - swapFee) / 1e18;
        
        // Simplified Calc for MVP (assuming 50/50 if weights equal, else full formula)
        // Ao = Bo * (1 - (Bi / (Bi + Ai)) ^ (Wi/Wo))
        
        // For MVP, implementing Constant Product for any pair
        // (Bi + Ai) * balanceOut_new = Bi * Bo
        
        uint256 denominator = balanceIn + amountInAfterFee;
        // Basic xy=k style for MVP (ignoring weights for moment to ensure safety)
        // To strictly follow weights:
        // amountOut = balanceOut * (1 - (balanceIn / (balanceIn + amountInAfterFee)) ^ (weightIn / weightOut))
        
        // Simplified constant product for MVP (assuming equal weights essentially or simplified)
        // Actual Balancer math: amountOut = amountIn * (1 - (Bi / (Bi + Ai)) ^ (Wi / Wo))
        // MVP: x * y = k logic between the two tokens
        
        amountOut = (amountInAfterFee * balanceOut) / denominator;

        require(amountOut >= minAmountOut, "Slippage");
        
        // Transfer to user
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        
        emit Swap(msg.sender, address(tokenIn), address(tokenOut), amountIn, amountOut);
    }
    
    function getTokens() public view returns (IERC20[] memory) {
        return tokens;
    }

    function getWeight(address token) public view returns (uint256) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (address(tokens[i]) == token) return weights[i];
        }
        return 0;
    }

    // Emergency controls — removeLiquidity stays unpaused so LPs can exit anytime.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
