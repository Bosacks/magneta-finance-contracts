// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 }            from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }         from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard }   from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Ownable }           from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  BexBerachainAdapter — STUB (Sprint LP-unlock Berachain V1.1)
/// @notice Uniswap V2 router facade over BEX (Berachain's Balancer V2 fork).
///         Mirrors `UbeswapCeloAdapter.sol` / `DragonSwapSeiAdapter.sol`
///         shape so `LPModule.sol` can call this without modification.
///
///         STATUS as of 2026-06-07: function signatures + storage skeleton
///         are in place. The function bodies marked `revert NotImplemented()`
///         must be implemented in the V1.1 dedicated session. See the
///         per-function notes for the BEX call to make.
///
/// @dev    BEX security advisory (CRITICAL — read before deploying):
///         Balancer V2 (which BEX forks) has a disclosed token-frontrun
///         vulnerability as of 2026-01-21:
///         https://forum.balancer.fi/t/balancer-v2-token-frontrun-vulnerability-disclosure/6309
///
///         Impact on Magneta's flow:
///           - Tokens deployed BEFORE the LP pool is created are NOT affected
///             (Magneta's UX always creates the token first, then the LP)
///           - Tokens that don't exist at pool-creation time COULD be exploited
///           - LPModule currently never creates pools for not-yet-deployed
///             tokens, so the practical exposure is zero. Document this
///             clearly in the deploy script anyway so future refactors don't
///             silently regress the assumption.
///
///         Berachain's roadmap is to upgrade BEX to Balancer V3 codebase,
///         which mitigates the vulnerability. If/when that happens, this
///         adapter should be redeployed against the V3 Vault.
///
///         Mainnet BEX addresses (verified on docs.berachain.com 2026-06-07):
///           Vault                 0x4Be03f781C497A489E3cB0287833452cA9B9E80B
///           WeightedPoolFactory   0xa966fA8F2d5B087FFFA499C0C1240589371Af409
///           BalancerQueries       0x3C612e132624f4Bd500eE1495F54565F0bcc9b59
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
    /// @dev Signature shape per the BEX WeightedPoolFactory.create ABI.
    ///      Verify the exact tuple layout before wiring (the doc ABI link
    ///      in the design doc has the canonical typing).
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

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
}

// ─── Adapter contract ────────────────────────────────────────────────────

