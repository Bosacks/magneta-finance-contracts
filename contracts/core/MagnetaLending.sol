// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// ⚠️ NOT FOR PRODUCTION ⚠️
///
/// MagnetaLending is V1.1+ scope — lending / flash-loan surface is
/// outside V1 launch. Sentinelle Multi-AI audit #13 (2026-07-30)
/// returned 2 CRITICAL + 7 findings on this contract, all remediated
/// in this pass:
///   - F-2 CRITICAL: `totalSupplied`/`totalBorrowed` were nominal
///     (principal-only) accumulators. Repaying or withdrawing an
///     interest-inclusive amount subtracted more than the stale
///     nominal figure held, underflowing and bricking the reserve
///     (last depositors could never withdraw). FIXED: shares
///     (`totalSupplyShares`/`totalDebtShares`) are now the sole
///     source of truth; underlying totals are derived on read via
///     the index (`getTotalSupplied`/`getTotalBorrowed`).
///   - F-3 CRITICAL: borrow power was gated on `liquidationThreshold`
///     instead of `ltv`, so a position could be opened already
///     inside its own liquidation band. FIXED: `avgLtv` (borrow
///     power) and `avgLiquidationThreshold` (health factor /
///     liquidation) are now computed and used separately.
///   - F-7 HIGH (previously flagged 2026-05-22 as SC02): borrow()
///     and flashLoan() used raw `balanceOf(address(this))` for
///     liquidity math, trivially manipulable via direct ERC20
///     donations (Venus Protocol March 2026 $2M+ pattern). RESOLVED:
///     liquidity checks now use an internal `availableCash` ledger
///     per reserve; `balanceOf` is only read to verify flash-loan
///     repayment.
///   - F-8 HIGH: fee-on-transfer tokens could mint shares / clear
///     debt against the nominal amount instead of what was actually
///     received. FIXED: deposit/repay/liquidate all measure the
///     actual balance delta.
///   - F-9 HIGH: an unrelated stale/misconfigured oracle blocked
///     borrow/withdraw/liquidate for users with zero exposure to
///     that reserve. FIXED: reserves with 0 collateral and 0 debt
///     shares are skipped before any `getAssetPrice` call.
///   - F-11/F-18 MEDIUM: flash-loan premiums were not accounted for
///     anywhere, and duplicate assets in one call were not rejected.
///     FIXED: premiums split reserve-factor/suppliers via
///     `protocolFees`/`supplyIndex`; duplicate assets revert.
///   - F-19 HIGH: `initReserve` accepted any ltv/threshold and no
///     price feed, and there was no way to patch a live reserve's
///     risk params without redeploying. FIXED: bounds enforced at
///     init, feed required first; `setReserveParams`/
///     `setReserveActive` added.
///   - F-22: share mint/burn rounding was not directionally
///     protocol-favoring. FIXED: deposits/borrows mint (round
///     down/up respectively away from the user); withdrawals/repays
///     burn (round up/down respectively, also away from the user).
///
/// This remediation pass changes the ABI (`ReserveData` layout,
/// `calculateUserAccountData` return values, several revert
/// strings) — a redeploy is required regardless of prior testnet
/// deployments. Do NOT deploy to production until the full V1.1
/// audit pass is complete.

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title MagnetaLending
 * @dev Prototype Lending Protocol for Magneta Finance.
 * Implements Supply, Borrow, Repay, and FlashLoan features.
 * This is a simplified version (MVP) for audit and functional testing.
 */
