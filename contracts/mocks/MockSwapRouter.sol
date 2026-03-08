// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockSwapRouter {
    function swap(address tokenOut, uint256 amountOut, address recipient) external payable {
        if (tokenOut != address(0)) {
            IERC20(tokenOut).transfer(recipient, amountOut);
        } else {
            payable(recipient).transfer(amountOut);
        }
    }
    
    // Allow receiving ETH
    receive() external payable {}
}