contract BexBerachainAdapter is ReentrancyGuard, Ownable {
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
    uint256 public constant SWAP_FEE = 3e15;

    /// @notice Pair → BEX pool address. Populated lazily on first
    ///         addLiquidityETH() against a new pair. Setting and clearing
    ///         must keep both pair orderings in sync to avoid orphan reads.
    mapping(address => mapping(address => address)) public pairOf;

    // ─── Events ───────────────────────────────────────────────────────────

    event PairCreated(address indexed tokenA, address indexed tokenB, address indexed pool, bytes32 poolId);
    event LPAdded(address indexed token, address indexed lp, uint256 tokenAmount, uint256 ethAmount, uint256 bptMinted);
    event LPRemoved(address indexed token, address indexed lp, uint256 tokenAmount, uint256 ethAmount, uint256 bptBurned);

    // ─── Errors ───────────────────────────────────────────────────────────

    error NotImplemented();
    error ZeroAddress();
    error DeadlinePassed();
    error PoolMissing(address tokenA, address tokenB);

    constructor(address _vault, address _poolFactory, address _weth) {
        if (_vault == address(0) || _poolFactory == address(0) || _weth == address(0)) revert ZeroAddress();
        vault       = IBexVault(_vault);
        poolFactory = IBexWeightedPoolFactory(_poolFactory);
        WETH        = _weth;
        // OZ 4.x Ownable sets owner = msg.sender in the default constructor.
    }

    // ─── Read surface (LPModule calls these) ──────────────────────────────

    /// @notice V2 facade — returns this contract so `factory().getPair()`
    ///         routes back to our `getPair`.
    function factory() external view returns (address) {
        return address(this);
    }

    /// @notice V2 facade — `IUniswapV2Factory.getPair`. Returns address(0)
    ///         when the pair hasn't been created yet (LPModule treats that
    ///         as "no LP yet, fall through to addLiquidityETH which will
    ///         lazily create the pool").
    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairOf[tokenA][tokenB];
    }

    // ─── Mutation surface ─────────────────────────────────────────────────

    /// @notice V2 → BEX joinPool. Wraps msg.value to WBERA, lazily creates
    ///         a 50/50 weighted pool if one doesn't exist for (token, WBERA),
    ///         then joins.
    ///
    /// @dev TODO V1.1:
    ///        1. Wrap msg.value → WBERA via IWETH(WETH).deposit{value: ...}()
    ///        2. Pull `amountTokenDesired` of `token` from msg.sender
    ///        3. If pairOf[token][WETH] == 0:
    ///           - Sort tokens by address (Balancer requires this)
    ///           - poolFactory.create(name="MAG-XYZ", symbol="MAG-XYZ",
    ///             tokens=[sortedA, sortedB], normalizedWeights=[5e17, 5e17],
    ///             rateProviders=[0, 0], swapFeePercentage=SWAP_FEE,
    ///             owner=address(this), salt=bytes32(0))
    ///           - pool.getPoolId() → poolId; store pairOf[a][b] = pool
    ///           - Emit PairCreated
    ///        4. Approve both tokens to Vault
    ///        5. Build JoinPoolRequest with:
    ///             assets = sorted [token, WETH]
    ///             maxAmountsIn = matching desired amounts
    ///             userData = abi.encode(JoinKind.INIT, amounts) on first
    ///                        join, or JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT
    ///                        with minBPTOut = … on subsequent
    ///        6. Call vault.joinPool(poolId, address(this), to, request)
    ///        7. Compute liquidity = IERC20(pool).balanceOf(to) - balanceBefore
    ///        8. Refund any unused tokenA/tokenB to msg.sender
    ///        9. Emit LPAdded(token, pool, amountToken, amountETH, liquidity)
    function addLiquidityETH(
        address /* token */,
        uint256 /* amountTokenDesired */,
        uint256 /* amountTokenMin */,
        uint256 /* amountETHMin */,
        address /* to */,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 /* amountToken */, uint256 /* amountETH */, uint256 /* liquidity */) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        revert NotImplemented();
    }

    /// @notice V2 → BEX exitPool. Burns BPT for proportional token+native
    ///         withdrawal.
    ///
    /// @dev TODO V1.1:
    ///        1. require(tokenB == WETH) — Magneta's REMOVE_LP path always
    ///           pairs token with native. Multi-token exit out-of-scope V1.
    ///        2. pool = pairOf[tokenA][WETH]; if 0 → PoolMissing
    ///        3. poolId = pool.getPoolId()
    ///        4. Pull `liquidity` BPT from msg.sender
    ///        5. Build ExitPoolRequest with:
    ///             assets = sorted [tokenA, WETH]
    ///             minAmountsOut = [amountAMin, amountBMin] sorted
    ///             userData = abi.encode(ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT,
    ///                                   liquidity)
    ///        6. Call vault.exitPool(poolId, address(this), address(this), …)
    ///        7. Track WBERA received → unwrap → forward native to `to`
    ///        8. Track tokenA received → safeTransfer to `to`
    ///        9. Emit LPRemoved
    function removeLiquidity(
        address /* tokenA */, address tokenB,
        uint256 /* liquidity */,
        uint256 /* amountAMin */, uint256 /* amountBMin */,
        address /* to */, uint256 deadline
    ) external nonReentrant returns (uint256 /* amountA */, uint256 /* amountB */) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        require(tokenB == WETH, "BexAdapter: tokenB must be WBERA (V1 scope)");
        revert NotImplemented();
    }

    /// @notice V2 → BEX swap (GIVEN_IN, single-pool path).
    /// @dev TODO V1.1:
    ///        1. require(path.length == 2) — multi-hop out of scope V1
    ///        2. Find or pre-stage the pool for (path[0], path[1]); revert
    ///           PoolMissing if not registered
    ///        3. Pull `amountIn` of path[0] from msg.sender; approve to Vault
    ///        4. Build SingleSwap { poolId, GIVEN_IN, assetIn=path[0],
    ///                              assetOut=path[1], amount=amountIn,
    ///                              userData="" }
    ///        5. Build FundManagement { sender=address(this),
    ///                                  fromInternalBalance=false,
    ///                                  recipient=to,
    ///                                  toInternalBalance=false }
    ///        6. Call vault.swap(singleSwap, funds, limit=amountOutMin,
    ///                           deadline)
    ///        7. Return [amountIn, amountCalculated]
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 /* amountOutMin */,
        address[] calldata path,
        address /* to */,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        require(path.length == 2, "BexAdapter: multi-hop out of scope V1");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        revert NotImplemented();
    }

    /// @notice V2 → BEX swap with native in. Same as
    ///         swapExactTokensForTokens but wraps msg.value to WBERA first.
    /// @dev TODO V1.1: same as swapExactTokensForTokens with
    ///      `path[0] == WETH` assumed; wrap msg.value before the swap.
    function swapExactETHForTokens(
        uint256 /* amountOutMin */,
        address[] calldata path,
        address /* to */,
        uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        require(path.length == 2 && path[0] == WETH, "BexAdapter: bad path");
        amounts = new uint256[](path.length);
        amounts[0] = msg.value;
        revert NotImplemented();
    }

    /// @notice Owner-only: pre-register a (tokenA, tokenB) → pool mapping
    ///         after creating the pool out-of-band. Useful for chains
    ///         where Magneta wants to use an existing BEX pool instead of
    ///         deploying a fresh one. Symmetric in both orderings.
    function setPair(address tokenA, address tokenB, address pool) external onlyOwner {
        if (tokenA == address(0) || tokenB == address(0) || pool == address(0)) revert ZeroAddress();
        pairOf[tokenA][tokenB] = pool;
        pairOf[tokenB][tokenA] = pool;
        // Note: doesn't emit PairCreated — this is an admin shortcut, not
        // a fresh deployment. Future addLiquidityETH calls will see the
        // pre-registered pool and short-circuit creation.
    }

    /// @notice Accept native unwraps from WBERA so removeLiquidity →
    ///         WBERA.withdraw → ETH lands here before we forward it out.
    receive() external payable {
        require(msg.sender == WETH, "BexAdapter: only WBERA refund");
    }
}
