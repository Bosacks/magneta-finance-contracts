// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal mock for MagnetaProxy tests — raw swap with no AMM logic.
contract MockSimpleRouter {
    function swap(address tokenOut, uint256 amountOut, address recipient) external payable {
        if (tokenOut != address(0)) {
            IERC20(tokenOut).transfer(recipient, amountOut);
        } else {
            payable(recipient).transfer(amountOut);
        }
    }

    receive() external payable {}
}
