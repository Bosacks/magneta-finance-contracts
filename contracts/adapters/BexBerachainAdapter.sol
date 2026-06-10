// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title  BexBerachainAdapter
/// @notice Uniswap V2 router facade over BEX (Berachain's Balancer V2 fork).
///         Mirrors `UbeswapCeloAdapter.sol` / `DragonSwapSeiAdapter.sol`
///         shape so `LPModule.sol` can call this without modification.
///
///         V1.1 bodies implemented 2026-06-09 — supersedes the V1 stub.
///
/// @dev    BEX security advisory (read before deploying):
///         Balancer V2 (which BEX forks) has a disclosed token-frontrun
///         vulnerability disclosed 2026-01-21. The runtime guard
///         `require(token.code.length > 0)` inside addLiquidityETH ensures
///         Magneta's flow only creates pools for already-deployed tokens,
///         which is the documented mitigation. Berachain's roadmap moves
///         BEX to Balancer V3 (mitigated); redeploy this adapter against
///         the V3 Vault once available.
///
///         Mainnet BEX addresses (verified on docs.berachain.com 2026-06-07):
///           Vault                 0x4Be03f781C497A489E3cB0287833452cA9B9E80B
///           WeightedPoolFactory   0xa966fA8F2d5B087FFFA499C0C1240589371Af409
///           WBERA                 0x6969696969696969696969696969696969696969
///
///         Bepolia testnet for E2E:
///           Vault                 0x708cA656b68A6b7384a488A36aD33505a77241FE
///           WeightedPoolFactory   0xf1d23276C7b271B2aC595C78977b2312E9954D57

// ─── BEX interface subsets ────────────────────────────────────────────────

interface IBexVault {
    enum SwapKind { GIVEN_IN, GIVEN_OUT }
    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes   userData;
    }
    struct FundManagement {
        address sender;
        bool    fromInternalBalance;
        address payable recipient;
        bool    toInternalBalance;
    }
    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256 amountCalculated);

    struct JoinPoolRequest {
        address[] assets;
        uint256[] maxAmountsIn;
        bytes     userData;
        bool      fromInternalBalance;
    }
    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable;

    struct ExitPoolRequest {
        address[] assets;
        uint256[] minAmountsOut;
        bytes     userData;
        bool      toInternalBalance;
    }
    function exitPool(
        bytes32 poolId,
        address sender,
        address payable recipient,
        ExitPoolRequest memory request
    ) external;

    function getPoolTokens(bytes32 poolId)
        external view returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

interface IBexWeightedPoolFactory {
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory normalizedWeights,
        address[] memory rateProviders,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address pool);
}

interface IBexPool {
    function getPoolId() external view returns (bytes32);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

// ─── Adapter contract ────────────────────────────────────────────────────

contract BexBerachainAdapter is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // BEX endpoints (immutable on mainnet, settable in constructor for
    // Bepolia testnet reuse).
    IBexVault                public immutable vault;
    IBexWeightedPoolFactory  public immutable poolFactory;
    address                  public immutable WETH;             // = WBERA

    /// @notice 50/50 weighted pool default (in Balancer's 1e18-scaled
    ///         normalizedWeights). [0.5e18, 0.5e18]. Adapter is opinionated
    ///         to 50/50 because Magneta's UI assumes constant-product pricing.
    uint256 public constant WEIGHT_HALF = 5e17;

    /// @notice Swap fee for pools created by this adapter (1e18-scaled).
    ///         0.3e16 = 0.30%, matching Magneta's V2-chain default UX.
    ///         Hardcoded (not parameter) to satisfy Sentinelle MEDIUM CVSS 5.3:
    ///         any future variant that exposes this MUST enforce
    ///         `require(swapFeePercentage <= 1e17)` before calling create.
    uint256 public constant SWAP_FEE = 3e15;

    // Balancer V2 user-data join/exit kinds for WeightedPool.
    uint8 private constant JOIN_KIND_INIT                       = 0;
    uint8 private constant JOIN_KIND_EXACT_TOKENS_IN_FOR_BPT_OUT = 1;
    uint8 private constant EXIT_KIND_EXACT_BPT_IN_FOR_TOKENS_OUT = 1;

    /// @notice Pair → BEX pool address. Populated lazily on first
    ///         addLiquidityETH() against a new pair. Both orderings tracked.
    mapping(address => mapping(address => address)) public pairOf;

