// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./AdapterPull.sol";

/// @title DragonSwapSeiAdapter
/// @notice Thin adapter exposing the Uniswap V2 router interface (WETH, addLiquidityETH, ...)
///         on top of DragonSwap V1 on Sei. Signatures match UniV2; only selectors differ
///         (addLiquiditySEI vs addLiquidityETH, etc.).
/// @dev    Sentinelle Multi-AI 2026-05-22: SafeERC20 wrappers + msg.value-relative
///         refund + constructor zero check + nonReentrant.

interface IDragonFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IDragonRouter {
    function factory() external view returns (address);
    function WSEI() external view returns (address);
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256, uint256, uint256);
    function addLiquiditySEI(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountSEIMin,
        address to, uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256, uint256);
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory);
    function swapExactSEIForTokens(
        uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external payable returns (uint256[] memory);
    function swapExactTokensForSEI(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory);
}

contract DragonSwapSeiAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using AdapterPull for IERC20;

    IDragonRouter public immutable dragon;
    address public immutable factory;
    address public immutable WETH;

    constructor(address _dragon) {
        require(_dragon != address(0), "DragonAdapter: zero router");
        dragon = IDragonRouter(_dragon);
        factory = IDragonRouter(_dragon).factory();
        WETH = IDragonRouter(_dragon).WSEI();
        require(factory != address(0) && WETH != address(0), "DragonAdapter: bad router");
    }

    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Forward what actually ARRIVED, not what was asked for: a
        // fee-on-transfer token delivers less, and approving the requested
        // figure would have the router pull more than this call brought in.
        uint256 gotA = IERC20(tokenA).pullMeasured(msg.sender, amountADesired);
        uint256 gotB = IERC20(tokenB).pullMeasured(msg.sender, amountBDesired);
        IERC20(tokenA).forceApprove(address(dragon), gotA);
        IERC20(tokenB).forceApprove(address(dragon), gotB);
        (amountA, amountB, liquidity) = dragon.addLiquidity(
            tokenA, tokenB, gotA, gotB, amountAMin, amountBMin, to, deadline
        );
        // Refund against what was received, so the adapter stays balance-neutral.
        if (gotA > amountA) IERC20(tokenA).safeTransfer(msg.sender, gotA - amountA);
        if (gotB > amountB) IERC20(tokenB).safeTransfer(msg.sender, gotB - amountB);
        IERC20(tokenA).forceApprove(address(dragon), 0);
        IERC20(tokenB).forceApprove(address(dragon), 0);
    }

    function addLiquidityETH(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable nonReentrant returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        // Token leg: same measured-pull rule as addLiquidity — the native leg

        // is msg.value and needs no measuring.

        uint256 gotToken = IERC20(token).pullMeasured(msg.sender, amountTokenDesired);
        IERC20(token).forceApprove(address(dragon), gotToken);
        (amountToken, amountETH, liquidity) = dragon.addLiquiditySEI{value: msg.value}(
            token, gotToken, amountTokenMin, amountETHMin, to, deadline
        );
        if (gotToken > amountToken) IERC20(token).safeTransfer(msg.sender, gotToken - amountToken);
        IERC20(token).forceApprove(address(dragon), 0);

        // Refund only the unused msg.value, not address(this).balance
        // (Sentinelle HIGH SC03 — donation-drain vector).
        uint256 refund = msg.value - amountETH;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "DragonAdapter: refund failed");
        }
    }

    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        address pair = IDragonFactory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "no pair");
        IERC20(pair).safeTransferFrom(msg.sender, address(this), liquidity);
        IERC20(pair).forceApprove(address(dragon), liquidity);
        (amountA, amountB) = dragon.removeLiquidity(
            tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline
        );
        IERC20(pair).forceApprove(address(dragon), 0);
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).forceApprove(address(dragon), amountIn);
        amounts = dragon.swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
        IERC20(path[0]).forceApprove(address(dragon), 0);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory amounts) {
        amounts = dragon.swapExactSEIForTokens{value: msg.value}(amountOutMin, path, to, deadline);
    }

    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).forceApprove(address(dragon), amountIn);
        amounts = dragon.swapExactTokensForSEI(amountIn, amountOutMin, path, to, deadline);
        IERC20(path[0]).forceApprove(address(dragon), 0);
    }

    receive() external payable {}
}
