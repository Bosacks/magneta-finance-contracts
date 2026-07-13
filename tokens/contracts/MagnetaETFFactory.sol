// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/// ⚠️ NOT FOR PRODUCTION ⚠️
///
/// MagnetaETFFactory is V1.1+ scope — ETF basket is outside V1 launch.
/// Sentinelle Multi-AI 2026-05-22 returned CAUTION 72/100 with:
///   - MEDIUM SC06: hard-coded 1-hour Chainlink staleness threshold —
///     too lax for low-volume feeds, too strict for cross-chain feeds.
///   - MEDIUM SC08: executeWithdraw lacks nonReentrant.
///   - LOWs: reentrancy-adjacent ordering in createETF / executeWithdraw
///     (mitigated by nonReentrant on createETF + recipient trust).
/// Address the oracle-staleness configurability and add nonReentrant
/// to executeWithdraw before any production use.

import "./MagnetaETF.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AggregatorV3Interface
 * @dev Minimal Chainlink price-feed interface (no external dependency needed).
 */
interface AggregatorV3Interface {
    function latestRoundData()
        external view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        );
    function decimals() external view returns (uint8);
}

/**
 * @title MagnetaETFFactory
 * @dev Factory for creating MagnetaETF instances.
 *
 *      The creation fee is fixed at $2 000 USD, converted to the chain's
 *      native token at the time of creation using a Chainlink price feed.
 *      A manual fallback fee can be set for chains without Chainlink coverage.
 *
 *      A 2 % tolerance is applied so the transaction does not revert if
 *      the price moves slightly between the frontend quote and on-chain
 *      execution.
 */
