// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IUniswapV2Router02 {
    function WETH() external view returns (address);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/**
 * @title MagnetaXChainLpReceiver
 * @notice Permissionless destination-chain receiver for the LI.FI cross-chain
 *         LP flow. LI.FI's executor bridges the user's funds to the destination
 *         chain and calls this contract with the bridged NATIVE gas token as
 *         msg.value; the contract atomically builds a token/native V2 LP
 *         position and sends the LP tokens (plus any dust) to the user.
 *
 * @dev    Design constraints (validated 2026-05-24, memory:
 *         project_crosschain_lp_bridge_strategy):
 *           - NATIVE-ONLY input. LI.FI delivers the chain's native gas token, so
 *             there is exactly one input asset and one swap (half → token), then
 *             addLiquidityETH with the remaining half. No USDC/ERC20 entrypoint:
 *             a single asset means no per-token approval surface to pull from.
 *           - NON-CUSTODIAL. Funds arrive as msg.value and leave in the same tx
 *             as LP tokens + dust to `to`. The contract holds nothing between
 *             calls; any residual is a donation, never user principal.
 *           - PERMISSIONLESS but TRUST-MINIMAL. Anyone (the LI.FI executor) may
 *             call addLiquidityNative for any token/recipient, but every slippage
 *             bound (minTokenOut, minTokenLp, minNativeLp) and the deadline is
 *             caller-supplied — there is no unprotected swap and no oracle to
 *             manipulate. The router is immutable and set at deploy.
 *           - DONATION-SAFE. Native refund is computed from a tx-scoped snapshot
 *             (balance − msg.value), and token refund from the measured swap
 *             delta, so a griefer pre-funding the contract cannot inflate or
 *             drain a refund. Token amounts are measured by balance delta, which
 *             also tolerates fee-on-transfer tokens.
 *
 *         This contract is deployed once per EVM chain (router + WETH differ per
 *         chain) and registered as the LI.FI destination call target in the
 *         frontend's cross-chain LP quote.
 */
contract MagnetaXChainLpReceiver is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice V2-compatible router used for the swap and addLiquidityETH.
    address public immutable router;
    /// @notice Wrapped-native token of this chain (must equal router.WETH()).
    address public immutable wnative;

    event LpAdded(
        address indexed caller,
        address indexed token,
        address indexed to,
        uint256 nativeIn,
        uint256 amountToken,
        uint256 amountNative,
        uint256 liquidity
    );
    event DustRefunded(address indexed to, address indexed token, uint256 tokenDust, uint256 nativeDust);
    event Rescued(address indexed token, address indexed to, uint256 amount); // token == address(0) for native

    error ZeroValue();
    error ZeroAddress();
    error NotAContract();
    error TokenIsNative();
    error InsufficientTokenOut();
    error NativeRefundFailed();
    error RescueFailed();

    /**
     * @param _router  V2-compatible DEX router for this chain (immutable).
     * @param _wnative Wrapped-native token; checked against router.WETH().
     */
    constructor(address _router, address _wnative) {
        if (_router == address(0) || _wnative == address(0)) revert ZeroAddress();
        // Pin the path token to the router's own WETH so swapExactETHForTokens
        // and addLiquidityETH operate on the same pair the router expects.
        require(IUniswapV2Router02(_router).WETH() == _wnative, "router/WETH mismatch");
        router = _router;
        wnative = _wnative;
    }

    /**
     * @notice Atomically turn bridged native into a token/native LP position.
     *         Swaps half of msg.value into `token`, then pairs it with the
     *         remaining native via addLiquidityETH. LP tokens and all dust go to
     *         `to`.
     *
     * @param token        The Magneta token to pair against native. Must be a
     *                      deployed contract and not the native sentinel.
     * @param to           Recipient of the LP tokens and any dust refund.
     * @param minTokenOut  Min `token` out of the native→token swap (slippage).
     * @param minTokenLp   Min `token` consumed by addLiquidityETH (slippage).
     * @param minNativeLp  Min native consumed by addLiquidityETH (slippage).
     * @param deadline     Unix deadline applied to both the swap and the add.
     */
    function addLiquidityNative(
        address token,
        address to,
        uint256 minTokenOut,
        uint256 minTokenLp,
        uint256 minNativeLp,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        if (msg.value == 0) revert ZeroValue();
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) revert TokenIsNative();
        if (token.code.length == 0) revert NotAContract();

        // Snapshot the native balance that does NOT belong to this tx, so the
        // end-of-call refund returns only this tx's unused native and never any
        // pre-existing donation. (balance already includes msg.value here.)
        uint256 nativeBaseline = address(this).balance - msg.value;

        uint256 half = msg.value / 2;
        uint256 nativeForLp = msg.value - half; // remainder (covers odd wei)

        // 1. Swap half the native into `token`. Measure by balance delta so the
        //    amount we pair is what actually arrived (fee-on-transfer safe) and
        //    excludes any donated `token` already sitting in the contract.
        address[] memory path = new address[](2);
        path[0] = wnative;
        path[1] = token;

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        IUniswapV2Router02(router).swapExactETHForTokens{value: half}(
            minTokenOut, path, address(this), deadline
        );
        uint256 tokenReceived = IERC20(token).balanceOf(address(this)) - tokenBefore;
        // Re-validate the MEASURED delta against the caller's floor — not just
        // the router's internal amountOutMin (Sentinelle 2026-05-25, SC02 MEDIUM
        // CVSS 5.3). A fee-on-transfer token, or one whose router-reported output
        // exceeds what actually landed, is caught here before we approve and
        // pair it — independent of what the router claimed it sent.
        if (tokenReceived < minTokenOut) revert InsufficientTokenOut();

        // 2. Add liquidity: token + native → LP, minted directly to `to`.
        IERC20(token).forceApprove(router, tokenReceived);
        (amountToken, amountNative, liquidity) = IUniswapV2Router02(router).addLiquidityETH{value: nativeForLp}(
            token, tokenReceived, minTokenLp, minNativeLp, to, deadline
        );
        // Clear any residual allowance left if the router under-pulled.
        IERC20(token).forceApprove(router, 0);

        // 3. Refund dust to `to`.
        uint256 tokenDust = tokenReceived - amountToken;
        if (tokenDust > 0) IERC20(token).safeTransfer(to, tokenDust);

        // Native dust = this tx's current balance above the donation baseline
        // (unspent swap remainder + addLiquidityETH's ETH refund). Donations
        // stay untouched.
        uint256 nativeDust = address(this).balance - nativeBaseline;
        if (nativeDust > 0) {
            (bool ok, ) = payable(to).call{value: nativeDust}("");
            if (!ok) revert NativeRefundFailed();
        }

        emit LpAdded(msg.sender, token, to, msg.value, amountToken, amountNative, liquidity);
        if (tokenDust > 0 || nativeDust > 0) emit DustRefunded(to, token, tokenDust, nativeDust);
    }

    // ───────────────────────── owner rescue ─────────────────────────
    // Only ever touches stray donations — the contract holds no user principal
    // between calls (addLiquidityNative is atomic + nonReentrant).

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    function rescueNative(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert RescueFailed();
        emit Rescued(address(0), to, amount);
    }

    /// @notice Accept native: bridged funds (msg.value to addLiquidityNative)
    ///         and the router's addLiquidityETH ETH refund both land here.
    receive() external payable {}
}
