// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IModule.sol";
import "../interfaces/IMagnetaGateway.sol";

interface IV2RouterSwap {
    function WETH() external pure returns (address);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface ICCTPMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64);
}

/// @title SwapModule
/// @notice Local swap on the chain's V2 router, with optional bridge-out when
///         the user wants the output landed on another chain. For Phase 1 the
///         bridge-out path only supports USDC via CCTP; other assets/routes
///         are expected to be resolved off-chain by the chain-service SDK
///         (LI.FI quote + user-confirmed tx).
/// @dev    This contract handles the SWAP_LOCAL and SWAP_OUT OpTypes. SWAP_OUT
///         is swap-then-CCTP-burn (USDC only); anything else stays off-chain.
contract SwapModule is IModule, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint16 public constant FEE_BPS = 15; // 0.15%

    address public immutable gateway;
    address public immutable router;
    address public immutable usdc;
    address public cctpMessenger;

    event LocalSwap(address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 magnetaFee);
    event SwapOut(address indexed caller, address indexed tokenIn, uint256 amountIn, uint256 usdcOut, uint32 dstDomain, bytes32 recipient, uint256 magnetaFee);
    event CctpMessengerSet(address indexed previous, address indexed current);

    error OnlyGateway();
    error UnsupportedOp();
    error CctpDisabled();
    error EthMismatch();
    error OutputNotUsdc();

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

    function setCctpMessenger(address messenger) external onlyOwner {
        emit CctpMessengerSet(cctpMessenger, messenger);
        cctpMessenger = messenger;
    }

    // ───────────────────── dispatch ─────────────────────

    /// @inheritdoc IModule
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

        if (op == IMagnetaGateway.OpType.SWAP_LOCAL) {
            return _swapLocal(ctx, inner);
        } else if (op == IMagnetaGateway.OpType.SWAP_OUT) {
            return _swapOut(ctx, inner);
        }
        revert UnsupportedOp();
    }

    // ───────────────────── SWAP_LOCAL ─────────────────────

    struct SwapLocalParams {
        address tokenIn;         // address(0) = native
        address tokenOut;        // address(0) = native
        uint256 amountIn;
        uint256 amountOutMin;
        address[] path;
        address recipient;
        uint256 deadline;
    }

    function _swapLocal(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        SwapLocalParams memory p = abi.decode(raw, (SwapLocalParams));
        bool inNative  = (p.tokenIn  == address(0));
        bool outNative = (p.tokenOut == address(0));

        uint256 amountOut;
        if (inNative) {
            if (msg.value != p.amountIn) revert EthMismatch();
            uint256[] memory amts = IV2RouterSwap(router).swapExactETHForTokens{value: p.amountIn}(
                p.amountOutMin, p.path, address(this), p.deadline
            );
            amountOut = amts[amts.length - 1];
        } else {
            IERC20(p.tokenIn).safeTransferFrom(ctx.caller, address(this), p.amountIn);
            IERC20(p.tokenIn).forceApprove(router, p.amountIn);

            if (outNative) {
                uint256[] memory amts = IV2RouterSwap(router).swapExactTokensForETH(
                    p.amountIn, p.amountOutMin, p.path, address(this), p.deadline
                );
                amountOut = amts[amts.length - 1];
            } else {
                uint256[] memory amts = IV2RouterSwap(router).swapExactTokensForTokens(
                    p.amountIn, p.amountOutMin, p.path, address(this), p.deadline
                );
                amountOut = amts[amts.length - 1];
            }
        }

        uint256 magnetaFee = (amountOut * FEE_BPS) / 10_000;
        uint256 adminNet   = amountOut - magnetaFee;

        _sendOut(p.tokenOut, ctx.feeVault, magnetaFee);
        _sendOut(p.tokenOut, p.recipient, adminNet);

        emit LocalSwap(ctx.caller, p.tokenIn, p.tokenOut, p.amountIn, amountOut, magnetaFee);
        return abi.encode(amountOut, magnetaFee);
    }

    // ───────────────────── SWAP_OUT (local swap → CCTP burn) ─────────────────────

    struct SwapOutParams {
        address tokenIn;         // address(0) = native
        uint256 amountIn;
        uint256 amountOutMin;    // in USDC
        address[] path;          // must terminate in `usdc`
        uint32  dstDomain;       // CCTP destination domain
        bytes32 recipient;       // bytes32-padded mint recipient on destination
        uint256 deadline;
    }

    function _swapOut(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        if (cctpMessenger == address(0)) revert CctpDisabled();

        SwapOutParams memory p = abi.decode(raw, (SwapOutParams));
        if (p.path[p.path.length - 1] != usdc) revert OutputNotUsdc();

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

        if (p.tokenIn == address(0)) {
            if (msg.value != p.amountIn) revert EthMismatch();
            IV2RouterSwap(router).swapExactETHForTokens{value: p.amountIn}(
                p.amountOutMin, p.path, address(this), p.deadline
            );
        } else {
            IERC20(p.tokenIn).safeTransferFrom(ctx.caller, address(this), p.amountIn);
            IERC20(p.tokenIn).forceApprove(router, p.amountIn);
            IV2RouterSwap(router).swapExactTokensForTokens(
                p.amountIn, p.amountOutMin, p.path, address(this), p.deadline
            );
        }

        uint256 usdcOut = IERC20(usdc).balanceOf(address(this)) - usdcBefore;
        uint256 magnetaFee = (usdcOut * FEE_BPS) / 10_000;
        uint256 adminNet   = usdcOut - magnetaFee;

        if (magnetaFee > 0) IERC20(usdc).safeTransfer(ctx.feeVault, magnetaFee);

        IERC20(usdc).forceApprove(cctpMessenger, adminNet);
        ICCTPMessenger(cctpMessenger).depositForBurn(adminNet, p.dstDomain, p.recipient, usdc);

        emit SwapOut(ctx.caller, p.tokenIn, p.amountIn, usdcOut, p.dstDomain, p.recipient, magnetaFee);
        return abi.encode(usdcOut, adminNet, magnetaFee);
    }

    // ───────────────────── internals ─────────────────────

    function _sendOut(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "native send failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}