contract MagnetaLending is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Data Structures ---

    struct ReserveData {
        bool isActive;
        uint256 totalSupplyShares;  // Shares are the source of truth; underlying is derived via supplyIndex.
        uint256 totalDebtShares;    // Shares are the source of truth; underlying is derived via borrowIndex.
        uint256 availableCash;      // Internal cash ledger — NOT balanceOf(this). Donations never inflate this.
        uint256 ltv;           // Loan to Value (e.g., 7500 = 75%)
        uint256 liquidationThreshold;
        uint256 supplyIndex;    // For interest accrual
        uint256 borrowIndex;    // For interest accrual
        uint256 lastUpdateTimestamp;
        uint8 decimals;
    }

    struct UserData {
        mapping(address => uint256) collateralShares;
        mapping(address => uint256) debtShares;
    }

    /**
     * Oracle config per asset.
     * Defends against the Moonwell-class incident (composite cbETH/ETH × ETH/USD
     * misconfigured to a flat $1 feed → $1.8M bad debt) and Ribbon-class decimal
     * mismatches by:
     *  - caching feed.decimals() at registration (no implicit assumption)
     *  - enforcing absolute min/max bounds in 18-dec normalized space
     *  - enforcing per-update max deviation vs lastPrice (anti flash-pump)
     *  - supporting composite ratio×USD feeds for LSTs/LRTs
     */
    struct FeedConfig {
        address feed;             // USD feed (Chainlink AggregatorV3)
        address ratioFeed;        // Optional: ratio feed (e.g. cbETH/ETH). 0 = pure USD feed
        uint8 feedDecimals;       // Cached at registration
        uint8 ratioDecimals;      // Cached at registration (0 if no ratio feed)
        uint256 minPrice;         // 18-dec floor (revert if observed < min)
        uint256 maxPrice;         // 18-dec ceiling (revert if observed > max)
        uint256 maxDeviationBps;  // Max delta vs lastPrice (0 = disabled)
        uint256 lastPrice;        // Last validated price (18 dec), updated by mutating ops
        bool isSet;
    }

    // --- State Variables ---

    mapping(address => ReserveData) public reserves;
    address[] public allReserves;

    mapping(address => UserData) private users;
    mapping(address => FeedConfig) public priceFeeds; // Asset -> oracle config

    /// @notice Accrued protocol share of flash-loan premiums, withdrawable by the owner.
    mapping(address => uint256) public protocolFees;

    uint256 public constant SECONDS_PER_YEAR = 31536000;
    uint256 public constant BASE_RATE = 2e16; // 2% Base APY
    uint256 public constant KINK = 8e17;      // 80% Utilization Kink
    uint256 public constant SLOPE1 = 4e16;    // 4% Slope before kink
    uint256 public constant SLOPE2 = 1e18;    // 100% Slope after kink

    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5% bonus for liquidators
    uint256 public constant HEALTH_FACTOR_THRESHOLD = 1e18;
    uint256 public constant BPS_DIVISOR = 10000;
    uint256 public constant FLASHLOAN_FEE_BPS = 9; // 0.09% fee
    uint256 public constant RESERVE_FACTOR_BPS = 1000; // 10%
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600; // 1 hour
    uint256 public constant PRICE_PRECISION = 1e18;

    // --- Errors ---

    error DuplicateFlashLoanAsset(address asset);

    // --- Events ---

    event Deposit(address indexed asset, address indexed user, uint256 amount);
    event Withdraw(address indexed asset, address indexed user, uint256 amount);
    event Borrow(address indexed asset, address indexed user, uint256 amount);
    event Repay(address indexed asset, address indexed user, uint256 amount);
    event FlashLoan(address indexed target, address indexed asset, uint256 amount, uint256 fee);
    event Liquidation(address indexed user, address indexed debtAsset, address indexed collateralAsset, uint256 amountRepaid, uint256 collateralSeized, address liquidator);
    event PriceFeedSet(address indexed asset, address feed, address ratioFeed, uint256 minPrice, uint256 maxPrice, uint256 maxDeviationBps);
    event PriceLastUpdated(address indexed asset, uint256 price);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event PauserAdded(address indexed account);
    event PauserRemoved(address indexed account);
    event ProtocolFeesWithdrawn(address indexed asset, address indexed to, uint256 amount);
    event ReserveParamsUpdated(address indexed asset, uint256 ltv, uint256 liquidationThreshold);
    event ReserveActiveSet(address indexed asset, bool isActive);

    /// @notice Canonical human guardian (back-compat view). Kept in sync with
    ///         {isPauser} by {setPauseGuardian}. Prefer {addPauser}/{removePauser}.
    address public pauseGuardian;

    /// @notice Multi-pauser set. Any address with isPauser[addr] == true may
    ///         call {pause}. UNPAUSE remains owner-only.
    mapping(address => bool) public isPauser;

    modifier onlyOwnerOrPauser() {
        require(
            msg.sender == owner() || isPauser[msg.sender],
            "MagnetaLending: not owner or pauser"
        );
        _;
    }

    constructor() {}

    // --- Admin Functions ---

    function initReserve(
        address asset,
        uint256 ltv,
        uint256 liquidationThreshold
    ) external onlyOwner {
        require(!reserves[asset].isActive, "Reserve already active");
        require(
            ltv > 0 && liquidationThreshold >= ltv && liquidationThreshold <= BPS_DIVISOR,
            "Invalid risk params"
        );
        require(priceFeeds[asset].isSet, "Price feed not set");
        // NOTE: Aderyn flags this as a CEI violation, but reading metadata before state initialization is safe.
        uint8 decimals = IERC20Metadata(asset).decimals();
        reserves[asset] = ReserveData({
            isActive: true,
            totalSupplyShares: 0,
            totalDebtShares: 0,
            availableCash: 0,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            supplyIndex: 1e18,
            borrowIndex: 1e18,
            lastUpdateTimestamp: block.timestamp,
            decimals: decimals
        });
        allReserves.push(asset);
    }

    /**
     * @dev Update risk params on an already-initialized reserve, without a
     * redeploy. Same bounds as {initReserve}.
     */
    function setReserveParams(
        address asset,
        uint256 ltv,
        uint256 liquidationThreshold
    ) external onlyOwner {
        ReserveData storage reserve = reserves[asset];
        require(reserve.supplyIndex != 0, "Reserve not initialized");
        require(
            ltv > 0 && liquidationThreshold >= ltv && liquidationThreshold <= BPS_DIVISOR,
            "Invalid risk params"
        );
        reserve.ltv = ltv;
        reserve.liquidationThreshold = liquidationThreshold;
        emit ReserveParamsUpdated(asset, ltv, liquidationThreshold);
    }

    /**
     * @dev Toggle a reserve's active flag. Inactive reserves refuse new
     * deposit()/borrow() calls but always allow withdraw()/repay()/
     * liquidate() — users must never be locked out of exiting a market.
     */
    function setReserveActive(address asset, bool active) external onlyOwner {
        ReserveData storage reserve = reserves[asset];
        require(reserve.supplyIndex != 0, "Reserve not initialized");
        reserve.isActive = active;
        emit ReserveActiveSet(asset, active);
    }

    /**
     * @dev Register or replace an asset's price feed configuration.
     *
     * @param asset           Underlying asset address.
     * @param feed            Chainlink-style USD feed (or ETH-denominated feed if used with ratioFeed).
     * @param ratioFeed       Optional ratio feed for LSTs/LRTs (e.g. cbETH/ETH). Pass address(0) for direct USD feeds.
     *                        When set, getAssetPrice = normalize(feed) * normalize(ratioFeed) / 1e18.
     *                        This is the protection that would have prevented the Moonwell cbETH incident.
     * @param minPrice        Sanity floor in 18-dec normalized space. Reverts if observed price < minPrice.
     * @param maxPrice        Sanity ceiling in 18-dec normalized space. Reverts if observed price > maxPrice.
     * @param maxDeviationBps Maximum allowed deviation vs lastPrice in basis points. 0 disables the check.
     *
     * Decimals are read from the feed(s) at registration so an oracle swap to a feed with different
     * decimals does not silently break price scaling (Ribbon-class incident).
     */
    function setPriceFeed(
        address asset,
        address feed,
        address ratioFeed,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 maxDeviationBps
    ) external onlyOwner {
        require(asset != address(0), "Invalid asset");
        require(feed != address(0), "Invalid feed");
        require(maxPrice > minPrice, "Invalid bounds");
        require(maxDeviationBps <= BPS_DIVISOR, "Deviation > 100%");

        uint8 fDec = AggregatorV3Interface(feed).decimals();
        uint8 rDec = 0;
        if (ratioFeed != address(0)) {
            rDec = AggregatorV3Interface(ratioFeed).decimals();
        }

        priceFeeds[asset] = FeedConfig({
            feed: feed,
            ratioFeed: ratioFeed,
            feedDecimals: fDec,
            ratioDecimals: rDec,
            minPrice: minPrice,
            maxPrice: maxPrice,
            maxDeviationBps: maxDeviationBps,
            lastPrice: 0,
            isSet: true
        });

        emit PriceFeedSet(asset, feed, ratioFeed, minPrice, maxPrice, maxDeviationBps);
    }

    // --- Internal/Interest Functions ---

    /**
     * @dev mulDiv rounding UP. No external dependency — small, self-contained
     * helper used wherever a share burn or debt-share mint must round away
     * from the user (protocol-favoring direction, F-22).
     */
    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        uint256 product = x * y;
        if (product == 0) return 0;
        return (product - 1) / denominator + 1;
    }

    /**
     * @dev Total underlying currently supplied to `asset`, derived from
     * shares × index. This is interest-inclusive and always in sync — there
     * is no separate nominal accumulator to drift out of step (F-2).
     */
    function _totalSuppliedUnderlying(address asset) internal view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        return (reserve.totalSupplyShares * reserve.supplyIndex) / 1e18;
    }

    /**
     * @dev Total underlying currently borrowed from `asset`, derived from
     * shares × index (F-2).
     */
    function _totalBorrowedUnderlying(address asset) internal view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        return (reserve.totalDebtShares * reserve.borrowIndex) / 1e18;
    }

    /// @notice Interest-inclusive total supplied for `asset`.
    function getTotalSupplied(address asset) public view returns (uint256) {
        return _totalSuppliedUnderlying(asset);
    }

    /// @notice Interest-inclusive total borrowed for `asset`.
    function getTotalBorrowed(address asset) public view returns (uint256) {
        return _totalBorrowedUnderlying(asset);
    }

    /**
     * @dev Updates reserve data including interest accrual based on utilization
     */
    function _updateReserve(address asset) internal {
        ReserveData storage reserve = reserves[asset];
        if (block.timestamp <= reserve.lastUpdateTimestamp) return;

        uint256 timeDelta = block.timestamp - reserve.lastUpdateTimestamp;
        uint256 utilization = getUtilization(asset);
        uint256 borrowRate = getBorrowRate(asset, utilization);

        // Update Borrow Index
        uint256 borrowIndexDelta = (reserve.borrowIndex * borrowRate * timeDelta) / (SECONDS_PER_YEAR * 1e18);
        reserve.borrowIndex += borrowIndexDelta;

        // Update Supply Index (Supply Rate = Borrow Rate * Utilization * (1 - Reserve Factor))
        uint256 supplyIndexDelta = (reserve.supplyIndex * borrowRate * utilization * (BPS_DIVISOR - RESERVE_FACTOR_BPS) * timeDelta) / (1e36 * BPS_DIVISOR * SECONDS_PER_YEAR);
        reserve.supplyIndex += supplyIndexDelta;

        reserve.lastUpdateTimestamp = block.timestamp;
    }

    /// @dev Utilization is computed on interest-inclusive derived totals — never on
    /// stale nominal accumulators (F-2).
    function getUtilization(address asset) public view returns (uint256) {
        uint256 totalSupplied = _totalSuppliedUnderlying(asset);
        if (totalSupplied == 0) return 0;
        uint256 totalBorrowed = _totalBorrowedUnderlying(asset);
        return (totalBorrowed * 1e18) / totalSupplied;
    }

    function getBorrowRate(address asset, uint256 utilization) public pure returns (uint256) {
        if (utilization <= KINK) {
            return BASE_RATE + (utilization * SLOPE1) / KINK;
        } else {
            return BASE_RATE + SLOPE1 + ((utilization - KINK) * SLOPE2) / (1e18 - KINK);
        }
    }

    /**
     * @dev Read & validate a single Chainlink-style feed. Returns raw int as uint256.
     */
    function _readFeed(address feedAddr) internal view returns (uint256) {
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feedAddr).latestRoundData();
        require(price > 0, "Invalid price");
        require(updatedAt > 0 && block.timestamp - updatedAt <= PRICE_STALENESS_THRESHOLD, "Stale price");
        require(answeredInRound >= roundId, "Incomplete round");
        return uint256(price);
    }

    /**
     * @dev Normalize an arbitrary-decimal price to 18-dec fixed point.
     */
    function _normalize(uint256 price, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return price;
        if (dec < 18) return price * (10 ** (18 - dec));
        return price / (10 ** (dec - 18));
    }

    /**
     * @dev Returns asset price normalized to 18 decimals with all guards applied.
     *
     * Guards:
     *   1. Feed staleness + round completeness (basic Chainlink hygiene)
     *   2. Composite (ratioFeed × usdFeed) for LSTs — prevents Moonwell-class incidents
     *      where an LST is priced via a flat USD feed instead of (ratio × ETH/USD)
     *   3. Decimal normalization read from feed at registration — prevents Ribbon-class
     *      decimal-mismatch losses
     *   4. Hard min/max bounds in 18-dec space — sanity floor/ceiling
     *   5. Max-deviation cap vs lastPrice — defense-in-depth against single-block manipulation
     *
     * `view` so it can be called from health-factor calculations. lastPrice is updated by
     * mutating ops via _refreshLastPrice(). On first call (lastPrice == 0) the deviation
     * check is skipped — bounds + staleness still apply.
     */
    function getAssetPrice(address asset) public view returns (uint256) {
        FeedConfig storage cfg = priceFeeds[asset];
        require(cfg.isSet, "Price feed not set");

        uint256 price18 = _normalize(_readFeed(cfg.feed), cfg.feedDecimals);

        if (cfg.ratioFeed != address(0)) {
            uint256 ratio18 = _normalize(_readFeed(cfg.ratioFeed), cfg.ratioDecimals);
            price18 = (price18 * ratio18) / PRICE_PRECISION;
        }

        require(price18 >= cfg.minPrice, "Price below floor");
        require(price18 <= cfg.maxPrice, "Price above ceiling");

        if (cfg.lastPrice != 0 && cfg.maxDeviationBps != 0) {
            uint256 diff = price18 > cfg.lastPrice ? price18 - cfg.lastPrice : cfg.lastPrice - price18;
            uint256 deviationBps = (diff * BPS_DIVISOR) / cfg.lastPrice;
            require(deviationBps <= cfg.maxDeviationBps, "Price deviation too high");
        }

        return price18;
    }

    /**
     * @dev Refresh lastPrice for an asset. Called by mutating ops so the deviation
     * cap has a recent reference. No-op if feed not configured.
     */
    function _refreshLastPrice(address asset) internal {
        if (!priceFeeds[asset].isSet) return;
        uint256 price = getAssetPrice(asset);
        priceFeeds[asset].lastPrice = price;
        emit PriceLastUpdated(asset, price);
    }

    /**
     * @dev Permissionless: anyone can re-anchor lastPrice for an asset by reading
     * the validated price now. Useful for keepers to keep the deviation reference
     * fresh on assets that are sitting as collateral but not actively traded.
     * Reverts under the same conditions as getAssetPrice (bounds/staleness/round/dev).
     */
    function refreshPrice(address asset) external {
        _refreshLastPrice(asset);
    }

    /**
     * @dev Aggregates a user's account across all reserves.
     *
     * F-9: a reserve the user has zero exposure to (0 collateral AND 0 debt
     * shares) is skipped entirely — including the `getAssetPrice` call — so a
     * stale/misconfigured feed on a market the user never touched cannot
     * block their borrow/withdraw/liquidate on other markets.
     *
     * F-3: `avgLtv` (weighted by `reserve.ltv`) and `avgLiquidationThreshold`
     * (weighted by `reserve.liquidationThreshold`) are computed and returned
     * separately. `avgLtv` gates borrow power; `avgLiquidationThreshold`
     * drives `healthFactor`, which gates withdraw/liquidate. Since
     * ltv <= liquidationThreshold always (enforced at init/param-set), a
     * position sized to avgLtv is guaranteed to be above HF 1 at inception.
     */
    function calculateUserAccountData(address user) public view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 avgLtv,
        uint256 avgLiquidationThreshold,
        uint256 healthFactor
    ) {
        uint256 totalLtvWeight = 0;
        uint256 totalThresholdWeight = 0;
        for (uint256 i = 0; i < allReserves.length; i++) {
            address asset = allReserves[i];
            uint256 collateralShares = users[user].collateralShares[asset];
            uint256 debtShares = users[user].debtShares[asset];
            if (collateralShares == 0 && debtShares == 0) continue; // F-9: no oracle call for unused reserves

            uint256 assetPrice = getAssetPrice(asset);
            ReserveData storage reserve = reserves[asset];

            if (collateralShares > 0) {
                // Normalize to 18 decimals: (amount * price) / 10^decimals
                uint256 collateralValue = (collateralShares * reserve.supplyIndex * assetPrice) / (1e18 * (10 ** reserve.decimals));
                totalCollateralBase += collateralValue;
                totalLtvWeight += collateralValue * reserve.ltv;
                totalThresholdWeight += collateralValue * reserve.liquidationThreshold;
            }

            if (debtShares > 0) {
                // Normalize to 18 decimals: (amount * price) / 10^decimals
                uint256 debtValue = (debtShares * reserve.borrowIndex * assetPrice) / (1e18 * (10 ** reserve.decimals));
                totalDebtBase += debtValue;
            }
        }

        avgLtv = totalCollateralBase == 0 ? 0 : totalLtvWeight / totalCollateralBase;
        avgLiquidationThreshold = totalCollateralBase == 0 ? 0 : totalThresholdWeight / totalCollateralBase;
        healthFactor = calculateHealthFactor(totalCollateralBase, totalDebtBase, avgLiquidationThreshold);
    }

    /// @dev `avgFactorBps` is whichever bps figure the caller wants the health
    /// factor computed against — `calculateUserAccountData` always passes
    /// `avgLiquidationThreshold` here (F-3).
    function calculateHealthFactor(
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 avgFactorBps
    ) public pure returns (uint256) {
        if (totalDebtBase == 0) return type(uint256).max;
        return (totalCollateralBase * avgFactorBps * 1e18) / (totalDebtBase * BPS_DIVISOR);
    }

    // --- User Functions ---

    /**
     * @dev Deposit tokens as collateral or for interest.
     *
     * F-8: shares are minted on the amount actually received (post
     * fee-on-transfer), not the nominal `amount` requested. F-22: shares
     * round DOWN (protocol-favoring); a deposit too small to mint a whole
     * share reverts instead of silently donating dust.
     */
    function deposit(address asset, uint256 amount) external nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        ReserveData storage reserve = reserves[asset];
        require(reserve.isActive, "Reserve not active");
        require(amount > 0, "Amount must be > 0");

        _updateReserve(asset);

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        uint256 shares = (received * 1e18) / reserve.supplyIndex; // round down
        require(shares > 0, "Deposit amount too small");
        users[msg.sender].collateralShares[asset] += shares;
        reserve.totalSupplyShares += shares;
        reserve.availableCash += received;

        emit Deposit(asset, msg.sender, received);
    }

    /**
     * @dev Withdraw tokens from collateral.
     *
     * F-7: gated on `availableCash` (real spendable cash), not balanceOf.
     * F-22: shares burned round UP, capped to the caller's balance — belt
     * and suspenders, the cap is not reachable given the rounding direction
     * of the prior mint, but kept explicit for defense in depth.
     */
    function withdraw(address asset, uint256 amount) external nonReentrant whenNotPaused {
        ReserveData storage reserve = reserves[asset];
        _updateReserve(asset);

        uint256 userShares = users[msg.sender].collateralShares[asset];
        uint256 userBalance = (userShares * reserve.supplyIndex) / 1e18;
        require(userBalance >= amount, "Insufficient balance");

        uint256 sharesToBurn = _mulDivUp(amount, 1e18, reserve.supplyIndex);
        if (sharesToBurn > userShares) sharesToBurn = userShares;
        users[msg.sender].collateralShares[asset] = userShares - sharesToBurn;
        reserve.totalSupplyShares -= sharesToBurn;

        require(reserve.availableCash >= amount, "Insufficient liquidity");
        reserve.availableCash -= amount;

        if (getUserTotalDebt(msg.sender) > 0) {
            _refreshLastPrice(asset);
            (, , , , uint256 healthFactor) = calculateUserAccountData(msg.sender);
            require(healthFactor >= 1e18, "Health factor too low after withdrawal");
        }

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdraw(asset, msg.sender, amount);
    }

    /**
     * @dev Borrow tokens against collateral.
     *
     * F-7: liquidity gated on `availableCash`, not balanceOf — a direct
     * ERC20 donation to the contract no longer inflates borrowable liquidity.
     * F-3: borrow power is gated on `avgLtv` (not the liquidation threshold);
     * since ltv <= liquidationThreshold always, this implies HF >= 1e18 on
     * every newly-opened position. F-22: debt shares round UP (protocol
     * favoring — the borrower owes at least what they took).
     */
    function borrow(address asset, uint256 amount) external nonReentrant whenNotPaused {
        ReserveData storage reserve = reserves[asset];
        require(reserve.isActive, "Reserve not active");
        require(reserve.availableCash >= amount, "Insufficient liquidity");

        _updateReserve(asset);

        uint256 shares = _mulDivUp(amount, 1e18, reserve.borrowIndex);
        require(shares > 0, "Borrow amount too small");
        users[msg.sender].debtShares[asset] += shares;
        reserve.totalDebtShares += shares;
        reserve.availableCash -= amount;

        _refreshLastPrice(asset);
        (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 avgLtv, , ) = calculateUserAccountData(msg.sender);
        require(
            totalDebtBase <= (totalCollateralBase * avgLtv) / BPS_DIVISOR,
            "Borrow exceeds LTV limit"
        );

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(asset, msg.sender, amount);
    }

    /**
     * @dev Repay borrowed tokens.
     *
     * F-8: debt is reduced by the amount actually received (post
     * fee-on-transfer), capped at the outstanding debt. `type(uint256).max`
     * still means "repay everything" — it pulls the full nominal debt, then
     * measures what arrived. F-22: debt shares burned round DOWN.
     */
    function repay(address asset, uint256 amount) external nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        ReserveData storage reserve = reserves[asset];

        _updateReserve(asset);

        uint256 userDebt = (users[msg.sender].debtShares[asset] * reserve.borrowIndex) / 1e18;

        if (amount == type(uint256).max) {
            amount = userDebt;
        }

        require(userDebt >= amount, "Repay amount exceeds debt");

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;

        // Fee-on-transfer: only what actually arrived clears debt.
        uint256 effectiveRepay = received > userDebt ? userDebt : received;

        uint256 sharesToBurn;
        if (effectiveRepay == userDebt) {
            sharesToBurn = users[msg.sender].debtShares[asset];
        } else {
            sharesToBurn = (effectiveRepay * 1e18) / reserve.borrowIndex; // round down
        }

        users[msg.sender].debtShares[asset] -= sharesToBurn;
        reserve.totalDebtShares -= sharesToBurn;
        reserve.availableCash += received;

        emit Repay(asset, msg.sender, effectiveRepay);
    }


    /**
     * @dev Liquidate a user with health factor < 1.0.
     * @param user The address of the user to liquidate
     * @param debtAsset The asset to repay on behalf of the user
     * @param collateralAsset The asset to seize from the user
     * @param amountToRepay The amount of debt to repay
     *
     * F-8: the debt asset is pulled first and the actual amount received
     * drives the seizure math — not the nominal `amountToRepay` — so a
     * fee-on-transfer debt asset cannot be used to seize more collateral
     * than was actually repaid. F-7: collateral seizure decrements
     * `availableCash`, and repayment credits it. F-22: debt shares burn
     * round DOWN (repay direction), collateral shares burn round UP
     * (withdraw direction), both protocol-favoring.
     */
    function liquidate(
        address user,
        address debtAsset,
        address collateralAsset,
        uint256 amountToRepay
    ) external nonReentrant {
        _updateReserve(debtAsset);
        _updateReserve(collateralAsset);

        _refreshLastPrice(debtAsset);
        _refreshLastPrice(collateralAsset);

        (, , , , uint256 healthFactor) = calculateUserAccountData(user);
        require(healthFactor < HEALTH_FACTOR_THRESHOLD, "User is healthy");

        ReserveData storage debtReserve = reserves[debtAsset];
        ReserveData storage collateralReserve = reserves[collateralAsset];

        uint256 userDebt = (users[user].debtShares[debtAsset] * debtReserve.borrowIndex) / 1e18;
        require(amountToRepay <= userDebt, "Repay amount exceeds user debt");

        uint256 balanceBefore = IERC20(debtAsset).balanceOf(address(this));
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), amountToRepay);
        uint256 received = IERC20(debtAsset).balanceOf(address(this)) - balanceBefore;

        // Calculate collateral to seize: (repaidAmount * debtPrice / collateralPrice) * (1 + bonus)
        // Adjusting for decimals: (amount * debtPrice / 10^debtDecimals) / (collateralPrice / 10^collateralDecimals)
        uint256 debtPrice = getAssetPrice(debtAsset);
        uint256 collateralPrice = getAssetPrice(collateralAsset);
        uint8 debtDecimals = debtReserve.decimals;
        uint8 collateralDecimals = collateralReserve.decimals;

        uint256 collateralToSeize = (received * debtPrice * (10 ** collateralDecimals) * (BPS_DIVISOR + LIQUIDATION_BONUS_BPS)) /
                                   (collateralPrice * (10 ** debtDecimals) * BPS_DIVISOR);

        uint256 userCollateralShares = users[user].collateralShares[collateralAsset];
        uint256 userCollateral = (userCollateralShares * collateralReserve.supplyIndex) / 1e18;
        require(userCollateral >= collateralToSeize, "Insufficient collateral to seize");

        // Execute liquidation
        uint256 debtSharesToBurn = (received * 1e18) / debtReserve.borrowIndex; // round down
        users[user].debtShares[debtAsset] -= debtSharesToBurn;
        debtReserve.totalDebtShares -= debtSharesToBurn;
        debtReserve.availableCash += received;

        uint256 collateralSharesToBurn = _mulDivUp(collateralToSeize, 1e18, collateralReserve.supplyIndex);
        if (collateralSharesToBurn > userCollateralShares) collateralSharesToBurn = userCollateralShares;
        users[user].collateralShares[collateralAsset] = userCollateralShares - collateralSharesToBurn;
        collateralReserve.totalSupplyShares -= collateralSharesToBurn;
        require(collateralReserve.availableCash >= collateralToSeize, "Insufficient liquidity");
        collateralReserve.availableCash -= collateralToSeize;

        IERC20(collateralAsset).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidation(user, debtAsset, collateralAsset, received, collateralToSeize, msg.sender);
    }

    /**
     * @dev Simple FlashLoan implementation.
     *
     * F-18: duplicate assets in one call are rejected up front (arrays are
     * small in practice, O(n^2) is cheap and simple).
     * F-7: liquidity is drawn from/returned to `availableCash`, not
     * balanceOf. F-11: the premium is now accounted for — `RESERVE_FACTOR_BPS`
     * of it goes to `protocolFees` (withdrawable via
     * {withdrawProtocolFees}), the rest is distributed to suppliers by
     * bumping `supplyIndex`. If a reserve has no suppliers, the supplier
     * share is routed to the protocol instead of being lost.
     */
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external nonReentrant {
        require(msg.sender != address(0), "Invalid sender");
        require(assets.length == amounts.length, "Array length mismatch");

        // F-18: reject duplicate assets — small arrays, O(n^2) is fine.
        for (uint256 i = 0; i < assets.length; i++) {
            for (uint256 j = i + 1; j < assets.length; j++) {
                if (assets[i] == assets[j]) revert DuplicateFlashLoanAsset(assets[i]);
            }
        }

        uint256[] memory premiums = new uint256[](assets.length);
        // Store balances before issuing loans so repayment can be verified without
        // relying on safeTransferFrom(receiverAddress, ...) which Slither flags as
        // arbitrary-from. The receiver can repay by any means (direct transfer, etc.).
        uint256[] memory balancesBefore = new uint256[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amount = amounts[i];
            ReserveData storage reserve = reserves[assets[i]];
            require(reserve.availableCash >= amount, "Insufficient liquidity");

            balancesBefore[i] = IERC20(assets[i]).balanceOf(address(this));
            premiums[i] = (amount * FLASHLOAN_FEE_BPS) / BPS_DIVISOR;

            reserve.availableCash -= amount;
            IERC20(assets[i]).safeTransfer(receiverAddress, amount);
        }

        require(
            IFlashLoanReceiver(receiverAddress).executeOperation(assets, amounts, premiums, msg.sender, params),
            "FlashLoan callback failed"
        );

        // Verify repayment: balance must be >= pre-loan balance + fee.
        // The receiver must have transferred principal + premium back to this address
        // inside executeOperation() before returning.
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 balanceAfter = IERC20(assets[i]).balanceOf(address(this));
            require(
                balanceAfter >= balancesBefore[i] + premiums[i],
                "Flash loan not repaid"
            );

            ReserveData storage reserve = reserves[assets[i]];
            // Credit the returned principal plus whatever actually came back on
            // top of the pre-loan balance (>= premium, verified above).
            // `balancesBefore` was snapshotted BEFORE the principal left, so the
            // balance delta alone is only the net gain (premium + any extra) —
            // the principal that was debited from availableCash when the loan
            // was issued must be credited back explicitly, otherwise the cash
            // ledger leaks `amount - premium` on every flash loan and
            // borrow/withdraw eventually DoS on "Insufficient liquidity".
            uint256 netGain = balanceAfter - balancesBefore[i];
            reserve.availableCash += amounts[i] + netGain;

            uint256 protocolCut = (premiums[i] * RESERVE_FACTOR_BPS) / BPS_DIVISOR;
            uint256 supplierCut = premiums[i] - protocolCut;

            if (supplierCut > 0) {
                if (reserve.totalSupplyShares > 0) {
                    reserve.supplyIndex += (supplierCut * 1e18) / reserve.totalSupplyShares;
                } else {
                    // No suppliers to credit — route to protocol instead of losing it.
                    protocolCut += supplierCut;
                }
            }
            protocolFees[assets[i]] += protocolCut;

            emit FlashLoan(receiverAddress, assets[i], amounts[i], premiums[i]);
        }
    }

    /// @notice Withdraw accrued protocol fees (flash-loan reserve-factor cut) for `asset`.
    function withdrawProtocolFees(address asset, address to) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid recipient");
        uint256 amount = protocolFees[asset];
        require(amount > 0, "No fees to withdraw");
        protocolFees[asset] = 0;

        ReserveData storage reserve = reserves[asset];
        require(reserve.availableCash >= amount, "Insufficient liquidity");
        reserve.availableCash -= amount;

        IERC20(asset).safeTransfer(to, amount);
        emit ProtocolFeesWithdrawn(asset, to, amount);
    }

    // --- Admin Functions ---

    function pause() external onlyOwnerOrPauser {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Grant an address the pauser role. Owner-only.
    function addPauser(address account) public onlyOwner {
        require(account != address(0), "MagnetaLending: zero pauser");
        isPauser[account] = true;
        emit PauserAdded(account);
    }

    /// @notice Revoke an address's pauser role. Owner-only.
    function removePauser(address account) external onlyOwner {
        require(account != address(0), "MagnetaLending: zero pauser");
        isPauser[account] = false;
        emit PauserRemoved(account);
    }

    /// @notice Deprecated single-guardian setter, retained for back-compat.
    ///         Rotates the canonical {pauseGuardian} within {isPauser}.
    function setPauseGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "MagnetaLending: zero guardian");
        address old = pauseGuardian;
        if (old != address(0)) {
            isPauser[old] = false;
            emit PauserRemoved(old);
        }
        pauseGuardian = _guardian;
        isPauser[_guardian] = true;
        emit PauserAdded(_guardian);
        emit PauseGuardianUpdated(old, _guardian);
    }

    // --- View Functions ---

    function getUserCollateral(address user, address asset) external view returns (uint256) {
        return (users[user].collateralShares[asset] * reserves[asset].supplyIndex) / 1e18;
    }

    function getUserBorrow(address user, address asset) public view returns (uint256) {
        return (users[user].debtShares[asset] * reserves[asset].borrowIndex) / 1e18;
    }

    /// @dev Never touches the oracle (getUserBorrow is index-based only), so F-9's
    /// "skip unused reserves before pricing" concern does not apply here — kept
    /// as a plain sum, used only as a `> 0` gate in {withdraw}.
    function getUserTotalDebt(address user) public view returns (uint256) {
        uint256 totalDebt = 0;
        for (uint256 i = 0; i < allReserves.length; i++) {
            totalDebt += getUserBorrow(user, allReserves[i]);
        }
        return totalDebt;
    }
}
