// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./AdapterPull.sol";

/// @title TraderJoeAvaxAdapter
/// @notice Thin adapter exposing the Uniswap V2 router interface (WETH, addLiquidityETH, ...)
///         on top of TraderJoe V1 on Avalanche, which renames native-token functions
///         (AVAX instead of ETH) and the wrapper getter (WAVAX instead of WETH).
///         Signatures are identical; only selectors differ.
/// @dev    Stateless forwarder. Pulls tokens via SafeERC20.safeTransferFrom, approves
///         Joe via forceApprove (USDT-compatible), delegates, then refunds the call's
///         msg.value surplus (NOT `address(this).balance`) back to msg.sender.
///
///         Sentinelle Multi-AI 2026-05-22 hardening:
///         - SC06: switched raw IERC20.transfer/transferFrom/approve to SafeERC20
///           wrappers (Lendf.me $25M pattern).
///         - SC03: native refund now tracks `msg.value - actually-spent` rather than
///           `address(this).balance` — eliminates the donation/leftover-balance drain.
///         - SC05: constructor + per-op zero-address inputs validated.
///         - SC08: addLiquidity / addLiquidityETH / swap* gated by nonReentrant.

interface IJoeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IJoeRouter {
    function factory() external view returns (address);
    function WAVAX() external view returns (address);
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256, uint256, uint256);
    function addLiquidityAVAX(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountAVAXMin,
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
    function swapExactAVAXForTokens(
        uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external payable returns (uint256[] memory);
    function swapExactTokensForAVAX(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory);
}

contract TraderJoeAvaxAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using AdapterPull for IERC20;

    IJoeRouter public immutable joe;
    address public immutable factory;
    address public immutable WETH;

    constructor(address _joe) {
        require(_joe != address(0), "TJoeAdapter: zero router");
        joe = IJoeRouter(_joe);
        factory = IJoeRouter(_joe).factory();
        WETH = IJoeRouter(_joe).WAVAX();
        require(factory != address(0) && WETH != address(0), "TJoeAdapter: bad router");
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
        IERC20(tokenA).forceApprove(address(joe), gotA);
        IERC20(tokenB).forceApprove(address(joe), gotB);
        (amountA, amountB, liquidity) = joe.addLiquidity(
            tokenA, tokenB, gotA, gotB, amountAMin, amountBMin, to, deadline
        );
        // Refund against what was received, so the adapter stays balance-neutral.
        if (gotA > amountA) IERC20(tokenA).safeTransfer(msg.sender, gotA - amountA);
        if (gotB > amountB) IERC20(tokenB).safeTransfer(msg.sender, gotB - amountB);
        // Clear any residual allowance left by USDT-style tokens.
        IERC20(tokenA).forceApprove(address(joe), 0);
        IERC20(tokenB).forceApprove(address(joe), 0);
    }

    function addLiquidityETH(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable nonReentrant returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        // Token leg: same measured-pull rule as addLiquidity — the native leg

        // is msg.value and needs no measuring.

        uint256 gotToken = IERC20(token).pullMeasured(msg.sender, amountTokenDesired);
        IERC20(token).forceApprove(address(joe), gotToken);
        (amountToken, amountETH, liquidity) = joe.addLiquidityAVAX{value: msg.value}(
            token, gotToken, amountTokenMin, amountETHMin, to, deadline
        );
        if (gotToken > amountToken) IERC20(token).safeTransfer(msg.sender, gotToken - amountToken);
        IERC20(token).forceApprove(address(joe), 0);

        // Refund only the call's unused msg.value, not address(this).balance,
        // to avoid draining any native held on this contract by donation /
        // accidental transfer (Sentinelle HIGH SC03 2026-05-22).
        uint256 refund = msg.value - amountETH;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "TJoeAdapter: refund failed");
        }
    }

    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        address pair = IJoeFactory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "no pair");
        IERC20(pair).safeTransferFrom(msg.sender, address(this), liquidity);
        IERC20(pair).forceApprove(address(joe), liquidity);
        (amountA, amountB) = joe.removeLiquidity(
            tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline
        );
        IERC20(pair).forceApprove(address(joe), 0);
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        // Same measured-pull rule as the liquidity paths. Approving and
        // instructing the router to spend amountIn when a fee-on-transfer
        // token delivered less lets the router take the shortfall out of any
        // residual balance this adapter holds — the remediation applied to
        // addLiquidity but originally missed here (Sentinelleai F-1).
        uint256 gotIn = IERC20(path[0]).pullMeasured(msg.sender, amountIn);
        IERC20(path[0]).forceApprove(address(joe), gotIn);
        amounts = joe.swapExactTokensForTokens(gotIn, amountOutMin, path, to, deadline);
        IERC20(path[0]).forceApprove(address(joe), 0);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory amounts) {
        amounts = joe.swapExactAVAXForTokens{value: msg.value}(amountOutMin, path, to, deadline);
    }

    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        // Same measured-pull rule as the liquidity paths. Approving and
        // instructing the router to spend amountIn when a fee-on-transfer
        // token delivered less lets the router take the shortfall out of any
        // residual balance this adapter holds — the remediation applied to
        // addLiquidity but originally missed here (Sentinelleai F-1).
        uint256 gotIn = IERC20(path[0]).pullMeasured(msg.sender, amountIn);
        IERC20(path[0]).forceApprove(address(joe), gotIn);
        amounts = joe.swapExactTokensForAVAX(gotIn, amountOutMin, path, to, deadline);
        IERC20(path[0]).forceApprove(address(joe), 0);
    }

    receive() external payable {}
}
