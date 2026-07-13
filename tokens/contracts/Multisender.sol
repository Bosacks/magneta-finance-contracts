// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Multisender
 * @dev Batch send ETH and ERC20 tokens to multiple addresses in one transaction.
 *      Collects a flat fee per recipient to support the platform.
 */
contract Multisender is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Maximum number of recipients per transaction (prevents out-of-gas and loop exploits)
    uint256 public constant MAX_RECIPIENTS = 200;

    // Fee per recipient in Wei (default 0.00005 ETH)
    uint256 public feePerRecipient = 0.00005 ether;

    /// @notice Magneta FeeVault that receives accumulated multisend fees via
    ///         `withdrawFees()`. Set in constructor; updateable by owner.
    address public feeRecipient;

    event MultisendEther(uint256 total, address tokenAddress);
    event MultisendToken(address indexed token, uint256 total);
    event FeeUpdated(uint256 newFee);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    constructor(address _feeRecipient) Ownable(msg.sender) {
        feeRecipient = _feeRecipient; // zero address allowed → withdraw falls back to owner
    }

    /// @notice Update the FeeVault address. Set to address(0) to fall back
    ///         to owner-receives-fees behavior on `withdrawFees()`.
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Distribute ETH to multiple recipients.
     * @param recipients Array of recipient addresses
     * @param amounts Array of ETH amounts (in Wei) for each recipient
     */
    function multisendEther(address[] calldata recipients, uint256[] calldata amounts) external payable nonReentrant {
        require(recipients.length == amounts.length, "Arrays length mismatch");
        require(recipients.length > 0, "No recipients");
        require(recipients.length <= MAX_RECIPIENTS, "Too many recipients");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] > 0, "Zero amount");
            totalAmount += amounts[i];
        }

        uint256 totalFees = feePerRecipient * recipients.length;
        require(msg.value >= totalAmount + totalFees, "Insufficient ETH sent");

        // Refund excess ETH if any
        uint256 excess = msg.value - (totalAmount + totalFees);

        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address");
            (bool success, ) = recipients[i].call{value: amounts[i]}("");
            require(success, "Transfer failed");
        }

        if (excess > 0) {
            (bool refundSuccess, ) = msg.sender.call{value: excess}("");
            require(refundSuccess, "Refund failed");
        }

        emit MultisendEther(totalAmount, address(0));
    }

    /**
     * @dev Distribute ERC20 tokens to multiple recipients.
     *      Sender must approve this contract to spend the total tokens.
     *      A flat fee in ETH (native currency) is charged per recipient.
     * @param token Address of the ERC20 token
     * @param recipients Array of recipient addresses
     * @param amounts Array of token amounts for each recipient
     */
    function multisendToken(address token, address[] calldata recipients, uint256[] calldata amounts) external payable nonReentrant {
        require(token != address(0), "Invalid token");
        require(recipients.length == amounts.length, "Arrays length mismatch");
        require(recipients.length > 0, "No recipients");
        require(recipients.length <= MAX_RECIPIENTS, "Too many recipients");

        uint256 totalFees = feePerRecipient * recipients.length;
        require(msg.value >= totalFees, "Insufficient ETH for fees");

        uint256 totalTokens = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            require(amounts[i] > 0, "Zero amount");
            totalTokens += amounts[i];
        }

        IERC20 tokenContract = IERC20(token);

        // Measure the amount ACTUALLY received. For a fee-on-transfer /
        // deflationary token the contract receives less than `totalTokens`, so
        // distributing the full `sum(amounts)` would either revert on the last
        // recipients (whole batch griefed) or hand out tokens stranded from a
        // prior failed multisend awaiting `withdrawToken` rescue. Reject such
        // tokens up-front with a clear error. (Delta, not absolute balance, so a
        // pre-existing stuck balance of the same token isn't mistaken for input.)
        // safeTransferFrom handles non-standard ERC20s that don't return bool.
        uint256 balBefore = tokenContract.balanceOf(address(this));
        tokenContract.safeTransferFrom(msg.sender, address(this), totalTokens);
        uint256 received = tokenContract.balanceOf(address(this)) - balBefore;
        require(received >= totalTokens, "Multisender: fee-on-transfer token unsupported");

        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address");
            tokenContract.safeTransfer(recipients[i], amounts[i]);
        }

        // Refund excess ETH fee if any
        uint256 excess = msg.value - totalFees;
        if (excess > 0) {
            (bool refundSuccess, ) = msg.sender.call{value: excess}("");
            require(refundSuccess, "Refund failed");
        }

        emit MultisendToken(token, totalTokens);
    }

    /**
     * @dev Update the fee per recipient.
     */
    function setFeePerRecipient(uint256 newFee) external onlyOwner {
        feePerRecipient = newFee;
        emit FeeUpdated(newFee);
    }

    /**
     * @dev Withdraw accumulated ETH fees to the owner.
     */
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw");

        address payable to = payable(feeRecipient == address(0) ? owner() : feeRecipient);
        emit FeesWithdrawn(to, balance);
        (bool success, ) = to.call{value: balance}("");
        require(success, "Withdraw failed");
    }

    /**
     * @dev Withdraw ERC20 tokens accidentally sent to contract (rescue).
     */
    function withdrawToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token");
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        address recipient = owner();
        emit TokenRescued(token, recipient, balance);
        tokenContract.safeTransfer(recipient, balance);
    }

    // Allow contract to receive ETH (needed for fee collection)
    receive() external payable {}
}
