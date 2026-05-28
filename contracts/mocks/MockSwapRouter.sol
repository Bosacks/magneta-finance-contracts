// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IMagnetaSwap.sol";

/// @dev Mock MagnetaSwap implementing IMagnetaSwap with 1:1 token swaps.
/// Used for unit tests — no real AMM logic.
contract MockSwapRouter is IMagnetaSwap {
    using SafeERC20 for IERC20;

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 /* amountOutMin */,
        address to,
        uint256 /* deadline */
    ) external override returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn; // 1:1 for tests
        IERC20(tokenOut).safeTransfer(to, amountOut);
        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, to);
    }

    function getAmountOut(
        address /* tokenIn */,
        address /* tokenOut */,
        uint256 amountIn
    ) external pure override returns (uint256) {
        return amountIn; // 1:1
    }

    receive() external payable {}
}
