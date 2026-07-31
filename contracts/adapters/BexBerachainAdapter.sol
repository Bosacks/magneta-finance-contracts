// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./AdapterPull.sol";

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

    // ── Read-only reentrancy guard plumbing ──
    // Balancer V2's own `nonReentrant` modifier lives on `manageUserBalance`,
    // among other entrypoints. We never actually move funds through it — the
    // shape here exists solely so `VaultReentrancyLib` (below) can compute
    // the correct 4-byte selector and trigger that modifier from the outside.
    // See `VaultReentrancyLib.ensureNotInVaultContext` for why.
    enum UserBalanceOpKind { DEPOSIT_INTERNAL, WITHDRAW_INTERNAL, TRANSFER_INTERNAL, TRANSFER_EXTERNAL }
    struct UserBalanceOp {
        UserBalanceOpKind kind;
        address asset;
        uint256 amount;
        address sender;
        address payable recipient;
    }
    function manageUserBalance(UserBalanceOp[] memory ops) external payable;
}

/// @title  VaultReentrancyLib
/// @notice Local reimplementation of Balancer's own
///         `VaultReentrancyLib.ensureNotInVaultContext` (from
///         `balancer-labs`' `v2-pool-utils/contracts/lib/VaultReentrancyLib.sol`).
///         Not imported directly because the `balancer-labs` npm scope is
///         not a dependency of this repo (checked: absent from
///         `node_modules/`) — reproduced
///         here byte-for-byte in intent, ported and verified against the
///         upstream source on 2026-07-31.
/// @dev    THE READ-ONLY REENTRANCY PROBLEM THIS CLOSES:
///         Balancer V2's Vault has a documented read-only reentrancy issue
///         (https://forum.balancer.fi/t/reentrancy-vulnerability-scope-expanded/4345).
///         A `nonReentrant` modifier on *this* adapter only blocks a SECOND
///         call into THIS adapter while the first is still executing. It does
///         NOT block a FIRST call into this adapter that happens to occur
///         while some OTHER party's Vault operation (e.g. their own
///         `exitPool` sending them native ETH mid-callback) is still
///         in-flight. During that window the Vault's own internal balances
///         are mid-update, so `vault.getPoolTokens(poolId)` can return
///         transiently-inconsistent reserves — enough to skew this adapter's
///         ratio math in `_getReservesSorted` / the delta accounting in
///         `removeLiquidity`.
///
///         THE FIX: ask the Vault itself whether it is currently executing.
///         `manageUserBalance` carries the Vault's own `nonReentrant` guard.
///         Calling it (with a deliberately empty/degenerate op list, cost
///         `0` as calldata — decodes as a zero-length array since the value
///         doubles as both the array's offset AND, read at that offset, its
///         length) via a gas-capped `staticcall` produces exactly one of two
///         outcomes:
///           1. Vault is idle: the guard's `_require(status != ENTERED)`
///              passes, but the very next line (`status = ENTERED`) is a
///              storage write, which STATICCALL forbids outright — the call
///              reverts with EMPTY revertData (a low-level STATICCALL
///              violation, not a Solidity `revert`/`require`).
///           2. Vault is mid-operation (reentrant): the guard's `_require`
///              fails FIRST, before any storage write, producing a normal
///              `Error(string)`-encoded revert ("BAL#400" in the real Vault)
///              whose data survives the staticcall (REVERT-with-data is
///              permitted under STATICCALL; only writes are not).
///         So: empty revertData == Vault idle == safe to trust reads.
///         Non-empty revertData == Vault mid-operation == reads are
///         untrustworthy == revert.
///
///         CORRECTION vs. the task brief that requested this fix: it warned
///         "the official pattern is NOT a staticcall". That is incorrect —
///         verified directly against
///         github.com/balancer/balancer-v2-monorepo/blob/master/pkg/pool-utils/contracts/lib/VaultReentrancyLib.sol
///         on 2026-07-31, and it IS a `staticcall` (with a 10_000 gas cap,
///         reproduced below). Documenting the discrepancy rather than
///         silently following the (wrong) brief, per this repo's own
///         "verify against real sources, don't code from memory" rule.
library VaultReentrancyLib {
    /// @dev Mirrors Balancer's own VaultReentrancyLib. The probe is a
    ///      gas-capped staticcall to `manageUserBalance` with an empty op
    ///      array, and the verdict is the IDENTITY of the revert reason, not
    ///      whether it reverted:
    ///        - inside a Vault callback, the Vault's own reentrancy guard
    ///          fires first and returns Error("BAL#400");
    ///        - outside, the call either succeeds (empty ops mutate nothing)
    ///          or fails for an unrelated reason.
    ///      Testing `revertData.length == 0` instead — the shape this file
    ///      first shipped with — would treat ANY other Vault revert (paused
    ///      vault, upgraded error set, out-of-gas with data) as reentrancy and
    ///      permanently refuse to trade: a liveness bug wearing a safety
    ///      costume. The hash is derived here rather than hardcoded so a
    ///      transcription slip cannot silently disable the check.
    function ensureNotInVaultContext(IBexVault vault) internal view {
        bytes32 reentrancyErrorHash = keccak256(abi.encodeWithSignature("Error(string)", "BAL#400"));
        (, bytes memory revertData) = address(vault).staticcall{gas: 10_000}(
            abi.encodeWithSelector(vault.manageUserBalance.selector, 0)
        );
        require(
            keccak256(revertData) != reentrancyErrorHash,
            "BexAdapter: vault reentrancy detected"
        );
    }
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
    using AdapterPull for IERC20;

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
    event PairRegistered(address indexed tokenA, address indexed tokenB, address indexed pool, address registrar);
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
    ///
    /// @dev RESIDUAL MEV RISK (Sentinelleai v6 MEDIUM 4.8):
    ///        The optimal ratio is computed from SPOT pool reserves, which
    ///        an MEV bot can manipulate via sandwich attack: pump reserves
    ///        before the user's tx, deposit at skewed ratio, restore the
    ///        price after. Value extracted is BOUNDED by the user's
    ///        amountTokenMin / amountETHMin slippage parameters.
    ///        This is an inherent V2-router pattern risk that cannot be
    ///        eliminated at the contract level (would require TWAP pricing
    ///        or commit-reveal). Mitigations for integrators:
    ///          - Enforce TIGHT amountTokenMin / amountETHMin (e.g., 1%
    ///            slippage tolerance, not 50%)
    ///          - Route through MEV-protected RPC endpoints (Flashbots
    ///            Protect, MEV-Share, or Berachain's equivalent)
    ///          - Surface the slippage risk in the LP-create UX so users
    ///            can opt into private-mempool submission
    ///
    /// @dev F-8 MEDIUM (report 18, fixed): the non-init join used to encode
    ///        `minBPTOut = 0`, reasoning that `amountTokenMin`/`amountETHMin`
    ///        already bounded the INPUT side. They don't bound the OUTPUT
    ///        side: the token/ETH split is itself derived from spot reserves
    ///        (see the MEV-risk note above), so a manipulated ratio can pass
    ///        the input-side checks while still handing back far less BPT
    ///        than the true pre-manipulation price implied. Added a caller-
    ///        supplied `minLiquidity` floor, threaded into the Vault's own
    ///        `minBPTOut` for non-init joins (authoritative — the Vault
    ///        reverts before returning if unmet) AND independently checked
    ///        against the actual `balanceOf(to)` delta after the join, so an
    ///        INIT join (which has no native minBPTOut slot in Balancer's
    ///        userData layout) is covered too.
    ///        NOTE — PUBLIC SIGNATURE CHANGE: adds `minLiquidity` as a new
    ///        parameter (between `amountETHMin` and `to`). This contract is
    ///        not deployed anywhere, so there is no live caller to migrate;
    ///        any future LPModule/router wiring must pass this parameter.
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        uint256 minLiquidity,
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

        // ── Wrap exact native amount + pull the token leg ──
        IWETH(WETH).deposit{value: amountETH}();
        // F-fee-on-transfer (economic module finding, fixed): don't assume
        // the transfer delivered `amountToken`. Measure what actually
        // arrived — a fee-on-transfer token delivers less, and approving /
        // joining against the pre-fee figure would have the Vault try to
        // pull more than this adapter actually holds. Mirrors the
        // `AdapterPull.pullMeasured` pattern already used by
        // UbeswapCeloAdapter / DragonSwapSeiAdapter / MoeRouterAdapter /
        // TraderJoeAvaxAdapter for the same reason. Reassigning the named
        // return keeps every downstream use (approve, join amounts, the
        // LPAdded event) consistent with what was really pulled.
        amountToken = IERC20(token).pullMeasured(msg.sender, amountToken);

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
            // First-ever join: INIT. Balancer's INIT userData layout has no
            // minBPTOut slot — the post-join balance-delta check below is
            // this join's only BPT floor.
            userData = abi.encode(JOIN_KIND_INIT, amounts);
        } else {
            // Subsequent: EXACT_TOKENS_IN_FOR_BPT_OUT. F-8 fix: minBPTOut is
            // now the caller-supplied `minLiquidity`, not a hardcoded 0 — the
            // Vault enforces it authoritatively and reverts before returning
            // if unmet, closing the "manipulated ratio ⇒ starved BPT" gap.
            userData = abi.encode(JOIN_KIND_EXACT_TOKENS_IN_FOR_BPT_OUT, amounts, minLiquidity);
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

        // F-8 fix, second layer: enforce the floor on what was ACTUALLY
        // received regardless of join kind (covers INIT, which has no
        // Vault-level minBPTOut, and double-checks the non-init path).
        if (liquidity < minLiquidity) revert InsufficientOutput();

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
    /// @dev F-VaultReentrancy (verified, HIGH): `vault.getPoolTokens` is a
    ///      READ, and Balancer V2's read-only reentrancy issue means it can
    ///      return transiently-inconsistent balances if called while the
    ///      Vault is mid-operation for someone else (see
    ///      `VaultReentrancyLib` for the full mechanism). `nonReentrant` on
    ///      `addLiquidityETH` does not catch this — it guards against a
    ///      SECOND call into this adapter, not a FIRST call that happens to
    ///      land mid-callback of an unrelated Vault operation. Guard here,
    ///      immediately before the read.
    function _getReservesSorted(bytes32 poolId, address token)
        private view returns (uint256 reserveToken, uint256 reserveWeth)
    {
        VaultReentrancyLib.ensureNotInVaultContext(vault);
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
    ///            (1) nonReentrant precludes a SECOND call into this same
    ///                adapter while the first is still executing — see the
    ///                CORRECTION below for what it does NOT cover.
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
    ///        - CORRECTION (verified, HIGH — the three claims above that
    ///          `nonReentrant` alone makes the `getPoolTokens` reads below
    ///          safe were WRONG and have been fixed, not just reworded):
    ///          `nonReentrant` blocks re-ENTERING this adapter; it does not
    ///          block a FIRST entry into this adapter's `getPoolTokens`
    ///          reads while the Vault is mid-operation for some UNRELATED
    ///          caller (e.g. that caller's own `exitPool` sending them
    ///          native ETH mid-callback, from which they call back into
    ///          Magneta). During that window the Vault's balances are
    ///          transiently inconsistent, so the `balancesBefore` read two
    ///          lines below could be skewed before this function's own
    ///          `nonReentrant` lock is even relevant. `VaultReentrancyLib`
    ///          is now called immediately before that read to close the gap.
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

        // SC02 mitigation v6 (Sentinelleai 2026-06-10):
        // Authoritative `amountA` / `amountB` come from the Balancer Vault's
        // own pool-balance tracking via the `getPoolTokens` deltas below.
        // The Vault's internal accounting is the source of truth for "how
        // much did the pool send to us". CORRECTION (verified, HIGH): this
        // comment used to claim the read below was "atomic within this
        // transaction (nonReentrant precludes interleaving)" — that is only
        // true against a SECOND call into THIS adapter. It does not stop a
        // FIRST call into this adapter's `getPoolTokens` read landing while
        // the Vault is mid-operation for an unrelated caller (read-only
        // reentrancy — see `VaultReentrancyLib`), which is exactly the
        // window where "before" could already be stale. Guarded below. Any
        // token dust ERC20-transferred directly to the adapter is EXCLUDED
        // from the delta and stays as residue — donor self-griefs, user gets
        // exactly what the Vault sent. Owner can sweep accumulated dust
        // via `sweep()` (housekeeping, not load-bearing).
        //
        // WARNING (Sentinelleai v7 LOW SC02): Do NOT regress this function
        // to read per-token holdings of address(this) via any IERC20 view
        // function for amount accounting. That pattern is the Venus
        // Protocol 2026-03 vulnerability ($2M+). The vault delta below is
        // the ONLY correct accounting source for this code path.
        {
            VaultReentrancyLib.ensureNotInVaultContext(vault);
            (, uint256[] memory balancesBefore,) = vault.getPoolTokens(poolId);

            vault.exitPool(poolId, address(this), payable(address(this)), request);

            (, uint256[] memory balancesAfter,) = vault.getPoolTokens(poolId);

            // Pool balance DECREASED by exactly what the Vault forwarded to us.
            if (assets[0] == tokenA) {
                amountA = balancesBefore[0] - balancesAfter[0];
                amountB = balancesBefore[1] - balancesAfter[1];
            } else {
                amountA = balancesBefore[1] - balancesAfter[1];
                amountB = balancesBefore[0] - balancesAfter[0];
            }
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

        // F-fee-on-transfer (economic module finding, fixed): pull-then-
        // measure instead of assuming the transfer delivered `amountIn`.
        // Same rationale and library as `addLiquidityETH` above.
        uint256 gotIn = IERC20(path[0]).pullMeasured(msg.sender, amountIn);
        IERC20(path[0]).forceApprove(address(vault), gotIn);

        IBexVault.SingleSwap memory singleSwap = IBexVault.SingleSwap({
            poolId: poolId,
            kind: IBexVault.SwapKind.GIVEN_IN,
            assetIn: path[0],
            assetOut: path[1],
            amount: gotIn,
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
        amounts[0] = gotIn;
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
    /// @dev Sentinelleai 2026-06-10 v7 MEDIUM SC01: this function is
    ///      gated by Ownable2Step. Operational mitigation (per Sentinelle
    ///      recommendation): owner SHOULD be migrated to a 3-of-5 multisig
    ///      with a 48-hour timelock before mainnet ops day. The
    ///      `PairRegistered` event is emitted on every registration so
    ///      off-chain monitors (magneta-listener) can alert on suspicious
    ///      admin activity even if the multisig+timelock migration is not
    ///      yet in place.
    /// @dev F-7 HIGH (report 18, fixed): this used to accept ANY non-zero
    ///      `pool` address with no relationship check to `tokenA`/`tokenB`
    ///      or this adapter's configured `vault`. A misconfiguration (wrong
    ///      chain's pool, typo'd address, or a malicious pool crafted to
    ///      answer `getPoolId()`/`getPoolTokens()` favorably) would
    ///      PERMANENTLY bind the pair — write-once (SC01 above) makes that
    ///      unrecoverable, so the earlier lack of validation turned a config
    ///      error into a permanent one. Now requires: (1) `pool` resolves a
    ///      `getPoolId()`, (2) that poolId is registered with THIS adapter's
    ///      `vault` (a pool the Vault doesn't recognize reverts inside
    ///      `getPoolTokens`), and (3) the Vault reports it holds EXACTLY
    ///      `{tokenA, tokenB}` in Balancer's sorted order — not a superset,
    ///      subset, or different pair entirely.
    function setPair(address tokenA, address tokenB, address pool) external onlyOwner {
        if (tokenA == address(0) || tokenB == address(0) || pool == address(0)) revert ZeroAddress();
        require(pairOf[tokenA][tokenB] == address(0), "BexAdapter: pair exists");
        require(pairOf[tokenB][tokenA] == address(0), "BexAdapter: pair exists");

        bytes32 poolId = IBexPool(pool).getPoolId();
        (address[] memory tokens,,) = vault.getPoolTokens(poolId);
        require(tokens.length == 2, "BexAdapter: pool not 2-asset");
        (address t0, address t1) = _sort(tokenA, tokenB);
        require(tokens[0] == t0 && tokens[1] == t1, "BexAdapter: pool token mismatch");

        pairOf[tokenA][tokenB] = pool;
        pairOf[tokenB][tokenA] = pool;
        emit PairRegistered(tokenA, tokenB, pool, msg.sender);
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
