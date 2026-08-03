// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Ownable2Step }      from "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./AdapterPull.sol";

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

contract UbeswapCeloAdapter is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;
    using AdapterPull for IERC20;

    /// @notice CELO native token, exposed as an ERC20 via the GoldToken precompile.
    address public constant CELO = 0x471EcE3750Da237f93B8E339c536989b8978a438;

    IUbeswapRouter public immutable ube;
    address public immutable factory;
    address public immutable WETH;

    // ─── Events ───────────────────────────────────────────────────────────

    /// @dev Emitted on every rescue. `BexBerachainAdapter.sweep` emits nothing,
    ///      which is the one place this adapter deliberately does MORE than the
    ///      reference: the same file's `setPair` docblock argues admin actions
    ///      must be observable by magneta-listener, and a rescue is the most
    ///      privileged action either contract has. Ownership model, guards and
    ///      revert conditions are otherwise identical to Bex's.
    event Swept(address indexed token, address indexed to, uint256 amount);
    event SweptNative(address indexed to, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error SweepFailed();

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
        // Forward what actually ARRIVED, not what was asked for: a
        // fee-on-transfer token delivers less, and approving the requested
        // figure would have the router pull more than this call brought in.
        uint256 gotA = IERC20(tokenA).pullMeasured(msg.sender, amountADesired);
        uint256 gotB = IERC20(tokenB).pullMeasured(msg.sender, amountBDesired);
        IERC20(tokenA).forceApprove(address(ube), gotA);
        IERC20(tokenB).forceApprove(address(ube), gotB);
        (amountA, amountB, liquidity) = ube.addLiquidity(
            tokenA, tokenB, gotA, gotB, amountAMin, amountBMin, to, deadline
        );
        // Refund against what was received, so the adapter stays balance-neutral.
        if (gotA > amountA) IERC20(tokenA).safeTransfer(msg.sender, gotA - amountA);
        if (gotB > amountB) IERC20(tokenB).safeTransfer(msg.sender, gotB - amountB);
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
        // Token leg: same measured-pull rule as addLiquidity — the native leg

        // is msg.value and needs no measuring.

        uint256 gotToken = IERC20(token).pullMeasured(msg.sender, amountTokenDesired);
        IERC20(token).forceApprove(address(ube), gotToken);
        IERC20(CELO).forceApprove(address(ube), msg.value);
        (amountToken, amountETH, liquidity) = ube.addLiquidity(
            token, CELO,
            gotToken, msg.value,
            amountTokenMin, amountETHMin,
            to, deadline
        );
        if (gotToken > amountToken) IERC20(token).safeTransfer(msg.sender, gotToken - amountToken);
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
        // Same measured-pull rule as the liquidity paths. Approving and
        // instructing the router to spend amountIn when a fee-on-transfer
        // token delivered less lets the router take the shortfall out of any
        // residual balance this adapter holds — the remediation applied to
        // addLiquidity but originally missed here (Sentinelleai F-1).
        uint256 gotIn = IERC20(path[0]).pullMeasured(msg.sender, amountIn);
        IERC20(path[0]).forceApprove(address(ube), gotIn);
        amounts = ube.swapExactTokensForTokens(gotIn, amountOutMin, path, to, deadline);
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
        // Same measured-pull rule as the liquidity paths. Approving and
        // instructing the router to spend amountIn when a fee-on-transfer
        // token delivered less lets the router take the shortfall out of any
        // residual balance this adapter holds — the remediation applied to
        // addLiquidity but originally missed here (Sentinelleai F-1).
        uint256 gotIn = IERC20(path[0]).pullMeasured(msg.sender, amountIn);
        IERC20(path[0]).forceApprove(address(ube), gotIn);
        amounts = ube.swapExactTokensForTokens(gotIn, amountOutMin, path, address(this), deadline);
        IERC20(path[0]).forceApprove(address(ube), 0);

        uint256 out = amounts[amounts.length - 1];
        (bool ok, ) = to.call{value: out}("");
        require(ok, "UbeAdapter: celo send failed");
    }

    // ─── Rescue ───────────────────────────────────────────────────────────

    /// @notice Owner-only recovery of ERC20 value stranded on this adapter.
    ///         Same shape as `BexBerachainAdapter.sweep`: whole balance, named
    ///         recipient, reverts on a zero balance rather than emitting a
    ///         no-op.
    /// @dev    This is a net, not a treasury. The adapter holds nothing between
    ///         calls, so anything reachable here is residue: a donation, dust
    ///         from a rebasing token that credited more than `pullMeasured`
    ///         attributed to the caller, or a transfer sent to the wrong
    ///         address. Before this function existed such value was
    ///         unrecoverable by anyone, permanently.
    /// @dev    `nonReentrant` is load-bearing, not decoration. User funds are
    ///         only ever on this contract WITHIN a single transaction (between
    ///         `pullMeasured` and the router call, or between the router's
    ///         payout and the native forward at the end of
    ///         `swapExactTokensForETH`). The only way for the owner to reach
    ///         into that window is to re-enter mid-operation from a token with
    ///         a transfer callback — which is exactly what the shared
    ///         ReentrancyGuard status refuses. Across transactions there is
    ///         nothing in flight to take, so no further guard (pause flag,
    ///         timelock on the sweep itself) buys anything the guard does not
    ///         already give. Exercised by `test/AdapterRescue.t.sol`.
    /// @dev    CELO CAVEAT: on Celo the GoldToken precompile's ERC20 ledger and
    ///         the chain's native balance are the SAME state, so
    ///         `sweep(CELO, to)` and `sweepNative(to)` move the same value by
    ///         two different mechanisms. Either works; whichever runs first
    ///         leaves the other reverting `ZeroAmount`. For any other token the
    ///         two are independent.
    function sweep(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert ZeroAmount();
        emit Swept(token, to, bal);
        IERC20(token).safeTransfer(to, bal);
    }

    /// @notice Owner-only recovery of native value stranded on this adapter.
    /// @dev    `BexBerachainAdapter` has no native counterpart because its
    ///         `receive()` only accepts WBERA unwraps. This adapter's
    ///         `receive()` is open — the CELO precompile credits it on every
    ///         inbound ERC20 transfer — so native can land here from anyone
    ///         and, until now, stayed forever. See the CELO caveat on `sweep`.
    function sweepNative(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();
        emit SweptNative(to, bal);
        (bool ok, ) = payable(to).call{value: bal}("");
        if (!ok) revert SweepFailed();
    }

    /// @notice Open by necessity: an inbound CELO ERC20 transfer IS an inbound
    ///         native transfer on Celo, so this contract must accept value to
    ///         be able to hold CELO at all. Anything else that arrives is
    ///         recoverable via `sweepNative`.
    receive() external payable {}
}
