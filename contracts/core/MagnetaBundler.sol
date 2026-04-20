// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2Router02 {
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);

    function WETH() external pure returns (address);
}

contract MagnetaBundler is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    address public router;

    event BundleBuy(address indexed sender, address token, uint256 totalEthAmount, uint256 successCount);
    event BundleSell(address indexed sender, address token, uint256 totalTokenAmount, uint256 successCount);

    constructor(address _router) {
        require(_router != address(0), "Invalid router");
        router = _router;
    }

    receive() external payable {}

    // --- Core Bundling Logic ---

    /**
     * @dev Buy a specific token using ETH for multiple recipient addresses in one transaction.
     * @param token The token address to buy.
     * @param amountOutMin The minimum amount of tokens to receive per buy (slippage protection).
     * @param recipients The addresses that will receive the purchased tokens.
     * @param ethAmounts The amount of ETH to spend for each recipient.
     */
    function bundleBuy(
        address token,
        uint256 amountOutMin,
        address[] calldata recipients,
        uint256[] calldata ethAmounts
    ) external payable nonReentrant whenNotPaused {
        require(recipients.length == ethAmounts.length, "Arrays length mismatch");
        require(token != address(0), "Invalid token");
        
        uint256 totalRequired = 0;
        for (uint i = 0; i < ethAmounts.length; i++) {
            totalRequired += ethAmounts[i];
        }
        require(msg.value >= totalRequired, "Insufficient ETH sent");

        address[] memory path = new address[](2);
        path[0] = IUniswapV2Router02(router).WETH();
        path[1] = token;

        uint256 successCount = 0;
        uint256 ethSpent = 0;

        for (uint i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address");
            try IUniswapV2Router02(router).swapExactETHForTokens{value: ethAmounts[i]}(
                amountOutMin, // Note: Simplification used here. In prod, strict per-recipient slippage required.
                path,
                recipients[i],
                block.timestamp
            ) {
                successCount++;
                ethSpent += ethAmounts[i];
            } catch {
                // If a swap fails, we continue. 
                // In production, you might want to refund the ETH for failed swaps to the sender.
                // For simplified implementation, remaining ETH stays in contract for sender to rescue.
            }
        }

        // Refund excess ETH if any (from failures or overpayment)
        uint256 unspentEth = msg.value - ethSpent;
        if (unspentEth > 0) {
            (bool success, ) = msg.sender.call{value: unspentEth}("");
            require(success, "ETH refund failed");
        }

        emit BundleBuy(msg.sender, token, totalRequired, successCount);
    }

    /**
     * @dev Sell multiple tokens for ETH in one transaction.
     * @param tokens List of token addresses to sell.
     * @param amounts List of token amounts to sell.
     * @param amountsOutMin List of minimum ETH amounts to receive (slippage).
     */
    function bundleSell(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata amountsOutMin
    ) external nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        require(tokens.length == amounts.length && amounts.length == amountsOutMin.length, "Arrays length mismatch");

        uint256 totalEthReceived = 0;
        uint256 successCount = 0;

        address[] memory path = new address[](2);
        path[1] = IUniswapV2Router02(router).WETH();

        for (uint i = 0; i < tokens.length; i++) {
            // transfer tokens from user to contract
            IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            
            // approve router
            IERC20(tokens[i]).forceApprove(router, amounts[i]);

            path[0] = tokens[i];

            try IUniswapV2Router02(router).swapExactTokensForETH(
                amounts[i],
                amountsOutMin[i],
                path,
                msg.sender, // Send ETH directly to user
                block.timestamp
            ) returns (uint[] memory resultAmounts) {
                totalEthReceived += resultAmounts[resultAmounts.length - 1];
                successCount++;
            } catch {
                // If swap fails, return tokens to user
                 IERC20(tokens[i]).safeTransfer(msg.sender, amounts[i]);
            }
        }

        emit BundleSell(msg.sender, address(0), totalEthReceived, successCount);
    }

    // --- Advanced Tools ---

    /**
     * @dev Buy a token and immediately sell it back in the same transaction (Volume Generation).
     * @param token The token to brush volume for.
     * @param ethAmount The amount of ETH to use for buying.
     * @param minEthReturned The minimum ETH expected back (slippage).
     */
    function atomicVolumeBrush(
        address token,
        uint256 ethAmount,
        uint256 minEthReturned,
        uint256 minTokensExpected
    ) external payable nonReentrant whenNotPaused {
        require(msg.value >= ethAmount, "Insufficient ETH");

        address[] memory buyPath = new address[](2);
        buyPath[0] = IUniswapV2Router02(router).WETH();
        buyPath[1] = token;

        // 1. Buy Tokens
        uint[] memory amounts = IUniswapV2Router02(router).swapExactETHForTokens{value: ethAmount}(
            minTokensExpected,
            buyPath,
            address(this),
            block.timestamp
        );
        uint256 tokenAmount = amounts[1];

        // 2. Sell Tokens
        IERC20(token).forceApprove(router, tokenAmount);
        
        address[] memory sellPath = new address[](2);
        sellPath[0] = token;
        sellPath[1] = IUniswapV2Router02(router).WETH();

        uint[] memory returnAmounts = IUniswapV2Router02(router).swapExactTokensForETH(
            tokenAmount,
            minEthReturned,
            sellPath,
            msg.sender,
            block.timestamp
        );

        emit BundleSell(msg.sender, token, returnAmounts[1], 1);
    }

    /**
     * @dev Sell one token and use the proceeds to bundle buy another token.
     * @param sellToken Token to sell.
     * @param sellAmount Amount of token to sell.
     * @param minEthFromSell Minimum ETH to receive from the sell (slippage protection).
     * @param buyToken Token to buy.
     * @param minTokensPerBuy Minimum tokens per recipient buy (slippage protection).
     * @param recipients List of recipients for the buy.
     * @param buyAmounts List of ETH amounts to spend per recipient (must sum < proceeds).
     */
    function sellAndBundleBuy(
        address sellToken,
        uint256 sellAmount,
        uint256 minEthFromSell,
        address buyToken,
        uint256 minTokensPerBuy,
        address[] calldata recipients,
        uint256[] calldata buyAmounts
    ) external nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        require(recipients.length == buyAmounts.length, "Arrays length mismatch");
        // 1. Transfer Sell Token
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmount);
        IERC20(sellToken).forceApprove(router, sellAmount);

        // 2. Sell for ETH
        address[] memory sellPath = new address[](2);
        sellPath[0] = sellToken;
        sellPath[1] = IUniswapV2Router02(router).WETH();

        uint[] memory amounts = IUniswapV2Router02(router).swapExactTokensForETH(
            sellAmount,
            minEthFromSell,
            sellPath,
            address(this),
            block.timestamp
        );
        uint256 ethProceeds = amounts[1];

        // 3. Bundle Buy Logic
        uint256 totalRequired = 0;
        for (uint i = 0; i < buyAmounts.length; i++) {
            totalRequired += buyAmounts[i];
        }
        require(ethProceeds >= totalRequired, "Insufficient sell proceeds");

        address[] memory buyPath = new address[](2);
        buyPath[0] = IUniswapV2Router02(router).WETH();
        buyPath[1] = buyToken;

        uint256 successCount = 0;
        uint256 ethSpent = 0;
        for (uint i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address recipient");
            try IUniswapV2Router02(router).swapExactETHForTokens{value: buyAmounts[i]}(
                minTokensPerBuy,
                buyPath,
                recipients[i],
                block.timestamp
            ) {
                successCount++;
                ethSpent += buyAmounts[i];
            } catch {}
        }

        // Refund remaining ETH
        uint256 unspentEth = ethProceeds - ethSpent;
        if (unspentEth > 0) {
            (bool success, ) = msg.sender.call{value: unspentEth}("");
            require(success, "Refund failed");
        }
    }

    /**
     * @dev Disperse ETH to multiple recipients (for funding wallets).
     * @param recipients List of recipient addresses.
     * @param values List of ETH amounts (in wei) for each recipient.
     */
    function disperseEther(address[] calldata recipients, uint256[] calldata values) external payable nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        require(recipients.length == values.length, "Arrays length mismatch");
        
        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; i++)
            total += values[i];
        
        require(total <= msg.value, "Insufficient ETH sent");

        uint256 ethSpent = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address");
            (bool success, ) = recipients[i].call{value: values[i]}("");
            require(success, "Transfer failed"); // Simple transfer failure revert whole tx
            ethSpent += values[i];
        }

        uint256 unspentEth = msg.value - ethSpent;
        if (unspentEth > 0) {
             (bool success, ) = msg.sender.call{value: unspentEth}("");
             require(success, "Refund failed");
        }
    }

    // --- Admin ---

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        router = _router;
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function rescueETH() external onlyOwner {
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
