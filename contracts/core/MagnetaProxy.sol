// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title MagnetaProxy
 * @dev Proxy contract for executing swaps via 0x API while collecting fees.
 */
contract MagnetaProxy is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Fee in basis points (100 = 1%)
    uint256 public feeBps = 30; // 0.3%
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    // Fee recipient
    address public feeRecipient;

    // Events
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Execute a swap via 0x API (or any spender/target)
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @param minAmountOut Minimum amount of output tokens expected
     * @param spender Address to approve (0x Router)
     * @param swapTarget Address to call (0x Router)
     * @param swapCallData Calldata for the swap
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address spender,
        address swapTarget,
        bytes calldata swapCallData
    ) external payable nonReentrant {
        require(amountIn > 0, "Invalid amount");
        require(spender != address(0), "Invalid spender");
        require(swapTarget != address(0), "Invalid target");
        require(tokenIn != tokenOut, "Same token");

        uint256 fee = 0;
        uint256 amountToSwap = amountIn;

        // 1. Transfer tokens from user to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // 2. Calculate and deduct fee
        if (feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountToSwap = amountIn - fee;
            // Send fee to recipient
            IERC20(tokenIn).safeTransfer(feeRecipient, fee);
        }

        // 3. Approve 0x Router to spend tokens
        IERC20(tokenIn).forceApprove(spender, amountToSwap);

        // 4. Record balance before swap to verify output
        uint256 initialBalanceOut = IERC20(tokenOut).balanceOf(address(this));

        // 5. Execute Exchange Call
        (bool success, ) = swapTarget.call(swapCallData);
        require(success, "Swap failed");

        // 6. Verify output
        uint256 finalBalanceOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 amountReceived = finalBalanceOut - initialBalanceOut;
        require(amountReceived >= minAmountOut, "Insufficient output amount");

        // 7. Transfer output tokens to user
        IERC20(tokenOut).safeTransfer(msg.sender, amountReceived);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountReceived, fee);
    }

    /**
     * @dev Execute a swap with ETH as input
     */
    function executeSwapETH(
        address tokenOut,
        uint256 minAmountOut,
        address spender,
        address swapTarget,
        bytes calldata swapCallData
    ) external payable nonReentrant {
        require(msg.sender != address(0), "Invalid sender");
        require(msg.value > 0, "Invalid ETH amount");
        
        uint256 amountIn = msg.value;
        uint256 fee = 0;
        uint256 amountToSwap = amountIn;

        // 1. Deduct fee
        if (feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountToSwap = amountIn - fee;
            // Send fee to recipient
            (bool feeSuccess, ) = feeRecipient.call{value: fee}("");
            require(feeSuccess, "Fee transfer failed");
        }

        // 2. Record balance before swap
        uint256 initialBalanceOut = IERC20(tokenOut).balanceOf(address(this));

        // 3. Execute Exchange Call (Send ETH along with call)
        (bool success, ) = swapTarget.call{value: amountToSwap}(swapCallData);
        require(success, "Swap failed");

        // 4. Verify output
        uint256 finalBalanceOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 amountReceived = finalBalanceOut - initialBalanceOut;
        require(amountReceived >= minAmountOut, "Insufficient output amount");

        // 5. Transfer output tokens to user
        IERC20(tokenOut).safeTransfer(msg.sender, amountReceived);

        emit Swapped(msg.sender, address(0), tokenOut, amountIn, amountReceived, fee);
    }

    /**
     * @dev Admin functions
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid recipient");
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, "Fee too high");
        emit FeeBpsUpdated(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    // Allow receiving ETH (required for unwrapping WETH or refunds)
    receive() external payable {}
}