    // ─── Events ───────────────────────────────────────────────────────────

    event PairCreated(address indexed tokenA, address indexed tokenB, address indexed pool, bytes32 poolId);
    event LPAdded(address indexed token, address indexed lp, uint256 tokenAmount, uint256 ethAmount, uint256 bptMinted);
    event LPRemoved(address indexed token, address indexed lp, uint256 tokenAmount, uint256 ethAmount, uint256 bptBurned);

    // ─── Errors ───────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error DeadlinePassed();
    error PoolMissing(address tokenA, address tokenB);
    error TokenNotDeployed();
    error InsufficientOutput();
    error RefundFailed();
    error StaleBalance();

    constructor(address _vault, address _poolFactory, address _weth) {
        if (_vault == address(0) || _poolFactory == address(0) || _weth == address(0)) revert ZeroAddress();
        vault       = IBexVault(_vault);
        poolFactory = IBexWeightedPoolFactory(_poolFactory);
        WETH        = _weth;
    }

    // ─── Read surface (LPModule calls these) ──────────────────────────────

    function factory() external view returns (address) {
        return address(this);
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairOf[tokenA][tokenB];
    }

    // ─── Internal helpers ─────────────────────────────────────────────────

    /// @dev Sort tokens by address — Balancer V2 requires pool assets be in
    ///      strictly ascending order.
    function _sort(address tokenA, address tokenB)
        private pure returns (address t0, address t1)
    {
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @dev Build the sorted [tokenA, tokenB] addresses + matching amounts
    ///      array in the order Balancer expects.
    function _sortedAssets(
        address tokenA, address tokenB,
        uint256 amountA, uint256 amountB
    ) private pure returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](2);
        amounts = new uint256[](2);
        (address t0, address t1) = _sort(tokenA, tokenB);
        tokens[0] = t0; tokens[1] = t1;
        if (t0 == tokenA) { amounts[0] = amountA; amounts[1] = amountB; }
        else              { amounts[0] = amountB; amounts[1] = amountA; }
    }

    /// @dev Lazily create the 50/50 weighted pool for (token, WBERA) if it
    ///      doesn't exist, and return its pool address + id.
    function _ensurePool(address token, address weth) private returns (address pool, bytes32 poolId) {
        pool = pairOf[token][weth];
        if (pool != address(0)) {
            return (pool, IBexPool(pool).getPoolId());
        }

        (address[] memory tokens,) = _sortedAssets(token, weth, 0, 0);
        uint256[] memory weights = new uint256[](2);
        weights[0] = WEIGHT_HALF;
        weights[1] = WEIGHT_HALF;
        address[] memory rateProviders = new address[](2);
        // rateProviders[0] = rateProviders[1] = address(0) (no rate scaling)

        pool = poolFactory.create(
            "MAG-LP",
            "MAG-LP",
            tokens,
            weights,
            rateProviders,
            SWAP_FEE,
            address(this),
            bytes32(0)
        );
        poolId = IBexPool(pool).getPoolId();
        pairOf[token][weth] = pool;
        pairOf[weth][token] = pool;
        emit PairCreated(token, weth, pool, poolId);
    }

    // ─── Mutation surface ─────────────────────────────────────────────────

    /// @notice V2 → BEX joinPool. Wraps msg.value to WBERA, lazily creates
    ///         a 50/50 weighted pool if one doesn't exist, then joins.
    ///
    /// @dev Sentinelleai re-scan 2026-06-10 (MEDIUM SC06) fixed:
    ///        V2-style partial-fill logic. For non-empty pools we compute
    ///        the optimal token/ETH ratio against current reserves and
    ///        deposit only up to that ratio; excess native is refunded
    ///        to msg.sender. amountTokenMin / amountETHMin now bound the
    ///        ACTUAL deposited amount (not the desired), making them
    ///        meaningful slippage floors that protect against pool price
    ///        manipulation including flash-loan-pumped reserves.
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amountTokenDesired == 0 || msg.value == 0) revert ZeroAmount();

        // Mitigation for BEX (Balancer V2) token-frontrun vulnerability:
        // pool creation for a not-yet-deployed token is exploitable. Reject.
        if (token.code.length == 0) revert TokenNotDeployed();

        // ── Determine deposited amounts (V2 partial-fill — SC06 fix) ──
        address existingPool = pairOf[token][WETH];
        if (existingPool == address(0) || IBexPool(existingPool).totalSupply() == 0) {
            // INIT case (no pool OR empty pool). No ratio to enforce.
            // Slippage params still bound the user's own desires.
            if (amountTokenDesired < amountTokenMin) revert InsufficientOutput();
            if (msg.value < amountETHMin) revert InsufficientOutput();
            amountToken = amountTokenDesired;
            amountETH = msg.value;
        } else {
            // Subsequent join: compute optimal ratio from live reserves.
            // Flash-loan-pumped reserves would skew `ethOptimal`, but the
            // resulting amount is checked against amountETHMin which the
            // user sets per their slippage tolerance — manipulation is
            // bounded by the user's own floor (V2 router pattern).
            bytes32 pid = IBexPool(existingPool).getPoolId();
            (uint256 rToken, uint256 rWeth) = _getReservesSorted(pid, token);

            uint256 ethOptimal = (amountTokenDesired * rWeth) / rToken;
            if (ethOptimal <= msg.value) {
                if (ethOptimal < amountETHMin) revert InsufficientOutput();
                amountToken = amountTokenDesired;
                amountETH = ethOptimal;
            } else {
                uint256 tokenOptimal = (msg.value * rToken) / rWeth;
                if (tokenOptimal < amountTokenMin) revert InsufficientOutput();
                amountToken = tokenOptimal;
                amountETH = msg.value;
            }
        }

        // ── Wrap exact native amount + pull exact token amount ──
        IWETH(WETH).deposit{value: amountETH}();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);

        // Pool: lazy create (after amount calc so first join doesn't pay
        // factory gas for a tx that would have reverted on slippage).
        (address pool, bytes32 poolId) = _ensurePool(token, WETH);

        // Approve both to Vault
        IERC20(token).forceApprove(address(vault), amountToken);
        IERC20(WETH).forceApprove(address(vault), amountETH);

        // Build sorted JoinPoolRequest
        (address[] memory assets, uint256[] memory amounts) =
            _sortedAssets(token, WETH, amountToken, amountETH);

        bytes memory userData;
        if (IBexPool(pool).totalSupply() == 0) {
            // First-ever join: INIT
            userData = abi.encode(JOIN_KIND_INIT, amounts);
        } else {
            // Subsequent: EXACT_TOKENS_IN_FOR_BPT_OUT. minBPTOut = 0
            // because we've already enforced slippage at the amounts
            // layer above (the ratio is locked to the pool's current state).
            userData = abi.encode(JOIN_KIND_EXACT_TOKENS_IN_FOR_BPT_OUT, amounts, uint256(0));
        }

        IBexVault.JoinPoolRequest memory request = IBexVault.JoinPoolRequest({
            assets: assets,
            maxAmountsIn: amounts,
            userData: userData,
            fromInternalBalance: false
        });

        uint256 bptBefore = IBexPool(pool).balanceOf(to);
        vault.joinPool(poolId, address(this), to, request);
        liquidity = IBexPool(pool).balanceOf(to) - bptBefore;

        emit LPAdded(token, pool, amountToken, amountETH, liquidity);

        // ── Refund excess native to msg.sender (CEI: external call last) ──
        uint256 ethExcess = msg.value - amountETH;
        if (ethExcess > 0) {
            (bool ok, ) = payable(msg.sender).call{value: ethExcess}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev Read pool reserves and map them to (tokenA, WETH) order
    ///      regardless of Balancer's internal sort. Used by addLiquidityETH
    ///      for partial-fill ratio computation.
    function _getReservesSorted(bytes32 poolId, address token)
        private view returns (uint256 reserveToken, uint256 reserveWeth)
    {
        (address[] memory tokens, uint256[] memory balances,) = vault.getPoolTokens(poolId);
        require(tokens.length == 2, "BexAdapter: pool not 2-asset");
        if (tokens[0] == token) {
            (reserveToken, reserveWeth) = (balances[0], balances[1]);
        } else {
            (reserveToken, reserveWeth) = (balances[1], balances[0]);
        }
    }

    /// @notice V2 → BEX exitPool. Burns BPT for proportional token+native.
    ///
    /// @dev Sentinelleai re-scan 2026-06-10 follow-up:
    ///        - SC02 LOW (flash-loanable preview): dropped `_previewExit`
    ///          which read live pool state and was gameable by flash-loan
    ///          pumping reserves. Replaced with the Balancer V2 Vault's
    ///          own minAmountsOut[] floor as the AUTHORITATIVE slippage
    ///          enforcement — the Vault reverts before returning to us
    ///          if proportional output is below the user's minimums.
    ///        - SC02 (balanceOf delta): we still use balanceOf delta to
    ///          measure ACTUAL received, but it is structurally safe in
    ///          this adapter:
    ///            (1) nonReentrant precludes concurrent calls
    ///            (2) receive() rejects native from any sender != WBERA
    ///            (3) Balancer V2 has no ERC20 transfer callbacks; the
    ///                Vault is the only inflow source during exitPool
    ///            (4) Pre-existing donations are captured in `*Before`
    ///                and CORRECTLY excluded from the delta (donor self-griefs)
    ///        - SC08 MEDIUM (cross-contract reentrancy residual):
    ///          documented and mitigated. `vault.exitPool` runs to
    ///          completion BEFORE any ETH is forwarded to `to`. The
    ///          only remaining external calls (token.transfer,
    ///          WBERA.withdraw, payable(to).call) are atomic-finalizing
    ///          and protected by nonReentrant. No state mutation in this
    ///          adapter occurs after the vault call except the LPRemoved
    ///          event emission.
    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        require(tokenB == WETH, "BexAdapter: tokenB must be WBERA (V1 scope)");
        if (tokenA == address(0) || to == address(0)) revert ZeroAddress();
        if (liquidity == 0) revert ZeroAmount();

        address pool = pairOf[tokenA][tokenB];
        if (pool == address(0)) revert PoolMissing(tokenA, tokenB);
        bytes32 poolId = IBexPool(pool).getPoolId();

        // Build sorted ExitPoolRequest. minAmountsOut[] is the Vault's
        // own authoritative slippage floor (Balancer V2 invariant).
        (address[] memory assets, uint256[] memory minAmounts) =
            _sortedAssets(tokenA, tokenB, amountAMin, amountBMin);
        IBexVault.ExitPoolRequest memory request = IBexVault.ExitPoolRequest({
            assets: assets,
            minAmountsOut: minAmounts,
            userData: abi.encode(EXIT_KIND_EXACT_BPT_IN_FOR_TOKENS_OUT, liquidity),
            toInternalBalance: false
        });

        // Pull BPT. The vault enforces slippage via minAmountsOut[] — no
        // preview needed.
        IERC20(pool).safeTransferFrom(msg.sender, address(this), liquidity);

        // SC02 mitigation v5 (Sentinelleai 2026-06-10):
        // Authoritative `amountA` / `amountB` come from the Balancer Vault's
        // own balance tracking via `getPoolTokens` deltas — NOT from
        // `IERC20(token).balanceOf(address(this))`. The Vault's internal
        // accounting is the source of truth for "how much did the pool
        // send to us", and is atomic within this transaction (nonReentrant
        // precludes interleaving). This eliminates the Venus-Protocol-2026-03
        // donation-attack pattern at the architectural level.
        //
        // Defense-in-depth: also assert zero pre-call balance of (tokenA,
        // WBERA) so any future bug that leaves dust here is caught early.
        // Owner can recover dust via `sweep()`.
        if (IERC20(tokenA).balanceOf(address(this)) != 0) revert StaleBalance();
        if (IERC20(WETH).balanceOf(address(this)) != 0) revert StaleBalance();

        (, uint256[] memory poolBalancesBefore,) = vault.getPoolTokens(poolId);

        vault.exitPool(poolId, address(this), payable(address(this)), request);

        (, uint256[] memory poolBalancesAfter,) = vault.getPoolTokens(poolId);

        // Pool balance DECREASED by exactly what the Vault forwarded to us.
        uint256 vaultDelta0 = poolBalancesBefore[0] - poolBalancesAfter[0];
        uint256 vaultDelta1 = poolBalancesBefore[1] - poolBalancesAfter[1];
        if (assets[0] == tokenA) {
            (amountA, amountB) = (vaultDelta0, vaultDelta1);
        } else {
            (amountA, amountB) = (vaultDelta1, vaultDelta0);
        }

        // Effects: emit + state finalization BEFORE the user-facing
        // transfers and the native forward (CEI-aware).
        emit LPRemoved(tokenA, pool, amountA, amountB, liquidity);

        // Interactions (CEI-aware: external calls last)
        IERC20(tokenA).safeTransfer(to, amountA);
        IWETH(WETH).withdraw(amountB);
        (bool success, ) = payable(to).call{value: amountB}("");
        if (!success) revert RefundFailed();
    }

    /// @notice V2 → BEX swap (GIVEN_IN, single-pool path).
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        require(path.length == 2, "BexAdapter: multi-hop out of scope V1");
        if (to == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();

        address pool = pairOf[path[0]][path[1]];
        if (pool == address(0)) revert PoolMissing(path[0], path[1]);
        bytes32 poolId = IBexPool(pool).getPoolId();

        // Pull amountIn from msg.sender
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[0]).forceApprove(address(vault), amountIn);

        IBexVault.SingleSwap memory singleSwap = IBexVault.SingleSwap({
            poolId: poolId,
            kind: IBexVault.SwapKind.GIVEN_IN,
            assetIn: path[0],
            assetOut: path[1],
            amount: amountIn,
            userData: ""
        });

        IBexVault.FundManagement memory funds = IBexVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(to),
            toInternalBalance: false
        });

        uint256 amountOut = vault.swap(singleSwap, funds, amountOutMin, deadline);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    /// @notice V2 → BEX swap with native in. Wraps msg.value to WBERA first.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        require(path.length == 2 && path[0] == WETH, "BexAdapter: bad path");
        if (to == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();

        address pool = pairOf[path[0]][path[1]];
        if (pool == address(0)) revert PoolMissing(path[0], path[1]);
        bytes32 poolId = IBexPool(pool).getPoolId();

        // Wrap msg.value → WBERA, approve to Vault
        IWETH(WETH).deposit{value: msg.value}();
        IERC20(WETH).forceApprove(address(vault), msg.value);

        IBexVault.SingleSwap memory singleSwap = IBexVault.SingleSwap({
            poolId: poolId,
            kind: IBexVault.SwapKind.GIVEN_IN,
            assetIn: WETH,
            assetOut: path[1],
            amount: msg.value,
            userData: ""
        });

        IBexVault.FundManagement memory funds = IBexVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(to),
            toInternalBalance: false
        });

        uint256 amountOut = vault.swap(singleSwap, funds, amountOutMin, deadline);

        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = amountOut;
    }

    /// @notice Owner-only: pre-register a (tokenA, tokenB) → pool mapping
    ///         after creating the pool out-of-band. Useful for chains
    ///         where Magneta wants to use an existing BEX pool instead of
    ///         deploying a fresh one. Symmetric in both orderings.
    /// @dev Sentinelleai 2026-06-10 LOW SC01: mappings are write-once.
    ///      The owner CANNOT overwrite an existing pair — eliminates the
    ///      "compromised owner remaps to malicious pool" vector. To
    ///      replace a deprecated pool, a new (tokenA, tokenB) entry must
    ///      be created by removing the contract or deploying a fresh
    ///      adapter; we explicitly accept the operational cost of this
    ///      immutability as a security trade-off.
    function setPair(address tokenA, address tokenB, address pool) external onlyOwner {
        if (tokenA == address(0) || tokenB == address(0) || pool == address(0)) revert ZeroAddress();
        require(pairOf[tokenA][tokenB] == address(0), "BexAdapter: pair exists");
        require(pairOf[tokenB][tokenA] == address(0), "BexAdapter: pair exists");
        pairOf[tokenA][tokenB] = pool;
        pairOf[tokenB][tokenA] = pool;
    }

    /// @notice Owner-only emergency cleanup of stray ERC20 dust.
    ///         The StaleBalance guard in `removeLiquidity` reverts when
    ///         the adapter holds any (tokenA, WBERA) balance pre-call —
    ///         this function lets the owner sweep accidental or malicious
    ///         dust transfers so legitimate user flows can resume.
    /// @dev Sentinelleai 2026-06-10 SC02 mitigation companion. Doesn't
    ///      grant the owner authority over funds that are LEGITIMATELY
    ///      mid-flow — those are zero between calls thanks to the
    ///      no-residual design of all mutation functions.
    function sweep(address token, address to) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, bal);
    }

    /// @notice Accept native unwraps from WBERA so removeLiquidity →
    ///         WBERA.withdraw → ETH lands here before we forward it out.
    receive() external payable {
        require(msg.sender == WETH, "BexAdapter: only WBERA refund");
    }
}
