// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable2Step }     from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard }  from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import { MagnetaCurveToken } from "./MagnetaCurveToken.sol";
import { MagnetaCurvePool }  from "./MagnetaCurvePool.sol";

/**
 * @title MagnetaCurveFactory
 * @notice Single-tx entry point for the Magneta bonding-curve launchpad.
 *         A user calls `createCurveToken(...)` and gets:
 *           1. A fresh ERC20 (`MagnetaCurveToken`) with their name/symbol/URI
 *           2. A bonding-curve pool (`MagnetaCurvePool`) holding the entire
 *              token supply — full inventory available for the curve
 *              allocation + the post-graduation V2 LP reserve
 *           3. Bookkeeping in `userTokens[msg.sender]` so the Tokens UI
 *              can list their launches
 *
 *         The whole launch is atomic. The user pays only gas — no Magneta
 *         fee at creation. The 1% per-trade fee on the curve covers
 *         Magneta revenue.
 *
 *         The launchpad is intentionally PERMISSIONLESS: anyone can call
 *         `createCurveToken`. Front-running / brand-squatting is a known
 *         risk (Sentinelle MEDIUM SC03 2026-05-22); the mitigation strategy
 *         lives off-chain (UI flags verified creators, indexer dedupes by
 *         project URL, etc.) rather than on-chain commit-reveal.
 */
