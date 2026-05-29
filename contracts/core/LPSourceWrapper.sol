// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../interfaces/IMagnetaGateway.sol";

/// @dev IMagnetaGateway doesn't expose the BPS getter (state var made public
///      on the implementation). Read it via this thin interface so we can
///      size the bridged amount to fit the swap output exactly, fee included.
interface IGatewayFees {
    function crossChainValueFeeBps() external view returns (uint16);
}

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
}

/// @title LPSourceWrapper
/// @notice One-tx entry point for cross-chain LP from a NATIVE balance.
///         The user signs a single MetaMask popup, sends only native, and
///         the wrapper:
///           1. Swaps a portion of msg.value into USDC via the V2 router.
///           2. Patches the caller-supplied CrossChainLPParams to use the
///              *actual* swap output as `usdcTotal` (so the destination
///              LPModule sees a consistent amount, and the Gateway's BPS
///              fee is computed against what really arrives).
///           3. Calls `Gateway.sendFanOutValueOp` with that USDC + the
///              reserved native as LZ messaging fee.
///           4. Refunds any leftover native (the Gateway sends excess LZ
///              fee back to msg.sender = this wrapper) and any leftover
///              USDC to the original caller.
///
/// @dev    No state, no privileged role — owner-free. Anyone can use it.
///         Multi-dest fan-out is left out for V1.1; single dest covers the
///         token launcher's needs and keeps the slippage envelope tight.
///         Add the multi-dest variant once the keeper bot proves the
///         single-dest UX in prod.
contract LPSourceWrapper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Magneta v3 Gateway on the same chain.
    address public immutable gateway;
    /// @notice Native USDC on this chain (the asset the Gateway accepts).
    address public immutable usdc;
    /// @notice V2-compatible router used for the native→USDC swap.
    address public immutable router;
    /// @notice WNATIVE (wrapper-of-native) returned by `router.WETH()` —
    ///         WETH on Base/Arb/Eth/Op, WMATIC on Polygon, WBNB on BSC, …
    address public immutable wnative;

    event CrossChainLPDispatched(
        address indexed caller,
        uint32  indexed dstEid,
        uint256 nativeSwapped,
        uint256 usdcReceived,
        uint256 lzNativeFeeReserved
    );

    constructor(address _gateway, address _usdc, address _router) {
        require(_gateway != address(0) && _usdc != address(0) && _router != address(0), "zero address");
        gateway = _gateway;
        usdc = _usdc;
        router = _router;
        wnative = IUniswapV2Router02(_router).WETH();
    }

    /// @notice Quote helper — frontend can call this off-chain to figure out
    ///         the swap slippage envelope before the user clicks. Pure view.
    function quoteNativeToUsdc(uint256 nativeIn) external view returns (uint256 usdcOut) {
        address[] memory path = new address[](2);
        path[0] = wnative;
        path[1] = usdc;
        uint[] memory amounts = IUniswapV2Router02(router).getAmountsOut(nativeIn, path);
        return amounts[amounts.length - 1];
    }

    /// @notice Cross-chain LP for ONE destination, source-side native input.
    /// @param dstEid              LayerZero V2 EID of the destination chain.
    /// @param moduleParams        abi.encoded CrossChainLPParams (token,
    ///                            usdcTotal, tokenShareBps, mins×4, deadline).
    ///                            The wrapper overwrites `usdcTotal` with the
    ///                            actual swap output — the caller's value is
    ///                            used only to pad the struct.
    /// @param lzOptions           LZ V2 options bytes (lzReceiveGas).
    /// @param usdcMinOut          Slippage floor for the native→USDC swap.
    /// @param lzNativeFeeReserve  Native to keep aside for the Gateway's LZ
    ///                            messaging fee. Caller should pass the
    ///                            SDK-quoted fee × an overpay factor (V1
    ///                            uses 2×); excess is refunded by Gateway →
    ///                            this wrapper → caller.
    function createLpCrossChain(
        uint32 dstEid,
        bytes calldata moduleParams,
        bytes calldata lzOptions,
        uint256 usdcMinOut,
        uint256 lzNativeFeeReserve
    ) external payable nonReentrant {
        require(msg.value > lzNativeFeeReserve, "no native to swap");
        uint256 nativeToSwap = msg.value - lzNativeFeeReserve;

        // ─── 1. Swap native → USDC ────────────────────────────────────────
        address[] memory path = new address[](2);
        path[0] = wnative;
        path[1] = usdc;
        uint256[] memory amts = IUniswapV2Router02(router).swapExactETHForTokens{value: nativeToSwap}(
            usdcMinOut,
            path,
            address(this),
            block.timestamp + 600
        );
        uint256 swapOut = amts[amts.length - 1];

        // The Gateway pulls usdcTotal for the CCTP burn AND its BPS fee on
        // top of that (via _collectCrossChainFee). We have `swapOut` USDC
        // total to spend, so we must size the bridged amount so that
        //   bridgedAmount + bridgedAmount × bps / 10_000 == swapOut
        //   bridgedAmount = swapOut × 10_000 / (10_000 + bps)
        // The exact bps lives on the Gateway as a mutable setting; read it.
        uint16 bps = IGatewayFees(gateway).crossChainValueFeeBps();
        uint256 usdcReceived = (swapOut * 10_000) / (10_000 + uint256(bps));

        // ─── 2. Patch moduleParams.usdcTotal in place ─────────────────────
        // CrossChainLPParams layout (abi.encode of a struct/tuple):
        //   offset  0: token            (address, left-padded uint256)
        //   offset 32: usdcTotal        (uint256)
        //   offset 64: tokenShareBps    (uint16, padded)
        //   offset 96: amountTokenMin   (uint256)
        //   offset 128: amountNativeMin (uint256)
        //   offset 160: lpAmountTokenMin
        //   offset 192: lpAmountNativeMin
        //   offset 224: deadline
        // We rewrite the 32 bytes at offset [32, 64) with usdcReceived.
        bytes memory patched = abi.encodePacked(moduleParams); // copy to memory
        assembly {
            // patched layout in memory: 32-byte length prefix, then bytes.
            // First field starts at patched + 32. usdcTotal is the SECOND
            // field, so offset 32 from the start of the data = patched + 64.
            mstore(add(patched, 64), usdcReceived)
        }

        // ─── 3. Forward to Gateway ─────────────────────────────────────────
        // The Gateway pulls `usdcReceived` for the CCTP burn AND its BPS
        // markup on top (via _collectCrossChainFee). Approve max so both
        // transferFroms succeed; any unused allowance is harmless because
        // we hold zero USDC after the call (the swap output flows straight
        // through to CCTP).
        IERC20(usdc).forceApprove(gateway, type(uint256).max);

        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = dstEid;
        bytes[] memory moduleParamsArr = new bytes[](1);
        moduleParamsArr[0] = patched;
        uint256[] memory usdcAmounts = new uint256[](1);
        usdcAmounts[0] = usdcReceived;

        IMagnetaGateway(gateway).sendFanOutValueOp{value: lzNativeFeeReserve}(
            dstEids,
            IMagnetaGateway.OpType.CREATE_LP,
            moduleParamsArr,
            usdcAmounts,
            lzOptions
        );

        emit CrossChainLPDispatched(msg.sender, dstEid, nativeToSwap, usdcReceived, lzNativeFeeReserve);

        // ─── 4. Refund any leftover native (Gateway refunds excess LZ to
        //       msg.sender = this contract) and any stray USDC. ────────────
        uint256 nativeLeft = address(this).balance;
        if (nativeLeft > 0) {
            (bool ok, ) = msg.sender.call{value: nativeLeft}("");
            require(ok, "native refund failed");
        }
        uint256 usdcLeft = IERC20(usdc).balanceOf(address(this));
        if (usdcLeft > 0) {
            IERC20(usdc).safeTransfer(msg.sender, usdcLeft);
        }
    }

    /// @dev Accept the Gateway's native fee refund.
    receive() external payable {}
}
