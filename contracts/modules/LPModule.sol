// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IModule.sol";
import "../interfaces/IMagnetaGateway.sol";

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @title LPModule
/// @notice Handles CREATE_LP / REMOVE_LP / BURN_LP / CREATE_LP_AND_BUY on the
///         local chain using a V2-compatible DEX router (BaseSwap on Base,
///         SushiSwap on Arbitrum, QuickSwap on Polygon, PancakeSwap on BSC…).
/// @dev    Called exclusively by MagnetaGateway. Pulls user tokens/native via
///         the gateway context caller. Magneta markup (0.15% of value) is
///         taken in USDC and sent to the gateway feeVault.
contract LPModule is IModule, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint16 public constant FEE_BPS = 15;                   // 0.15%
    uint256 public constant BURN_ADDRESS_SALT = 0;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable gateway;
    address public immutable router;
    address public immutable usdc;

    event LPCreated(address indexed caller, address indexed token, uint256 amountToken, uint256 amountETH, uint256 liquidity);
    event LPRemoved(address indexed caller, address indexed token, uint256 liquidity, uint256 amountToken, uint256 amountETH);
    event LPBurned(address indexed caller, address indexed token, uint256 liquidity);

    error OnlyGateway();
    error InvalidParams();
    error UnsupportedOp();

    constructor(address _gateway, address _router, address _usdc) {
        require(_gateway != address(0) && _router != address(0) && _usdc != address(0), "zero address");
        gateway = _gateway;
        router = _router;
        usdc = _usdc;
    }

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    /// @inheritdoc IModule
    /// @dev Dispatches by the first byte of `params`: it carries the OpType so
    ///      the same module can serve the 4 LP ops without extra indirection.
    function execute(Context calldata ctx, bytes calldata params)
        external
        payable
        override
        onlyGateway
        nonReentrant
        returns (bytes memory result)
    {
        IMagnetaGateway.OpType op = IMagnetaGateway.OpType(uint8(params[0]));
        bytes calldata inner = params[1:];

        if (op == IMagnetaGateway.OpType.CREATE_LP) {
            return _createLP(ctx, inner);
        } else if (op == IMagnetaGateway.OpType.REMOVE_LP) {
            return _removeLP(ctx, inner);
        } else if (op == IMagnetaGateway.OpType.BURN_LP) {
            return _burnLP(ctx, inner);
        } else if (op == IMagnetaGateway.OpType.CREATE_LP_AND_BUY) {
            return _createLPAndBuy(ctx, inner);
        }
        revert UnsupportedOp();
    }

    // ───────────────────── ops ─────────────────────

    struct CreateLPParams {
        address token;
        uint256 tokenAmount;
        uint256 ethAmount;       // in wei; must equal msg.value
        uint256 amountTokenMin;
        uint256 amountETHMin;
        uint256 usdcFee;         // 0.15% of USD value; pulled from caller in USDC
        uint256 deadline;
    }

    function _createLP(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        CreateLPParams memory p = abi.decode(raw, (CreateLPParams));
        require(msg.value == p.ethAmount, "eth mismatch");

        _collectFee(ctx, p.usdcFee);

        IERC20(p.token).safeTransferFrom(ctx.caller, address(this), p.tokenAmount);
        IERC20(p.token).forceApprove(router, p.tokenAmount);

        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IUniswapV2Router02(router).addLiquidityETH{value: p.ethAmount}(
            p.token,
            p.tokenAmount,
            p.amountTokenMin,
            p.amountETHMin,
            ctx.caller,
            p.deadline
        );

        emit LPCreated(ctx.caller, p.token, amountToken, amountETH, liquidity);
        return abi.encode(amountToken, amountETH, liquidity);
    }

    struct RemoveLPParams {
        address token;
        uint256 liquidity;
        uint256 amountTokenMin;
        uint256 amountETHMin;
        uint256 usdcFee;
        uint256 deadline;
    }

    function _removeLP(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        RemoveLPParams memory p = abi.decode(raw, (RemoveLPParams));
        _collectFee(ctx, p.usdcFee);

        address weth = IUniswapV2Router02(router).WETH();
        address pair = IUniswapV2Factory(IUniswapV2Router02(router).factory()).getPair(p.token, weth);
        require(pair != address(0), "no pair");

        IERC20(pair).safeTransferFrom(ctx.caller, address(this), p.liquidity);
        IERC20(pair).forceApprove(router, p.liquidity);

        (uint256 amountToken, uint256 amountETH) = IUniswapV2Router02(router).removeLiquidity(
            p.token,
            weth,
            p.liquidity,
            p.amountTokenMin,
            p.amountETHMin,
            ctx.caller,
            p.deadline
        );

        emit LPRemoved(ctx.caller, p.token, p.liquidity, amountToken, amountETH);
        return abi.encode(amountToken, amountETH);
    }

    struct BurnLPParams {
        address token;
        uint256 liquidity;
    }

    function _burnLP(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        BurnLPParams memory p = abi.decode(raw, (BurnLPParams));
        address weth = IUniswapV2Router02(router).WETH();
        address pair = IUniswapV2Factory(IUniswapV2Router02(router).factory()).getPair(p.token, weth);
        require(pair != address(0), "no pair");

        IERC20(pair).safeTransferFrom(ctx.caller, DEAD, p.liquidity);
        emit LPBurned(ctx.caller, p.token, p.liquidity);
        return abi.encode(p.liquidity);
    }

    struct CreateLPAndBuyParams {
        CreateLPParams lp;
        uint256 buyEth;              // extra ETH used for first buy, held in msg.value along with lp.ethAmount
        uint256 buyAmountOutMin;
        address buyRecipient;
    }

    function _createLPAndBuy(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        CreateLPAndBuyParams memory p = abi.decode(raw, (CreateLPAndBuyParams));
        require(msg.value == p.lp.ethAmount + p.buyEth, "eth mismatch");

        _collectFee(ctx, p.lp.usdcFee);

        IERC20(p.lp.token).safeTransferFrom(ctx.caller, address(this), p.lp.tokenAmount);
        IERC20(p.lp.token).forceApprove(router, p.lp.tokenAmount);

        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IUniswapV2Router02(router).addLiquidityETH{value: p.lp.ethAmount}(
            p.lp.token,
            p.lp.tokenAmount,
            p.lp.amountTokenMin,
            p.lp.amountETHMin,
            ctx.caller,
            p.lp.deadline
        );

        address[] memory path = new address[](2);
        path[0] = IUniswapV2Router02(router).WETH();
        path[1] = p.lp.token;
        uint256[] memory amounts = IUniswapV2Router02(router).swapExactETHForTokens{value: p.buyEth}(
            p.buyAmountOutMin,
            path,
            p.buyRecipient,
            p.lp.deadline
        );

        emit LPCreated(ctx.caller, p.lp.token, amountToken, amountETH, liquidity);
        return abi.encode(amountToken, amountETH, liquidity, amounts[amounts.length - 1]);
    }

    // ───────────────────── fees ─────────────────────

    /// @dev Pulls `amount` USDC from ctx.caller into the gateway's feeVault.
    ///      Caller must have approved this module for at least `amount` USDC.
    ///      Skips on zero to allow owner-sponsored or fee-less future ops.
    function _collectFee(Context calldata ctx, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(usdc).safeTransferFrom(ctx.caller, ctx.feeVault, amount);
    }
}
