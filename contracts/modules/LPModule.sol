// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "../interfaces/IModule.sol";
import "../interfaces/IMagnetaGateway.sol";
import "../interfaces/IMagnetaSwap.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

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

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
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
///         taken in USDC and sent to the gateway feeVault on value-moving ops
///         (CREATE_LP / REMOVE_LP / CREATE_LP_AND_BUY). BURN_LP is
///         deliberately FEE-EXEMPT (Sentinelle rescan-15 F-7, arbitrated
///         2026-07-30): burning LP is value-destructive for the caller and no
///         major AMM (Uniswap/Sushi-class, or launchpad graduation burns)
///         charges a protocol fee on it — the site advertises it as free and
///         the site is right; _burnLP intentionally has no fee leg.
///
///         Fee-on-transfer / rebasing tokens are NOT supported by this module
///         (rescan-15 F-18, assumed): swap and liquidity legs size approvals
///         and refunds on router-reported amounts, which a transfer-taxed
///         token breaks. Magneta's own token templates carry no transfer tax
///         (the 2% auto-liquidity tax template was retired 2026-06).
contract LPModule is IModule, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint16 public constant FEE_BPS = 15;                   // 0.15%
    uint256 public constant MIN_LOCAL_FEE_USDC = 100_000;  // $0.10 (6dp) flat floor — fail-closed when no on-chain price
    uint256 public constant BURN_ADDRESS_SALT = 0;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable gateway;
    address public immutable router;
    address public immutable usdc;
    address public immutable magnetaSwap;

    event LPCreated(address indexed caller, address indexed token, uint256 amountToken, uint256 amountETH, uint256 liquidity);
    event LPRemoved(address indexed caller, address indexed token, uint256 liquidity, uint256 amountToken, uint256 amountETH);
    event LPBurned(address indexed caller, address indexed token, uint256 liquidity);
    /// @notice A native dust refund could not be pushed to `to` (e.g. a
    ///         contract recipient that rejects native currency) and was
    ///         credited to the pull-payment ledger instead (F17).
    event NativeRefundPending(address indexed to, uint256 amount);
    event NativeRefundWithdrawn(address indexed to, uint256 amount);

    /// @notice Native owed to a caller whose dust refund push failed. Lets a
    ///         completed LP/swap operation stay final instead of reverting
    ///         because an unrelated recipient can't receive native currency
    ///         (Sentinelle F17 — mirrors MagnetaBundler's pendingWithdrawals).
    mapping(address => uint256) public pendingRefunds;

    error OnlyGateway();
    error InvalidParams();
    error UnsupportedOp();
    /// @notice Thrown when a cross-chain op is dispatched while the gateway's
    ///         CURRENT DVN quorum has dropped below {MIN_DVN_QUORUM} — the
    ///         constructor only proves the quorum at deploy time, so execute()
    ///         must re-check it for any op that actually traversed a bridge.
    error DVNQuorumBelowMinimum();
    /// @notice Thrown when a CREATE_LP dispatch carries an incoherent
    ///         cross-chain context — `ctx.tokenSource != address(0)` (bridged
    ///         funds staged by the gateway) must always agree with
    ///         `ctx.originChainId != block.chainid` (the op actually
    ///         traversed a bridge). Sentinelle rescan-15 F-24: the two
    ///         predicates diverged — routing picked the bridged-USDC branch
    ///         on `tokenSource != 0` alone, while the DVN re-check above
    ///         gated on `originChainId != block.chainid` alone, so an
    ///         inconsistent context (e.g. tokenSource set but
    ///         originChainId == block.chainid) could enter the bridged
    ///         branch WITHOUT ever passing through the DVN re-check.
    error InconsistentLpRoutingContext();

    /// @notice Minimum attested DVN quorum the gateway must surface for this
    ///         module to wire up. Mitigates Kelp-DAO-class single-validator
    ///         risk by anchoring the off-chain DVN-config policy on-chain
    ///         (chantier #3 — Sentinelle 2026-06-12 SC01:2026).
    uint8 public constant MIN_DVN_QUORUM = 2;

    constructor(address _gateway, address _router, address _usdc, address _magnetaSwap) {
        require(_gateway != address(0) && _router != address(0) && _usdc != address(0) && _magnetaSwap != address(0), "zero address");
        require(IMagnetaGateway(_gateway).requiredDVNCount() >= MIN_DVN_QUORUM, "LPModule: DVN quorum");
        gateway = _gateway;
        router = _router;
        usdc = _usdc;
        magnetaSwap = _magnetaSwap;
    }

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    receive() external payable {}

    /// @notice Claim native owed from a dust refund whose push failed (F17
    ///         pull-payment fallback). Callable by anyone owed a balance —
    ///         there is no gateway/reentrancy dependency, unlike execute().
    function withdrawPendingRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        require(amount > 0, "LPModule: nothing to withdraw");
        pendingRefunds[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "LPModule: withdraw failed");
        emit NativeRefundWithdrawn(msg.sender, amount);
    }

    /// @dev Credit `amount` native to `to`'s pull-payment balance (F17).
    function _creditRefund(address to, uint256 amount) internal {
        pendingRefunds[to] += amount;
        emit NativeRefundPending(to, amount);
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

        // F4: the constructor only proves the gateway's DVN quorum once, at
        // deploy time. Re-check it here for every op that actually traversed
        // a bridge (originChainId != block.chainid) so a quorum that has
        // since dropped below MIN_DVN_QUORUM is caught before this module
        // trusts bridged params, not just at wiring time.
        if (ctx.originChainId != block.chainid) {
            if (IMagnetaGateway(gateway).requiredDVNCount() < MIN_DVN_QUORUM) revert DVNQuorumBelowMinimum();
        }

        if (op == IMagnetaGateway.OpType.CREATE_LP) {
            // F-24: CREATE_LP is the only op whose ROUTING depends on
            // ctx.tokenSource, so it is the only op where the two predicates
            // (tokenSource != 0, originChainId != block.chainid) must agree.
            // Other ops (REMOVE_LP/BURN_LP/CREATE_LP_AND_BUY, and TOKEN_OPS /
            // fan-out handled elsewhere) can legitimately see
            // originChainId != block.chainid with tokenSource == 0 — e.g. a
            // fan-out command op has no bridged token leg at all — so this
            // tightened check is intentionally scoped to CREATE_LP only.
            bool bridgedFunds = ctx.tokenSource != address(0);
            bool crossChainOrigin = ctx.originChainId != block.chainid;
            if (bridgedFunds != crossChainOrigin) revert InconsistentLpRoutingContext();
            if (bridgedFunds) {
                return _createLPFromBridgedUsdc(ctx, inner);
            }
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

        // NATIVE-FEE MIGRATION: the local Magneta service fee is now collected in
        // NATIVE by MagnetaGateway.executeOperation (opServiceFeeNative), skimmed
        // before this module runs — product policy is native-only (users never
        // convert to USDC). The old USDC local floor (F53 _requireLocalFee) is
        // therefore dropped for LOCAL ops; usdcFee may be 0. The fail-safe against
        // an unconfigured/evaded fee is off-chain reconciliation in MagnetaTerminal
        // (usage vs ServiceFeeCollected per chain/op). `_collectFee` is kept so any
        // non-zero usdcFee (and the cross-chain source-side markup) still works.
        _collectFee(ctx, p.usdcFee);

        _pullToken(ctx, p.token, p.tokenAmount);
        IERC20(p.token).forceApprove(router, p.tokenAmount);

        uint256 nativeBefore = address(this).balance - msg.value;

        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IUniswapV2Router02(router).addLiquidityETH{value: p.ethAmount}(
            p.token,
            p.tokenAmount,
            p.amountTokenMin,
            p.amountETHMin,
            ctx.caller,
            p.deadline
        );

        // F52: reset the router allowance so a compromised router cannot re-pull
        // any unconsumed token approval in a future call (mirrors the cross-chain
        // reset in _createLPFromBridgedUsdc).
        IERC20(p.token).forceApprove(router, 0);

        // F7: refund leftovers. addLiquidityETH consumes amountToken<=desired and
        // amountETH<=sent; the unused token/native would otherwise be stranded in
        // this module. Mirror the cross-chain dust-refund pattern.
        _refundDust(ctx.caller, p.token, p.tokenAmount - amountToken, nativeBefore);

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

        // Snapshot the module's pair-token balance BEFORE pulling, so the dust
        // refund below can be bounded to what this operation actually left over.
        // Refunding `balanceOf(this)` instead would hand the caller any
        // pair tokens the module already held — from a donation, an aborted flow
        // or a non-conforming router — which is the asymmetry an agent panel
        // flagged on 2026-07-29: the native side of the same refund has always
        // been bounded by `nativeBefore`, the token side was not.
        uint256 pairBefore = IERC20(pair).balanceOf(address(this));
        _pullToken(ctx, pair, p.liquidity);
        uint256 nativeBefore = address(this).balance - msg.value;
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

        // F52: reset the pair allowance on the router after the burn (mirrors the
        // cross-chain reset). removeLiquidity consumes the full liquidity so the
        // remaining approval should be 0, but a non-conforming router could leave
        // a residual; zero it defensively.
        IERC20(pair).forceApprove(router, 0);

        // F7: sweep any pair-token / native leftover back to the caller. The
        // router sends the unwound token+native directly to ctx.caller, so dust
        // here is only a defensive measure against a non-conforming router.
        uint256 pairNow = IERC20(pair).balanceOf(address(this));
        _refundDust(ctx.caller, pair, pairNow > pairBefore ? pairNow - pairBefore : 0, nativeBefore);

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

        address src = ctx.tokenSource != address(0) ? ctx.tokenSource : ctx.caller;
        IERC20(pair).safeTransferFrom(src, DEAD, p.liquidity);
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

        // NATIVE-FEE MIGRATION (see _createLP): local fee is now native, skimmed
        // by the Gateway; USDC local floor dropped, usdcFee may be 0. `_collectFee`
        // kept for any non-zero usdcFee and the cross-chain source-side markup.
        _collectFee(ctx, p.lp.usdcFee);

        _pullToken(ctx, p.lp.token, p.lp.tokenAmount);
        IERC20(p.lp.token).forceApprove(router, p.lp.tokenAmount);

        uint256 nativeBefore = address(this).balance - msg.value;

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

        // F52: reset the router allowance left by the LP add (mirrors the
        // cross-chain reset). F7: refund any unconsumed token / native back to
        // the caller. nativeBefore captures the module's pre-op native balance,
        // so the residual after both the LP add and the first-buy swap is dust.
        IERC20(p.lp.token).forceApprove(router, 0);
        _refundDust(ctx.caller, p.lp.token, p.lp.tokenAmount - amountToken, nativeBefore);

        emit LPCreated(ctx.caller, p.lp.token, amountToken, amountETH, liquidity);
        return abi.encode(amountToken, amountETH, liquidity, amounts[amounts.length - 1]);
    }

    // ───────────────── cross-chain LP from bridged USDC ──────────────────

    struct CrossChainLPParams {
        address token;
        uint256 usdcTotal;
        uint16  tokenShareBps;    // e.g. 5000 = 50% USDC → token, rest → native
        uint256 amountTokenMin;   // min token out from USDC→token swap
        uint256 amountNativeMin;  // min native out from USDC→native swap
        uint256 lpAmountTokenMin; // min token accepted by addLiquidityETH
        uint256 lpAmountNativeMin;// min native accepted by addLiquidityETH
        uint256 deadline;
    }

    event LPCreatedFromUsdc(
        address indexed caller, address indexed token,
        uint256 usdcUsed, uint256 amountToken, uint256 amountNative, uint256 liquidity
    );

    function _createLPFromBridgedUsdc(Context calldata ctx, bytes calldata raw) internal returns (bytes memory) {
        // F21: this branch is funded entirely from bridged USDC — its native-dust
        // accounting below (nativeReceived - amountETH) only tracks WETH withdrawn
        // during this op, so any msg.value the gateway forwarded here would be
        // silently absorbed into "dust" and refunded as if it came from the swap.
        // Reject it outright instead of accounting for it.
        require(msg.value == 0, "LPModule: no native for bridged LP");

        CrossChainLPParams memory p = abi.decode(raw, (CrossChainLPParams));
        require(p.tokenShareBps > 0 && p.tokenShareBps < 10_000, "bad share");

        _pullToken(ctx, usdc, p.usdcTotal);

        uint256 usdcForToken = (p.usdcTotal * p.tokenShareBps) / 10_000;
        uint256 usdcForNative = p.usdcTotal - usdcForToken;
        address weth = IUniswapV2Router02(router).WETH();

        // V1.1 pivot — bypass MagnetaSwap on the cross-chain LP path. The
        // Magneta-first guideline (feedback_self_referencing_architecture)
        // creates a per-chain × per-token bootstrap deadlock for cross-chain
        // because MagnetaSwap requires MagnetaPool registry + liquidity for
        // EVERY pair, which the token launcher cannot maintain. V2 router is
        // universally available (BaseSwap, QuickSwap, PancakeSwap, Sushi…)
        // and routes through WNATIVE-paired pools — the same pool we add LP
        // into via addLiquidityETH below — so 1 swap + 1 add is self-consistent.
        // Local Token Manage swaps still use MagnetaSwap (this only impacts
        // cross-chain dest fulfillment).
        IERC20(usdc).forceApprove(router, p.usdcTotal);

        // USDC → WNATIVE (1-hop)
        address[] memory pathToNative = new address[](2);
        pathToNative[0] = usdc;
        pathToNative[1] = weth;
        uint256[] memory nativeAmounts = IUniswapV2Router02(router).swapExactTokensForTokens(
            usdcForNative, p.amountNativeMin, pathToNative, address(this), p.deadline
        );
        uint256 wethReceived = nativeAmounts[nativeAmounts.length - 1];
        IWETH(weth).withdraw(wethReceived);
        uint256 nativeReceived = wethReceived;

        // USDC → WNATIVE → token (2-hop — the dest token is paired with
        // WNATIVE in the pool we're adding to, so a direct USDC→token route
        // typically doesn't exist on the V2 DEX).
        address[] memory pathToToken = new address[](3);
        pathToToken[0] = usdc;
        pathToToken[1] = weth;
        pathToToken[2] = p.token;
        uint256[] memory tokenAmounts = IUniswapV2Router02(router).swapExactTokensForTokens(
            usdcForToken, p.amountTokenMin, pathToToken, address(this), p.deadline
        );
        uint256 tokenReceived = tokenAmounts[tokenAmounts.length - 1];

        // Add liquidity: token + native → LP via V2 router
        IERC20(p.token).forceApprove(router, tokenReceived);
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IUniswapV2Router02(router)
            .addLiquidityETH{value: nativeReceived}(
                p.token, tokenReceived, p.lpAmountTokenMin, p.lpAmountNativeMin, ctx.caller, p.deadline
            );

        // Reset residual allowances. swapExactTokensForTokens consumes the
        // full amountIn so usdc allowance is already 0, but addLiquidityETH
        // can use less than tokenReceived if the pool ratio mismatches —
        // leaving a token allowance on the router. A compromised router
        // could re-pull that allowance in a future call. (Sentinelle
        // 2026-05-30 SC03 MEDIUM.)
        IERC20(usdc).forceApprove(router, 0);
        IERC20(p.token).forceApprove(router, 0);

        // Refund dust to user (same address on destination EVM chain). F17: a
        // failed native push (e.g. ctx.caller is a contract that rejects native
        // currency) is credited to pendingRefunds instead of reverting — the
        // swaps + LP add already completed and must not be unwound because an
        // unrelated dust transfer couldn't land.
        uint256 tokenDust = tokenReceived - amountToken;
        if (tokenDust > 0) IERC20(p.token).safeTransfer(ctx.caller, tokenDust);
        uint256 nativeDust = nativeReceived - amountETH;
        if (nativeDust > 0) {
            (bool ok, ) = ctx.caller.call{value: nativeDust}("");
            if (!ok) _creditRefund(ctx.caller, nativeDust);
        }

        emit LPCreatedFromUsdc(ctx.caller, p.token, p.usdcTotal, amountToken, amountETH, liquidity);
        return abi.encode(amountToken, amountETH, liquidity);
    }

    // ───────────────────── fees ─────────────────────

    /// @dev Pulls `amount` USDC from ctx.caller into the gateway's feeVault.
    ///      Caller must have approved this module for at least `amount` USDC.
    ///      Skips on zero to allow owner-sponsored or fee-less future ops.
    ///
    ///      Cross-chain bypass (`ctx.originChainId != block.chainid → return`)
    ///      is INTENTIONAL — not a fee evasion. The Magneta 0.15% markup on
    ///      cross-chain value ops is collected SOURCE-side by
    ///      MagnetaGateway._collectCrossChainFee (BPS on totalUsdc, sent to
    ///      _feeVault on the source chain) at the time the user signs the
    ///      sendFanOutValueOp tx. Collecting again on the destination would
    ///      double-charge. (Sentinelle 2026-05-30 SC06 MEDIUM acknowledged.)
    function _collectFee(Context calldata ctx, uint256 amount) internal {
        if (amount == 0) return;
        if (ctx.originChainId != block.chainid) return;
        IERC20(usdc).safeTransferFrom(ctx.caller, ctx.feeVault, amount);
    }

    /// @dev DEPRECATED / NO LONGER CALLED (native-fee migration): the local
    ///      Magneta fee is now collected in NATIVE by the Gateway, so this USDC
    ///      floor is not invoked. Retained (not deleted) so it can be re-enabled
    ///      if a chain ever needs a USDC fallback, and to avoid an unused-state
    ///      cascade on `magnetaSwap`. Not a live guard anymore.
    /// @dev F53: enforce the 0.15% Magneta markup floor for LOCAL value ops.
    ///      Without this, a local caller (originChainId == block.chainid) could
    ///      pass usdcFee = 0 and _collectFee would early-return, evading the fee
    ///      entirely. We derive the op's USD value on-chain instead of trusting
    ///      the caller-supplied fee: the native side (`ethAmount`) is priced into
    ///      USDC via MagnetaSwap, and a balanced two-sided LP add deposits ~equal
    ///      value on each side, so total value ≈ 2× the native value. The floor
    ///      is then value × FEE_BPS / 10_000, matching MagnetaGateway's
    ///      _collectCrossChainFee convention. Cross-chain ops are untouched (the
    ///      markup was already collected source-side).
    function _requireLocalFee(Context calldata ctx, uint256 ethAmount, uint256 suppliedFee) internal view {
        if (ctx.originChainId != block.chainid) return;
        if (ethAmount == 0) return;
        address weth = IUniswapV2Router02(router).WETH();
        // MagnetaSwap.getAmountOut returns 0 (no revert) when WETH/USDC is not
        // whitelisted or has no pool — which is the case on most chains. Applying
        // only the quoted fee would then floor at 0 and re-open the evasion, so we
        // ALWAYS enforce a flat minimum: the guard fails CLOSED on those chains.
        uint256 nativeUsd = IMagnetaSwap(magnetaSwap).getAmountOut(weth, usdc, ethAmount);
        uint256 valueUsd = nativeUsd * 2; // balanced LP: token side ≈ native side
        uint256 expectedFee = (valueUsd * FEE_BPS) / 10_000;
        if (expectedFee < MIN_LOCAL_FEE_USDC) expectedFee = MIN_LOCAL_FEE_USDC;
        require(suppliedFee >= expectedFee, "LPModule: fee below minimum");
    }

    /// @dev F7: refund unconsumed token / native back to `to`, mirroring the
    ///      cross-chain dust-refund block in _createLPFromBridgedUsdc.
    ///      `tokenDust` is the precomputed token leftover; the native leftover is
    ///      derived from the module's pre-op native balance (`nativeBefore`).
    ///      F17: a failed native push is credited to pendingRefunds instead of
    ///      reverting — `to` is ctx.caller and may be a contract that rejects
    ///      native currency, and the LP add / removal has already completed by
    ///      this point, so it must not be unwound over unrelated dust.
    function _refundDust(address to, address token, uint256 tokenDust, uint256 nativeBefore) internal {
        if (tokenDust > 0) IERC20(token).safeTransfer(to, tokenDust);
        uint256 nativeDust = address(this).balance - nativeBefore;
        if (nativeDust > 0) {
            (bool ok, ) = to.call{value: nativeDust}("");
            if (!ok) _creditRefund(to, nativeDust);
        }
    }

    /// @dev Pull tokens from tokenSource (cross-chain) or caller (local).
    function _pullToken(Context calldata ctx, address token, uint256 amount) internal {
        address src = ctx.tokenSource != address(0) ? ctx.tokenSource : ctx.caller;
        IERC20(token).safeTransferFrom(src, address(this), amount);
    }
}