contract MagnetaETFFactory is Ownable2Step, ReentrancyGuard {

    // ── Constants ────────────────────────────────────────────────────────

    uint256 public constant CREATE_FEE_USD     = 2000;  // $2 000
    uint256 public constant FEE_TOLERANCE_BPS  = 200;   // 2 %
    uint256 public constant PRICE_STALENESS    = 1 hours;
    uint256 public constant ADMIN_TIMELOCK     = 24 hours;

    // ── State ────────────────────────────────────────────────────────────

    address public treasury;
    AggregatorV3Interface public priceFeed;    // native / USD
    uint256 public fallbackFeeNative;          // manual override (wei)

    mapping(address => address[]) public userETFs;
    address[] public allETFs;

    /// @dev Maps action hash → timestamp when it becomes executable (0 = not queued)
    mapping(bytes32 => uint256) public pendingActions;

    // ── Structs ──────────────────────────────────────────────────────────

    struct CreateETFParams {
        string                        name;
        string                        symbol;
        uint8                         decimals_;
        uint256                       totalSupply;
        MagnetaETF.Asset[]            assets;
        MagnetaETF.BootstrapMode      bootstrapMode;
        uint256                       lockDuration;
        MagnetaETF.RebalanceFrequency rebalanceFrequency;
        bool                          closeEnabled;
    }

    // ── Events ───────────────────────────────────────────────────────────

    event ETFCreated(
        address indexed etfAddress,
        address indexed creator,
        string  name,
        string  symbol
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event PriceFeedUpdated(address indexed feed);
    event FallbackFeeUpdated(uint256 newFee);
    event Withdrawn(address indexed to, uint256 amount);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionExecuted(bytes32 indexed actionId);
    event ActionCancelled(bytes32 indexed actionId);

    // ── Constructor ──────────────────────────────────────────────────────

    /**
     * @param treasury_   Address that receives creation fees.
     * @param priceFeed_  Chainlink native/USD feed (address(0) to use fallback).
     */
    constructor(address treasury_, address priceFeed_) Ownable(msg.sender) {
        require(treasury_ != address(0), "MagnetaETFFactory: zero treasury");
        treasury = treasury_;

        if (priceFeed_ != address(0)) {
            priceFeed = AggregatorV3Interface(priceFeed_);
        }
    }

    // ── Fee calculation ──────────────────────────────────────────────────

    /**
     * @dev Returns the creation fee in native-token wei.
     *      Uses the Chainlink feed when available, otherwise the manual
     *      fallback fee set by the owner.
     *
     *      Math (Chainlink):
     *        price      = native / USD with `feedDecimals` decimals
     *        feeInWei   = CREATE_FEE_USD * 10^(18 + feedDecimals) / price
     */
    function getCreateFeeNative() public view returns (uint256) {
        if (address(priceFeed) != address(0)) {
            (
                /* roundId */,
                int256 answer,
                /* startedAt */,
                uint256 updatedAt,
                /* answeredInRound */
            ) = priceFeed.latestRoundData();

            require(answer > 0,                                "MagnetaETFFactory: bad price");
            require(block.timestamp - updatedAt <= PRICE_STALENESS, "MagnetaETFFactory: stale price");

            uint8 feedDecimals = priceFeed.decimals();
            return (CREATE_FEE_USD * 10 ** (18 + feedDecimals)) / uint256(answer);
        }

        require(fallbackFeeNative > 0, "MagnetaETFFactory: no fee source");
        return fallbackFeeNative;
    }

    // ── Create ETF ───────────────────────────────────────────────────────

    /**
     * @dev Deploy a new MagnetaETF and collect the creation fee.
     *      All parameters are packed into a `CreateETFParams` struct
     *      to avoid stack-depth issues.
     */
    function createETF(CreateETFParams calldata p)
        external payable nonReentrant returns (address)
    {
        // ── Fee check ────────────────────────────────────────────────
        uint256 requiredFee = getCreateFeeNative();
        uint256 minFee      = (requiredFee * (10000 - FEE_TOLERANCE_BPS)) / 10000;
        require(msg.value >= minFee, "MagnetaETFFactory: insufficient fee");

        // ── Deploy ───────────────────────────────────────────────────
        MagnetaETF etf = new MagnetaETF(
            p.name,
            p.symbol,
            p.decimals_,
            p.totalSupply,
            msg.sender,
            p.assets,
            p.bootstrapMode,
            p.lockDuration,
            p.rebalanceFrequency,
            p.closeEnabled
        );

        address etfAddress = address(etf);
        userETFs[msg.sender].push(etfAddress);
        allETFs.push(etfAddress);

        emit ETFCreated(etfAddress, msg.sender, p.name, p.symbol);

        // ── Send fee to treasury, refund excess ──────────────────────
        (bool sent, ) = payable(treasury).call{value: requiredFee}("");
        require(sent, "MagnetaETFFactory: fee transfer failed");

        // Refund any overpayment to the sender
        uint256 excess = msg.value - requiredFee;
        if (excess > 0) {
            (bool refunded, ) = payable(msg.sender).call{value: excess}("");
            require(refunded, "MagnetaETFFactory: refund failed");
        }

        return etfAddress;
    }

    // ── Admin (timelocked) ──────────────────────────────────────────────

    // ─── Treasury ────────────────────────────────────────────────────

    function queueSetTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "MagnetaETFFactory: zero address");
        bytes32 actionId = keccak256(abi.encode("setTreasury", newTreasury));
        pendingActions[actionId] = block.timestamp + ADMIN_TIMELOCK;
        emit ActionQueued(actionId, pendingActions[actionId]);
    }

    function executeSetTreasury(address newTreasury) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setTreasury", newTreasury));
        uint256 executeAfter = pendingActions[actionId];
        require(executeAfter != 0,               "MagnetaETFFactory: not queued");
        require(block.timestamp >= executeAfter,  "MagnetaETFFactory: timelock active");
        require(newTreasury != address(0),        "MagnetaETFFactory: zero address");

        delete pendingActions[actionId];
        address old = treasury;
        treasury = newTreasury;

        emit ActionExecuted(actionId);
        emit TreasuryUpdated(old, newTreasury);
    }

    // ─── Price Feed ──────────────────────────────────────────────────

    function queueSetPriceFeed(address feed) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setPriceFeed", feed));
        pendingActions[actionId] = block.timestamp + ADMIN_TIMELOCK;
        emit ActionQueued(actionId, pendingActions[actionId]);
    }

    function executeSetPriceFeed(address feed) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setPriceFeed", feed));
        uint256 executeAfter = pendingActions[actionId];
        require(executeAfter != 0,               "MagnetaETFFactory: not queued");
        require(block.timestamp >= executeAfter,  "MagnetaETFFactory: timelock active");

        delete pendingActions[actionId];
        priceFeed = AggregatorV3Interface(feed);

        emit ActionExecuted(actionId);
        emit PriceFeedUpdated(feed);
    }

    // ─── Fallback Fee ────────────────────────────────────────────────

    function queueSetFallbackFee(uint256 fee) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setFallbackFee", fee));
        pendingActions[actionId] = block.timestamp + ADMIN_TIMELOCK;
        emit ActionQueued(actionId, pendingActions[actionId]);
    }

    function executeSetFallbackFee(uint256 fee) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setFallbackFee", fee));
        uint256 executeAfter = pendingActions[actionId];
        require(executeAfter != 0,               "MagnetaETFFactory: not queued");
        require(block.timestamp >= executeAfter,  "MagnetaETFFactory: timelock active");

        delete pendingActions[actionId];
        fallbackFeeNative = fee;

        emit ActionExecuted(actionId);
        emit FallbackFeeUpdated(fee);
    }

    // ─── Withdraw ────────────────────────────────────────────────────

    function queueWithdraw() external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("withdraw"));
        pendingActions[actionId] = block.timestamp + ADMIN_TIMELOCK;
        emit ActionQueued(actionId, pendingActions[actionId]);
    }

    /// @dev Execute a previously queued withdrawal of native tokens.
    function executeWithdraw() external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("withdraw"));
        uint256 executeAfter = pendingActions[actionId];
        require(executeAfter != 0,               "MagnetaETFFactory: not queued");
        require(block.timestamp >= executeAfter,  "MagnetaETFFactory: timelock active");

        delete pendingActions[actionId];

        uint256 balance = address(this).balance;
        require(balance > 0, "MagnetaETFFactory: no balance");
        address payable recipient = payable(owner());

        emit ActionExecuted(actionId);
        emit Withdrawn(recipient, balance);

        (bool success, ) = recipient.call{value: balance}("");
        require(success, "MagnetaETFFactory: withdraw failed");
    }

    // ─── Cancel ──────────────────────────────────────────────────────

    /// @dev Cancel any queued timelock action.
    function cancelAction(bytes32 actionId) external onlyOwner {
        require(pendingActions[actionId] != 0, "MagnetaETFFactory: not queued");
        delete pendingActions[actionId];
        emit ActionCancelled(actionId);
    }

    // ── View helpers ─────────────────────────────────────────────────────

    function getUserETFs(address user) external view returns (address[] memory) {
        return userETFs[user];
    }

    function getETFCount() external view returns (uint256) {
        return allETFs.length;
    }
}
