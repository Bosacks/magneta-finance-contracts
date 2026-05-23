// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PromotionPayment
 * @notice Collects on-chain payment for the Promote Token feature.
 *         User calls pay(token, durationCode) with msg.value >= price[durationCode];
 *         contract forwards the value to feeRecipient and emits PromotionPaid.
 *         An off-chain indexer (Terminal API) listens to PromotionPaid and
 *         creates the promotion record. No promotion is recorded without an
 *         on-chain payment, eliminating spam and chargeback risk.
 *
 *         Duration codes are integers (1..N) mapped to durations (hours) and
 *         prices in native wei. Owner (Safe) sets prices via setPrice().
 */
contract PromotionPayment is Ownable2Step, ReentrancyGuard {
    /// @notice Native price (wei) per duration code. 0 = code disabled.
    mapping(uint8 => uint256) public priceByCode;

    /// @notice Native receiver of payments. Defaults to deployer; switch to FeeVault via setFeeRecipient.
    address public feeRecipient;

    /// @notice Accumulated payment fees awaiting `withdraw()` to feeRecipient.
    ///         Pull-payment pattern (Sentinelle HIGH SC10 2026-05-22) —
    ///         a reverting feeRecipient can only block `withdraw`, not
    ///         `pay`, so payments never DoS.
    uint256 public accumulatedFees;

    event PromotionPaid(
        address indexed payer,
        address indexed token,
        uint8 indexed durationCode,
        uint256 amountPaid,
        uint256 timestamp
    );
    event PriceUpdated(uint8 indexed durationCode, uint256 oldPrice, uint256 newPrice);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice Pay for a promotion of `token` for the given duration code.
     * @param token         Token being promoted; MUST be a deployed contract
     *                      (`code.length > 0`). This is the cheapest on-chain
     *                      validation we can do; the off-chain indexer is
     *                      responsible for verifier-style allowlisting before
     *                      displaying the promotion (Sentinelle MEDIUM SC04).
     * @param durationCode  Code mapped to a native price by `priceByCode`.
     * @param maxPrice      Caller's accepted price ceiling (slippage guard).
     *                      Pass `type(uint256).max` to disable. Excess
     *                      `msg.value` above the live `price` is REFUNDED to
     *                      msg.sender — no more silent-donation semantics
     *                      (Sentinelle MEDIUM SC03).
     */
    function pay(address token, uint8 durationCode, uint256 maxPrice) external payable nonReentrant {
        require(token != address(0), "Invalid token");
        require(token.code.length > 0, "Token not a contract");
        uint256 price = priceByCode[durationCode];
        require(price > 0, "Unknown duration code");
        require(price <= maxPrice, "Price exceeds maxPrice");
        require(msg.value >= price, "Insufficient payment");

        // Effects: accrue the fee internally; refund the excess after.
        accumulatedFees += price;

        uint256 refund = msg.value - price;
        emit PromotionPaid(msg.sender, token, durationCode, price, block.timestamp);

        // Interactions last (CEI). Refund first; failure here means the
        // caller is a contract that refuses receives — that's their bug,
        // they shouldn't be overpaying.
        if (refund > 0) {
            (bool okRefund, ) = payable(msg.sender).call{value: refund}("");
            require(okRefund, "Refund failed");
        }
    }

    /// @notice Owner-only release of accumulated fees to `feeRecipient`.
    function withdraw() external onlyOwner {
        uint256 amount = accumulatedFees;
        require(amount > 0, "No fees to withdraw");
        accumulatedFees = 0;
        address payable recipient = payable(feeRecipient);
        emit FeesWithdrawn(recipient, amount);
        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "Withdraw failed");
    }

    // ─── Admin ─────────────────────────────────────────────────────────

    function setPrice(uint8 durationCode, uint256 newPrice) external onlyOwner {
        emit PriceUpdated(durationCode, priceByCode[durationCode], newPrice);
        priceByCode[durationCode] = newPrice;
    }

    function setPricesBatch(uint8[] calldata codes, uint256[] calldata prices) external onlyOwner {
        require(codes.length == prices.length, "Length mismatch");
        for (uint256 i = 0; i < codes.length; i++) {
            emit PriceUpdated(codes[i], priceByCode[codes[i]], prices[i]);
            priceByCode[codes[i]] = prices[i];
        }
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid recipient");
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }
}
