// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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
        uint256 totalSupplied;
        uint256 totalBorrowed;
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

    // --- State Variables ---

    mapping(address => ReserveData) public reserves;
    address[] public allReserves;
    
    mapping(address => UserData) private users;
    mapping(address => address) public priceFeeds; // Asset -> Chainlink Price Feed

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

    // --- Events ---

    event Deposit(address indexed asset, address indexed user, uint256 amount);
    event Withdraw(address indexed asset, address indexed user, uint256 amount);
    event Borrow(address indexed asset, address indexed user, uint256 amount);
    event Repay(address indexed asset, address indexed user, uint256 amount);
    event FlashLoan(address indexed target, address indexed asset, uint256 amount, uint256 fee);
    event Liquidation(address indexed user, address indexed debtAsset, address indexed collateralAsset, uint256 amountRepaid, uint256 collateralSeized, address liquidator);

    constructor() {}

    // --- Admin Functions ---

    function initReserve(
        address asset,
        uint256 ltv,
        uint256 liquidationThreshold
    ) external onlyOwner {
        require(!reserves[asset].isActive, "Reserve already active");
        // NOTE: Aderyn flags this as a CEI violation, but reading metadata before state initialization is safe.
        uint8 decimals = IERC20Metadata(asset).decimals();
        reserves[asset] = ReserveData({
            isActive: true,
            totalSupplied: 0,
            totalBorrowed: 0,
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            supplyIndex: 1e18,
            borrowIndex: 1e18,
            lastUpdateTimestamp: block.timestamp,
            decimals: decimals
        });
        allReserves.push(asset);
    }

    function setPriceFeed(address asset, address feed) external onlyOwner {
        require(asset != address(0), "Invalid asset");
        require(feed != address(0), "Invalid feed");
        priceFeeds[asset] = feed;
    }

    // --- Internal/Interest Functions ---

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

    function getUtilization(address asset) public view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        if (reserve.totalSupplied == 0) return 0;
        return (reserve.totalBorrowed * 1e18) / reserve.totalSupplied;
    }

    function getBorrowRate(address asset, uint256 utilization) public pure returns (uint256) {
        if (utilization <= KINK) {
            return BASE_RATE + (utilization * SLOPE1) / KINK;
        } else {
            return BASE_RATE + SLOPE1 + ((utilization - KINK) * SLOPE2) / (1e18 - KINK);
        }
    }

    function getAssetPrice(address asset) public view returns (uint256) {
        address feedAddress = priceFeeds[asset];
        require(feedAddress != address(0), "Price feed not set");
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feedAddress).latestRoundData();
        require(price > 0, "Invalid price");
        require(updatedAt > 0 && block.timestamp - updatedAt <= PRICE_STALENESS_THRESHOLD, "Stale price");
        require(answeredInRound >= roundId, "Incomplete round");
        return uint256(price);
    }

    function calculateUserAccountData(address user) public view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 avgLtv,
        uint256 healthFactor
    ) {
        uint256 totalLtvWeight = 0;
        for (uint256 i = 0; i < allReserves.length; i++) {
            address asset = allReserves[i];
            uint256 assetPrice = getAssetPrice(asset);
            ReserveData storage reserve = reserves[asset];
            
            uint256 collateralShares = users[user].collateralShares[asset];
            if (collateralShares > 0) {
                // Normalize to 18 decimals: (amount * price) / 10^decimals
                uint256 collateralValue = (collateralShares * reserve.supplyIndex * assetPrice) / (1e18 * (10 ** reserve.decimals));
                totalCollateralBase += collateralValue;
                totalLtvWeight += (collateralValue * reserve.liquidationThreshold);
            }

            uint256 debtShares = users[user].debtShares[asset];
            if (debtShares > 0) {
                // Normalize to 18 decimals: (amount * price) / 10^decimals
                uint256 debtValue = (debtShares * reserve.borrowIndex * assetPrice) / (1e18 * (10 ** reserve.decimals));
                totalDebtBase += debtValue;
            }
        }

        avgLtv = totalCollateralBase == 0 ? 0 : totalLtvWeight / totalCollateralBase;
        healthFactor = calculateHealthFactor(totalCollateralBase, totalDebtBase, avgLtv);
    }

    function calculateHealthFactor(
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 avgLtv
    ) public pure returns (uint256) {
        if (totalDebtBase == 0) return type(uint256).max;
        return (totalCollateralBase * avgLtv * 1e18) / (totalDebtBase * BPS_DIVISOR);
    }

    // --- User Functions ---

    /**
     * @dev Deposit tokens as collateral or for interest
     */
    function deposit(address asset, uint256 amount) external nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        ReserveData storage reserve = reserves[asset];
        require(reserve.isActive, "Reserve not active");
        require(amount > 0, "Amount must be > 0");

        _updateReserve(asset);

        uint256 shares = (amount * 1e18) / reserve.supplyIndex;
        users[msg.sender].collateralShares[asset] += shares;
        reserve.totalSupplied += amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(asset, msg.sender, amount);
    }

    /**
     * @dev Withdraw tokens from collateral
     */
    function withdraw(address asset, uint256 amount) external nonReentrant whenNotPaused {
        ReserveData storage reserve = reserves[asset];
        uint256 userBalance = (users[msg.sender].collateralShares[asset] * reserve.supplyIndex) / 1e18;
        require(userBalance >= amount, "Insufficient balance");
        
        _updateReserve(asset);

        // Re-read balancing after potential index update
        userBalance = (users[msg.sender].collateralShares[asset] * reserve.supplyIndex) / 1e18;
        require(userBalance >= amount, "Insufficient balance after update");

        uint256 sharesToBurn = (amount * 1e18) / reserve.supplyIndex;
        users[msg.sender].collateralShares[asset] -= sharesToBurn;
        reserve.totalSupplied -= amount;
        
        if (getUserTotalDebt(msg.sender) > 0) {
            (, , , uint256 healthFactor) = calculateUserAccountData(msg.sender);
            require(healthFactor >= 1e18, "Health factor too low after withdrawal");
        }

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdraw(asset, msg.sender, amount);
    }

    /**
     * @dev Borrow tokens against collateral
     */
    function borrow(address asset, uint256 amount) external nonReentrant whenNotPaused {
        ReserveData storage reserve = reserves[asset];
        require(reserve.isActive, "Reserve not active");
        // NOTE: Aderyn flags this as a CEI violation. Reading balance here is safe as the function is nonReentrant.
        require(IERC20(asset).balanceOf(address(this)) >= amount, "Insufficient liquidity");

        _updateReserve(asset);

        uint256 shares = (amount * 1e18) / reserve.borrowIndex;
        users[msg.sender].debtShares[asset] += shares;
        reserve.totalBorrowed += amount;
        
        (, , , uint256 healthFactor) = calculateUserAccountData(msg.sender);
        require(healthFactor >= 1e18, "Health factor too low to borrow");

        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Borrow(asset, msg.sender, amount);
    }

    /**
     * @dev Repay borrowed tokens
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

        uint256 sharesToBurn;
        if (amount == userDebt) {
            sharesToBurn = users[msg.sender].debtShares[asset];
        } else {
            sharesToBurn = (amount * 1e18) / reserve.borrowIndex;
        }
        
        users[msg.sender].debtShares[asset] -= sharesToBurn;
        
        // Calculate principal portion to subtract from totalBorrowed
        // Since totalBorrowed tracks principal, we need to subtract the principal portion
        uint256 principalRepaid = amount <= reserve.totalBorrowed ? amount : reserve.totalBorrowed;
        reserve.totalBorrowed -= principalRepaid;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit Repay(asset, msg.sender, amount);
    }


    /**
     * @dev Liquidate a user with health factor < 1.0
     * @param user The address of the user to liquidate
     * @param debtAsset The asset to repay on behalf of the user
     * @param collateralAsset The asset to seize from the user
     * @param amountToRepay The amount of debt to repay
     */
    function liquidate(
        address user,
        address debtAsset,
        address collateralAsset,
        uint256 amountToRepay
    ) external nonReentrant {
        _updateReserve(debtAsset);
        _updateReserve(collateralAsset);

        (, , , uint256 healthFactor) = calculateUserAccountData(user);
        require(healthFactor < HEALTH_FACTOR_THRESHOLD, "User is healthy");

        uint256 userDebt = (users[user].debtShares[debtAsset] * reserves[debtAsset].borrowIndex) / 1e18;
        require(amountToRepay <= userDebt, "Repay amount exceeds user debt");

        // Calculate collateral to seize: (repaidAmount * debtPrice / collateralPrice) * (1 + bonus)
        // Adjusting for decimals: (amount * debtPrice / 10^debtDecimals) / (collateralPrice / 10^collateralDecimals)
        uint256 debtPrice = getAssetPrice(debtAsset);
        uint256 collateralPrice = getAssetPrice(collateralAsset);
        uint8 debtDecimals = reserves[debtAsset].decimals;
        uint8 collateralDecimals = reserves[collateralAsset].decimals;
        
        uint256 collateralToSeize = (amountToRepay * debtPrice * (10 ** collateralDecimals) * (BPS_DIVISOR + LIQUIDATION_BONUS_BPS)) / 
                                   (collateralPrice * (10 ** debtDecimals) * BPS_DIVISOR);
        
        uint256 userCollateral = (users[user].collateralShares[collateralAsset] * reserves[collateralAsset].supplyIndex) / 1e18;
        require(userCollateral >= collateralToSeize, "Insufficient collateral to seize");

        // Execute liquidation
        uint256 debtSharesToBurn = (amountToRepay * 1e18) / reserves[debtAsset].borrowIndex;
        users[user].debtShares[debtAsset] -= debtSharesToBurn;
        reserves[debtAsset].totalBorrowed -= amountToRepay;
        
        uint256 collateralSharesToBurn = (collateralToSeize * 1e18) / reserves[collateralAsset].supplyIndex;
        users[user].collateralShares[collateralAsset] -= collateralSharesToBurn;
        reserves[collateralAsset].totalSupplied -= collateralToSeize;
        
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), amountToRepay);
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidation(user, debtAsset, collateralAsset, amountToRepay, collateralToSeize, msg.sender);
    }

    /**
     * @dev Simple FlashLoan implementation
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
        
        uint256[] memory premiums = new uint256[](assets.length);
        // Store balances before issuing loans so repayment can be verified without
        // relying on safeTransferFrom(receiverAddress, ...) which Slither flags as
        // arbitrary-from. The receiver can repay by any means (direct transfer, etc.).
        uint256[] memory balancesBefore = new uint256[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            uint256 amount = amounts[i];
            balancesBefore[i] = IERC20(assets[i]).balanceOf(address(this));
            require(balancesBefore[i] >= amount, "Insufficient liquidity");

            premiums[i] = (amount * FLASHLOAN_FEE_BPS) / BPS_DIVISOR;

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
            emit FlashLoan(receiverAddress, assets[i], amounts[i], premiums[i]);
        }
    }

    // --- Admin Functions ---

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- View Functions ---

    function getUserCollateral(address user, address asset) external view returns (uint256) {
        return (users[user].collateralShares[asset] * reserves[asset].supplyIndex) / 1e18;
    }

    function getUserBorrow(address user, address asset) public view returns (uint256) {
        return (users[user].debtShares[asset] * reserves[asset].borrowIndex) / 1e18;
    }

    function getUserTotalDebt(address user) public view returns (uint256) {
        uint256 totalDebt = 0;
        for (uint256 i = 0; i < allReserves.length; i++) {
            totalDebt += getUserBorrow(user, allReserves[i]);
        }
        return totalDebt;
    }
}