contract MagnetaCurveFactory is Ownable2Step, ReentrancyGuard {
    /// @notice The chain's V2-strict router that the curve pools use for
    ///         post-graduation liquidity migration.
    address public router;

    /// @notice Magneta FeeVault — receives the 1% per-trade fee from every
    ///         curve pool created here.
    address public feeVault;

    /// @notice Per-creator list of tokens launched here.
    mapping(address => address[]) public userTokens;

    /// @notice Flat list of every token created, in deploy order.
    address[] public allTokens;

    /// @notice token → curve pool lookup for off-chain readers.
    mapping(address => address) public poolFor;

    // ─── Critical-setter timelock (Sentinelle HIGH SC01) ────────────────────
    //
    // setRouter / setFeeVault permanently wire any FUTURE pool to the active
    // value. A compromised owner could redirect all future graduation
    // liquidity (router) and all future per-trade fees (feeVault). The 24h
    // timelock gives the protocol time to observe the proposal and pause
    // creations if the new value is suspicious.
    uint256 public constant CRITICAL_SETTER_DELAY = 24 hours;

    address public pendingRouter;
    uint256 public pendingRouterTime;

    address public pendingFeeVault;
    uint256 public pendingFeeVaultTime;

    // ─── Per-creation parameter bounds (Sentinelle HIGH SC04) ───────────────
    //
    // Without bounds, a creator can deploy a "degenerate" pool — e.g.
    // virtualNativeReserve = 1 wei giving a near-zero initial price, or
    // graduationThreshold = type(uint256).max making graduation unreachable.
    // These pools still emit the official CurveTokenCreated event and appear
    // in the launchpad UI, lending them false legitimacy. Owner can re-tune
    // bounds for cheap-native chains.
    uint256 public minVirtualNativeReserve = 0.01 ether;
    uint256 public maxTotalSupply          = type(uint128).max;
    uint256 public minGraduationThreshold  = 0.1 ether;
    // F80: ceiling so a creator cannot pass a near-infinite graduationThreshold
    // for a pool that can never graduate yet still registers as a real launch.
    uint256 public maxGraduationThreshold  = type(uint128).max;

    // ─── Metadata caps (Sentinelle MEDIUM SC10) ─────────────────────────────
    uint256 public constant MAX_NAME_BYTES   = 64;
    uint256 public constant MAX_SYMBOL_BYTES = 16;
    uint256 public constant MAX_URI_BYTES    = 256;

    event CurveTokenCreated(
        address indexed creator,
        address indexed token,
        address indexed pool,
        string  name,
        string  symbol,
        uint256 totalSupply,
        uint256 graduationThreshold
    );

    event RouterProposed(address newRouter, uint256 applyTime);
    event FeeVaultProposed(address newVault, uint256 applyTime);
    event RouterUpdated(address oldRouter, address newRouter);
    event FeeVaultUpdated(address oldVault, address newVault);

    event ParameterBoundsUpdated(
        uint256 minVirtualNativeReserve,
        uint256 maxTotalSupply,
        uint256 minGraduationThreshold,
        uint256 maxGraduationThreshold
    );

    constructor(address router_, address feeVault_, address initialOwner) {
        require(router_ != address(0) && feeVault_ != address(0) && initialOwner != address(0), "zero address");
        router   = router_;
        feeVault = feeVault_;
        // Defer to Ownable2Step's two-step flow ONLY for post-deploy
        // transfers. The initial assignment uses the single-step
        // _transferOwnership because no acceptOwnership flow can run during
        // construction (the prospective owner has no opportunity to act).
        if (initialOwner != msg.sender) {
            _transferOwnership(initialOwner);
        }
    }

    // ─── Critical setters: propose / apply ──────────────────────────────────

    function proposeRouter(address _router) external onlyOwner {
        require(_router != address(0), "zero router");
        require(_router.code.length > 0, "router not a contract");
        pendingRouter = _router;
        pendingRouterTime = block.timestamp + CRITICAL_SETTER_DELAY;
        emit RouterProposed(_router, pendingRouterTime);
    }

    function applyRouter() external onlyOwner {
        require(pendingRouter != address(0), "no pending router");
        require(block.timestamp >= pendingRouterTime, "timelock active");
        emit RouterUpdated(router, pendingRouter);
        router = pendingRouter;
        pendingRouter = address(0);
        pendingRouterTime = 0;
    }

    function proposeFeeVault(address _feeVault) external onlyOwner {
        require(_feeVault != address(0), "zero vault");
        pendingFeeVault = _feeVault;
        pendingFeeVaultTime = block.timestamp + CRITICAL_SETTER_DELAY;
        emit FeeVaultProposed(_feeVault, pendingFeeVaultTime);
    }

    function applyFeeVault() external onlyOwner {
        require(pendingFeeVault != address(0), "no pending vault");
        require(block.timestamp >= pendingFeeVaultTime, "timelock active");
        emit FeeVaultUpdated(feeVault, pendingFeeVault);
        feeVault = pendingFeeVault;
        pendingFeeVault = address(0);
        pendingFeeVaultTime = 0;
    }

    // ─── Parameter bounds (owner tunes per chain) ───────────────────────────

    function setParameterBounds(
        uint256 _minVirtualNativeReserve,
        uint256 _maxTotalSupply,
        uint256 _minGraduationThreshold,
        uint256 _maxGraduationThreshold
    ) external onlyOwner {
        require(_minVirtualNativeReserve > 0, "zero virtual min");
        require(_maxTotalSupply > 0, "zero supply max");
        require(_minGraduationThreshold > 0, "zero threshold min");
        require(_maxGraduationThreshold >= _minGraduationThreshold, "bad threshold bounds");
        minVirtualNativeReserve = _minVirtualNativeReserve;
        maxTotalSupply          = _maxTotalSupply;
        minGraduationThreshold  = _minGraduationThreshold;
        maxGraduationThreshold  = _maxGraduationThreshold;
        emit ParameterBoundsUpdated(_minVirtualNativeReserve, _maxTotalSupply, _minGraduationThreshold, _maxGraduationThreshold);
    }

    /**
     * @notice Deploy a new curve token + pool in one tx.
     *
     * Order of operations (atomic):
     *   1. Mint full supply to the factory itself
     *   2. Deploy the pool with the token address baked in
     *   3. Transfer 100% of the supply from factory → pool
     *
     * @param name              ERC20 name
     * @param symbol            ERC20 symbol
     * @param uri               Off-chain metadata URI
     * @param totalSupply       Total token supply (e.g. 1e9 * 1e18)
     * @param curveAllocation   Tokens reserved on the curve (typ. 80% of totalSupply)
     * @param virtualNativeReserve  Initial virtual native (wei) — sets price floor
     * @param graduationThreshold   Native (wei) at which the pool migrates to V2
     */
    function createCurveToken(
        string memory name,
        string memory symbol,
        string memory uri,
        uint256 totalSupply,
        uint256 curveAllocation,
        uint256 virtualNativeReserve,
        uint256 graduationThreshold
    ) external nonReentrant returns (address token, address pool) {
        // Metadata caps prevent indexer / front-end DoS via giant strings.
        require(bytes(name).length   <= MAX_NAME_BYTES,   "name too long");
        require(bytes(symbol).length <= MAX_SYMBOL_BYTES, "symbol too long");
        require(bytes(uri).length    <= MAX_URI_BYTES,    "uri too long");

        // Economic-parameter sanity.
        require(totalSupply > 0,                                              "zero supply");
        require(totalSupply <= maxTotalSupply,                                "supply too large");
        require(curveAllocation > 0 && curveAllocation < totalSupply,         "bad alloc");
        require(virtualNativeReserve >= minVirtualNativeReserve,              "virtual too small");
        require(graduationThreshold  >= minGraduationThreshold,               "threshold too small");
        // F80: cap the graduation threshold and keep it above the virtual reserve,
        // so a creator can't register a pool that can never graduate.
        require(graduationThreshold  <= maxGraduationThreshold,               "threshold too large");
        require(graduationThreshold  >  virtualNativeReserve,                 "threshold below virtual");

        // 1. Deploy the token, mint full supply to the factory
        MagnetaCurveToken tokenContract = new MagnetaCurveToken(
            name, symbol, uri, totalSupply, address(this), msg.sender
        );
        token = address(tokenContract);

        // 2. Deploy the pool, bound to this token
        MagnetaCurvePool poolContract = new MagnetaCurvePool(
            token,
            router,
            feeVault,
            totalSupply,
            curveAllocation,
            virtualNativeReserve,
            graduationThreshold
        );
        pool = address(poolContract);

        // 3. Transfer the entire supply to the pool
        require(tokenContract.transfer(pool, totalSupply), "transfer failed");
        // Sentinelle LOW SC06: assert post-transfer balance to neutralise
        // any future MagnetaCurveToken change that adds transfer hooks or
        // fees, which would otherwise leave the pool under-funded.
        require(tokenContract.balanceOf(pool) == totalSupply, "balance mismatch");

        // Bookkeeping
        userTokens[msg.sender].push(token);
        allTokens.push(token);
        poolFor[token] = pool;

        emit CurveTokenCreated(msg.sender, token, pool, name, symbol, totalSupply, graduationThreshold);
    }

    // ─── Views ────────────────────────────────────────────────────────────

    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    /// @notice Paginated variant of `getUserTokens` for UIs/indexers that
    ///         need to read a slice instead of the whole (potentially
    ///         spam-bloated) array (Sentinelle MEDIUM SC10).
    function getUserTokensPaginated(address user, uint256 offset, uint256 limit)
        external view returns (address[] memory slice)
    {
        address[] storage arr = userTokens[user];
        uint256 len = arr.length;
        if (offset >= len) return new address[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        slice = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            slice[i - offset] = arr[i];
        }
    }

    /// @notice Paginated read of the global `allTokens` registry.
    function getAllTokensPaginated(uint256 offset, uint256 limit)
        external view returns (address[] memory slice)
    {
        uint256 len = allTokens.length;
        if (offset >= len) return new address[](0);
        uint256 end = offset + limit;
        if (end > len) end = len;
        slice = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            slice[i - offset] = allTokens[i];
        }
    }

    function getTokenCount() external view returns (uint256) {
        return allTokens.length;
    }
}
