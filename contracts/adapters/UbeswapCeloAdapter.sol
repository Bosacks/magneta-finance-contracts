// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title UbeswapCeloAdapter
/// @notice Uniswap V2 router facade over Ubeswap on Celo. Ubeswap is a V2 fork but
///         exposes no native-token entrypoints because CELO is itself an ERC20 at
///         the precompile 0x471EcE3750Da237f93B8E339c536989b8978a438. This adapter
///         synthesizes `WETH()`, `addLiquidityETH`, `swapExactETHForTokens`, and
///         `swapExactTokensForETH` by treating `msg.value` as CELO-ERC20 and
///         forwarding to Ubeswap's token-to-token router.
/// @dev    Sentinelle Multi-AI 2026-05-22 hardening:
///         - SC06 SafeERC20 wrappers instead of raw IERC20.
///         - SC02 native dust refund tracked via `msg.value - amountUsed` rather
///           than `balanceOf(this)`, so a donation cannot drain into the caller.
///         - SC05 constructor zero-router check.
///         - SC08 nonReentrant on mutating entrypoints.

interface IUbeswapFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IUbeswapRouter {
    function factory() external view returns (address);
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256, uint256, uint256);
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
}

contract UbeswapCeloAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice CELO native token, exposed as an ERC20 via the GoldToken precompile.
    address public constant CELO = 0x471EcE3750Da237f93B8E339c536989b8978a438;

    IUbeswapRouter public immutable ube;
    address public immutable factory;
    address public immutable WETH;

    constructor(address _ube) {
        require(_ube != address(0), "UbeAdapter: zero router");
        ube = IUbeswapRouter(_ube);
        factory = IUbeswapRouter(_ube).factory();
        require(factory != address(0), "UbeAdapter: bad router");
        WETH = CELO;
    }

    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountBDesired);
        IERC20(tokenA).forceApprove(address(ube), amountADesired);
        IERC20(tokenB).forceApprove(address(ube), amountBDesired);
        (amountA, amountB, liquidity) = ube.addLiquidity(
            tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline
        );
        if (amountADesired > amountA) IERC20(tokenA).safeTransfer(msg.sender, amountADesired - amountA);
        if (amountBDesired > amountB) IERC20(tokenB).safeTransfer(msg.sender, amountBDesired - amountB);
        IERC20(tokenA).forceApprove(address(ube), 0);
        IERC20(tokenB).forceApprove(address(ube), 0);
    }

    /// @notice `msg.value` arrives as native CELO, which (being the precompile) is already
    ///         an ERC20 balance on this contract — no wrap step needed.
    function addLiquidityETH(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable nonReentrant returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountTokenDesired);
        IERC20(token).forceApprove(address(ube), amountTokenDesired);
        IERC20(CELO).forceApprove(address(ube), msg.value);
        (amountToken, amountETH, liquidity) = ube.addLiquidity(
            token, CELO,
            amountTokenDesired, msg.value,
            amountTokenMin, amountETHMin,
            to, deadline
        );
        if (amountTokenDesired > amountToken) IERC20(token).safeTransfer(msg.sender, amountTokenDesired - amountToken);
        IERC20(token).forceApprove(address(ube), 0);
        IERC20(CELO).forceApprove(address(ube), 0);

        // Refund only the call's unused CELO (msg.value - amountETH), not the
        // adapter's CELO balance, which would otherwise drain donations.
        uint256 refund = msg.value - amountETH;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "UbeAdapter: celo refund failed");
        }
    }

    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        address pair = IUbeswapFactory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "no pair");
        IERC20(pair).safeTransferFrom(msg.sender, address(this), liquidity);
        IERC20(pair).forceApprove(address(ube), liquidity);
        (amountA, amountB) = ube.removeLiquidity(
            tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline
        );
        IERC20(pair).forceApprove(address(ube), 0);
    }

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).forceApprove(address(ube), amountIn);
        amounts = ube.swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
        IERC20(path[0]).forceApprove(address(ube), 0);
    }

    /// @notice Caller passes path starting with WETH (CELO precompile). `msg.value`
    ///         is already the ERC20 balance of this contract for CELO.
    function swapExactETHForTokens(
        uint256 amountOutMin, address[] calldata path,
        address to, uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory amounts) {
        require(path.length >= 2 && path[0] == CELO, "path must start with CELO");
        IERC20(CELO).forceApprove(address(ube), msg.value);
        amounts = ube.swapExactTokensForTokens(msg.value, amountOutMin, path, to, deadline);
        IERC20(CELO).forceApprove(address(ube), 0);
    }

    /// @notice Caller passes path ending with WETH (CELO precompile). Adapter pulls
    ///         the input token, swaps to CELO-ERC20 held here, then forwards as
    ///         native value to `to`.
    function swapExactTokensForETH(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        require(path.length >= 2 && path[path.length - 1] == CELO, "path must end with CELO");
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).forceApprove(address(ube), amountIn);
        amounts = ube.swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), deadline);
        IERC20(path[0]).forceApprove(address(ube), 0);

        uint256 out = amounts[amounts.length - 1];
        (bool ok, ) = to.call{value: out}("");
        require(ok, "UbeAdapter: celo send failed");
    }

    receive() external payable {}
}
