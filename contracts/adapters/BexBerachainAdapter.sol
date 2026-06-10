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
    ///         a 50/50 weighted pool if one doesn't exist for (token, WBERA),
    ///         then joins.
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

        // 1. Wrap native → WBERA
        IWETH(WETH).deposit{value: msg.value}();
        amountETH = msg.value;

        // 2. Pull token from msg.sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountTokenDesired);
        amountToken = amountTokenDesired;

        // 3. Pool: lazy create
        (address pool, bytes32 poolId) = _ensurePool(token, WETH);

        // 4. Approve both to Vault
        IERC20(token).forceApprove(address(vault), amountToken);
        IERC20(WETH).forceApprove(address(vault), amountETH);

        // 5. Build sorted JoinPoolRequest
        (address[] memory assets, uint256[] memory amounts) =
            _sortedAssets(token, WETH, amountToken, amountETH);

        bytes memory userData;
        if (IBexPool(pool).totalSupply() == 0) {
            // First-ever join: INIT
            userData = abi.encode(JOIN_KIND_INIT, amounts);
        } else {
            // Subsequent: EXACT_TOKENS_IN_FOR_BPT_OUT with no minBPT bound
            // (Magneta UX trusts Vault's accounting; LPModule already
            // enforces user slippage via amountTokenMin/amountETHMin below).
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

        // 6. Slippage checks (V2 facade contract — LPModule expects min bounds)
        if (amountToken < amountTokenMin) revert InsufficientOutput();
        if (amountETH < amountETHMin) revert InsufficientOutput();

        emit LPAdded(token, pool, amountToken, amountETH, liquidity);
    }

    /// @notice V2 → BEX exitPool. Burns BPT for proportional token+native.
    ///
    /// @dev Sentinelleai re-scan 2026-06-10 (HIGH SC02 + HIGH SC08) fixed:
    ///        - SC02: amounts are now pre-computed from pool state via
    ///          `_previewExit` (proportional bptIn/totalSupply per
    ///          Balancer V2 WeightedPool EXACT_BPT_IN_FOR_TOKENS_OUT
    ///          math). balanceOf(this) is no longer in the amount path,
    ///          eliminating the Venus-Protocol-2026-03 manipulation pattern.
    ///        - SC08: CEI compliance — emit + state finalization happen
    ///          BEFORE any external interactions (token transfers,
    ///          WBERA.withdraw, native call to `to`).
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

        // ── Pre-compute proportional amounts from pool state (SC02 fix) ──
        (uint256 expectedToken, uint256 expectedWeth) =
            _previewExit(pool, poolId, tokenA, liquidity);

        if (expectedToken < amountAMin) revert InsufficientOutput();
        if (expectedWeth < amountBMin) revert InsufficientOutput();

        // ── Effects (SC08 fix — finalise state + emit BEFORE externals) ──
        amountA = expectedToken;
        amountB = expectedWeth;
        emit LPRemoved(tokenA, pool, amountA, amountB, liquidity);

        // ── Interactions (CEI: external calls last) ──
        IERC20(pool).safeTransferFrom(msg.sender, address(this), liquidity);

        (address[] memory assets, uint256[] memory minAmounts) =
            _sortedAssets(tokenA, tokenB, amountAMin, amountBMin);
        IBexVault.ExitPoolRequest memory request = IBexVault.ExitPoolRequest({
            assets: assets,
            minAmountsOut: minAmounts,
            userData: abi.encode(EXIT_KIND_EXACT_BPT_IN_FOR_TOKENS_OUT, liquidity),
            toInternalBalance: false
        });
        vault.exitPool(poolId, address(this), payable(address(this)), request);

        IERC20(tokenA).safeTransfer(to, expectedToken);
        IWETH(WETH).withdraw(expectedWeth);
        (bool success, ) = payable(to).call{value: expectedWeth}("");
        if (!success) revert RefundFailed();
    }

    /// @dev Pre-computes proportional withdrawal amounts for a Balancer V2
    ///      WeightedPool exit via EXACT_BPT_IN_FOR_TOKENS_OUT. Matches the
    ///      pool's actual exit math (`amountOut[i] = balances[i] * bptIn /
    ///      totalSupply`). Used to avoid balanceOf-delta accounting (Sentinelleai
    ///      SC02 mitigation 2026-06-10).
    function _previewExit(
        address pool, bytes32 poolId, address tokenA, uint256 liquidity
    ) private view returns (uint256 expectedToken, uint256 expectedWeth) {
        (address[] memory tokens, uint256[] memory balances,) = vault.getPoolTokens(poolId);
        require(tokens.length == 2, "BexAdapter: pool not 2-asset");
        uint256 totalBpt = IBexPool(pool).totalSupply();
        require(totalBpt > 0, "BexAdapter: empty pool");
        require(liquidity <= totalBpt, "BexAdapter: liquidity > supply");

        uint256 e0 = (balances[0] * liquidity) / totalBpt;
        uint256 e1 = (balances[1] * liquidity) / totalBpt;
        // Map by sort order — Balancer V2 returns tokens sorted ASC.
        if (tokens[0] == tokenA) {
            (expectedToken, expectedWeth) = (e0, e1);
        } else {
            (expectedToken, expectedWeth) = (e1, e0);
        }
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
    function setPair(address tokenA, address tokenB, address pool) external onlyOwner {
        if (tokenA == address(0) || tokenB == address(0) || pool == address(0)) revert ZeroAddress();
        pairOf[tokenA][tokenB] = pool;
        pairOf[tokenB][tokenA] = pool;
    }

    /// @notice Accept native unwraps from WBERA so removeLiquidity →
    ///         WBERA.withdraw → ETH lands here before we forward it out.
    receive() external payable {
        require(msg.sender == WETH, "BexAdapter: only WBERA refund");
    }
}
