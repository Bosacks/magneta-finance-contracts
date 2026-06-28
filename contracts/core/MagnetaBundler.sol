// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2Router02 {
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);

    function WETH() external pure returns (address);
}

/**
 * @title MagnetaBundler
 * @notice Batched buy/sell/disperse helper over a V2 router. Hardened per the
 *         Sentinelle audit 2026-05-25 (CAUTION 42/100):
 *           - SC01 CRITICAL (mutable router rug vector): router changes go
 *             through a 24h propose→apply timelock with public cancellation,
 *             so a swap of the router (which receives unlimited forceApprove
 *             allowances) is observable on-chain before it can take effect.
 *           - SC08 HIGH (CEI / refund DoS): failed transfers no longer revert
 *             the whole batch — `disperseEther` skips-and-logs, and every
 *             sender refund / fee forward falls back to a pull-payment
 *             (`pendingWithdrawals` + `withdraw()`) when the push fails.
 *           - SC05 MEDIUM (fee-recipient liveness): `_forwardFee` credits the
 *             recipient on push failure instead of reverting fee-paying flows.
 *           - SC03 MEDIUM (stale deadline): all user-facing swap functions take
 *             a caller-supplied `deadline` instead of `block.timestamp`.
 *           - SC03 MEDIUM (single slippage min): `bundleBuy` / `sellAndBundleBuy`
 *             take a per-leg `amountOutMins[]` so a large leg can't be
 *             under-protected by a min calibrated for a small one.
 *
 * @dev    ABI CHANGE vs the pre-audit version (frontend must update):
 *           bundleBuy(token, amountOutMins[], recipients[], ethAmounts[], deadline)
 *           bundleSell(tokens[], amounts[], amountsOutMin[], deadline)
 *           atomicVolumeBrush(token, ethAmount, minEthReturned, minTokensExpected, deadline)
 *           sellAndBundleBuy(sellToken, sellAmount, minEthFromSell, buyToken,
 *                            minTokensPerBuy[], recipients[], buyAmounts[], deadline)
 *           setRouter(addr) → proposeRouter(addr) + applyRouter() + cancelRouterChange()
 */
contract MagnetaBundler is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    address public router;
    /// @notice Receives Magneta service fees forwarded on each bundleBuy /
    ///         atomicVolumeBrush call. Set to address(0) to keep the legacy
    ///         "fees stay in contract, owner rescues" behavior.
    address public feeRecipient;

    /// @notice Hard cap on the native amount forwarded as fee in a single
    ///         transaction. Defends against a buggy frontend sending an
    ///         excessive msg.value (which `_forwardFee` would otherwise
    ///         route in full to feeRecipient). Default = 1 native unit;
    ///         owner can adjust per-chain since 1 unit denominates
    ///         differently across deployments.
    uint256 public maxFeePerTx = 1 ether;

    /// @notice Optional fast-pause role. When set, can pause the contract
    ///         without going through the owner Safe (consistent with the
    ///         pause-guardian pattern elsewhere in Magneta).
    /// @notice Canonical human guardian (back-compat view). Kept in sync with
    ///         {isPauser} by {setPauseGuardian}. Prefer {addPauser}/{removePauser}.
    address public pauseGuardian;

    /// @notice Multi-pauser set. Any address with isPauser[addr] == true may
    ///         call {pause}. UNPAUSE remains owner-only.
    mapping(address => bool) public isPauser;

    // ── Router timelock (SC01) ───────────────────────────────────────────────
    /// @notice Minimum delay between proposing and applying a router change.
    uint256 public constant ROUTER_TIMELOCK = 24 hours;
    address public pendingRouter;
    uint256 public routerChangeETA;

    // ── Pull-payment fallback (SC08 / SC05) ──────────────────────────────────
    /// @notice Native owed to an address whose push transfer failed (failed
    ///         refund, failed fee forward, failed disperse leg refund). The
    ///         owed party calls withdraw() to claim. Decouples batch success
    ///         from any single recipient's ability to receive ETH.
    mapping(address => uint256) public pendingWithdrawals;
    /// @notice Sum of pendingWithdrawals — rescueETH may not dip below it.
    uint256 public totalPendingWithdrawals;

    event BundleBuy(address indexed sender, address token, uint256 totalEthAmount, uint256 successCount);
    event BundleSell(address indexed sender, address token, uint256 totalTokenAmount, uint256 successCount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeForwarded(address indexed to, uint256 amount);
    event MaxFeePerTxUpdated(uint256 oldCap, uint256 newCap);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event PauserAdded(address indexed account);
    event PauserRemoved(address indexed account);
    event RouterChangeProposed(address indexed newRouter, uint256 eta);
    event RouterChanged(address indexed oldRouter, address indexed newRouter);
    event RouterChangeCancelled(address indexed cancelledRouter);
    event DisperseSkipped(address indexed recipient, uint256 amount);
    event WithdrawalPending(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    modifier onlyOwnerOrPauser() {
        require(
            msg.sender == owner() || isPauser[msg.sender],
            "MagnetaBundler: not owner or pauser"
        );
        _;
    }

    modifier ensure(uint256 deadline) {
        require(block.timestamp <= deadline, "MagnetaBundler: expired");
        _;
    }

    constructor(address _router, address _feeRecipient) {
        require(_router != address(0), "Invalid router");
        router = _router;
        feeRecipient = _feeRecipient; // zero address allowed → keeps fees in-contract for legacy rescue
    }

    receive() external payable {}

    /// @notice Forward an arbitrary native amount to `feeRecipient` if set.
    ///         Called by mutating functions that accept `msg.value` excess so
    ///         fees route on-chain to the Magneta FeeVault without manual
    ///         rescueETH. On push failure the fee is CREDITED to the recipient
    ///         (pull) rather than reverting — removes the protocol-wide
    ///         liveness dependency on feeRecipient (Sentinelle SC05).
    function _forwardFee(uint256 amount) internal {
        if (amount == 0 || feeRecipient == address(0)) return;
        // Hard cap to neutralise a buggy/malicious frontend that sends
        // far more native than intended as fee.
        require(amount <= maxFeePerTx, "MagnetaBundler: fee exceeds cap");
        (bool ok, ) = payable(feeRecipient).call{value: amount}("");
        if (ok) {
            emit FeeForwarded(feeRecipient, amount);
        } else {
            _credit(feeRecipient, amount);
        }
    }

    /// @notice Try to push `amount` native to `to`; on failure credit it to the
    ///         pull-payment ledger so the caller's batch never reverts because a
    ///         recipient can't receive ETH (Sentinelle SC08).
    function _refundOrCredit(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) _credit(to, amount);
    }

    function _credit(address to, uint256 amount) internal {
        pendingWithdrawals[to] += amount;
        totalPendingWithdrawals += amount;
        emit WithdrawalPending(to, amount);
    }

    /// @notice Claim native owed from a failed push (refund / fee / disperse leg).
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "MagnetaBundler: nothing to withdraw");
        pendingWithdrawals[msg.sender] = 0;
        totalPendingWithdrawals -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "MagnetaBundler: withdraw failed");
        emit Withdrawn(msg.sender, amount);
    }

    // --- Core Bundling Logic ---

    /**
     * @dev Buy a token using ETH for multiple recipients in one transaction.
     * @param token         Token to buy.
     * @param amountOutMins  Per-recipient minimum tokens out (slippage). Length
     *                       must equal recipients.length — one min per leg so a
     *                       large buy isn't under-protected (Sentinelle SC03).
     * @param recipients     Addresses that receive the purchased tokens.
     * @param ethAmounts     ETH to spend per recipient.
     * @param deadline       Unix expiry passed to the router (Sentinelle SC03).
     */
    function bundleBuy(
        address token,
        uint256[] calldata amountOutMins,
        address[] calldata recipients,
        uint256[] calldata ethAmounts,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused ensure(deadline) {
        require(
            recipients.length == ethAmounts.length && recipients.length == amountOutMins.length,
            "Arrays length mismatch"
        );
        require(token != address(0), "Invalid token");

        uint256 totalRequired = 0;
        for (uint i = 0; i < ethAmounts.length; i++) {
            totalRequired += ethAmounts[i];
        }
        require(msg.value >= totalRequired, "Insufficient ETH sent");

        // Forward the Magneta service fee (msg.value excess over swap totals).
        uint256 fee = msg.value - totalRequired;
        _forwardFee(fee);

        address[] memory path = new address[](2);
        path[0] = IUniswapV2Router02(router).WETH();
        path[1] = token;

        uint256 successCount = 0;
        uint256 ethSpent = 0;

        for (uint i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address");
            try IUniswapV2Router02(router).swapExactETHForTokens{value: ethAmounts[i]}(
                amountOutMins[i],
                path,
                recipients[i],
                deadline
            ) {
                successCount++;
                ethSpent += ethAmounts[i];
            } catch {
                // Leg failed — its ETH stays in the contract and is refunded
                // to the sender below (never reverts the whole batch).
            }
        }

        // Refund only the unused buy budget — the fee was already forwarded.
        uint256 unspentEth = totalRequired - ethSpent;
        _refundOrCredit(msg.sender, unspentEth);

        emit BundleBuy(msg.sender, token, totalRequired, successCount);
    }

    /**
     * @dev Sell multiple tokens for ETH in one transaction.
     * @param tokens        Token addresses to sell.
     * @param amounts       Token amounts to sell.
     * @param amountsOutMin Per-token minimum ETH out (slippage).
     * @param deadline      Unix expiry passed to the router.
     */
    function bundleSell(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata amountsOutMin,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused ensure(deadline) {
        require(msg.sender != address(0), "Invalid sender");
        require(tokens.length == amounts.length && amounts.length == amountsOutMin.length, "Arrays length mismatch");

        // Forward the service fee (any native sent with the call) to FeeVault.
        _forwardFee(msg.value);

        uint256 totalEthReceived = 0;
        uint256 successCount = 0;

        address[] memory path = new address[](2);
        path[1] = IUniswapV2Router02(router).WETH();

        for (uint i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            IERC20(tokens[i]).forceApprove(router, amounts[i]);

            path[0] = tokens[i];

            try IUniswapV2Router02(router).swapExactTokensForETH(
                amounts[i],
                amountsOutMin[i],
                path,
                msg.sender, // Send ETH directly to user
                deadline
            ) returns (uint[] memory resultAmounts) {
                totalEthReceived += resultAmounts[resultAmounts.length - 1];
                successCount++;
            } catch {
                // If swap fails, return tokens to user and clear the allowance.
                IERC20(tokens[i]).forceApprove(router, 0);
                IERC20(tokens[i]).safeTransfer(msg.sender, amounts[i]);
            }
        }

        emit BundleSell(msg.sender, address(0), totalEthReceived, successCount);
    }

    // --- Advanced Tools ---

    /**
     * @dev Buy a token and immediately sell it back in one tx (volume gen).
     * @param token            Token to brush volume for.
     * @param ethAmount        ETH to use for buying.
     * @param minEthReturned   Minimum ETH expected back (slippage).
     * @param minTokensExpected Minimum tokens from the buy leg (slippage).
     * @param deadline         Unix expiry passed to the router.
     */
    function atomicVolumeBrush(
        address token,
        uint256 ethAmount,
        uint256 minEthReturned,
        uint256 minTokensExpected,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused ensure(deadline) {
        require(msg.value >= ethAmount, "Insufficient ETH");

        uint256 fee = msg.value - ethAmount;
        _forwardFee(fee);

        address[] memory buyPath = new address[](2);
        buyPath[0] = IUniswapV2Router02(router).WETH();
        buyPath[1] = token;

        // 1. Buy Tokens
        uint[] memory amounts = IUniswapV2Router02(router).swapExactETHForTokens{value: ethAmount}(
            minTokensExpected,
            buyPath,
            address(this),
            deadline
        );
        uint256 tokenAmount = amounts[1];

        // 2. Sell Tokens
        IERC20(token).forceApprove(router, tokenAmount);

        address[] memory sellPath = new address[](2);
        sellPath[0] = token;
        sellPath[1] = IUniswapV2Router02(router).WETH();

        uint[] memory returnAmounts = IUniswapV2Router02(router).swapExactTokensForETH(
            tokenAmount,
            minEthReturned,
            sellPath,
            msg.sender,
            deadline
        );

        emit BundleSell(msg.sender, token, returnAmounts[1], 1);
    }

    /**
     * @dev Sell one token and use the proceeds to bundle-buy another.
     * @param sellToken      Token to sell.
     * @param sellAmount     Amount of token to sell.
     * @param minEthFromSell Minimum ETH from the sell (slippage).
     * @param buyToken       Token to buy.
     * @param minTokensPerBuy Per-recipient minimum tokens out (slippage),
     *                        length must equal recipients.length (Sentinelle SC03).
     * @param recipients     Recipients for the buy.
     * @param buyAmounts     ETH to spend per recipient (sum must be ≤ proceeds).
     * @param deadline       Unix expiry passed to the router.
     */
    function sellAndBundleBuy(
        address sellToken,
        uint256 sellAmount,
        uint256 minEthFromSell,
        address buyToken,
        uint256[] calldata minTokensPerBuy,
        address[] calldata recipients,
        uint256[] calldata buyAmounts,
        uint256 deadline
    ) external payable nonReentrant whenNotPaused ensure(deadline) {
        require(msg.sender != address(0), "Invalid sender");
        require(
            recipients.length == buyAmounts.length && recipients.length == minTokensPerBuy.length,
            "Arrays length mismatch"
        );

        _forwardFee(msg.value);

        // 1. Transfer + sell the input token for ETH (proceeds held here).
        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmount);
        IERC20(sellToken).forceApprove(router, sellAmount);

        address[] memory sellPath = new address[](2);
        sellPath[0] = sellToken;
        sellPath[1] = IUniswapV2Router02(router).WETH();

        uint[] memory amounts = IUniswapV2Router02(router).swapExactTokensForETH(
            sellAmount,
            minEthFromSell,
            sellPath,
            address(this),
            deadline
        );
        uint256 ethProceeds = amounts[1];

        // 2. Bundle buy with the proceeds.
        uint256 totalRequired = 0;
        for (uint i = 0; i < buyAmounts.length; i++) {
            totalRequired += buyAmounts[i];
        }
        require(ethProceeds >= totalRequired, "Insufficient sell proceeds");

        address[] memory buyPath = new address[](2);
        buyPath[0] = IUniswapV2Router02(router).WETH();
        buyPath[1] = buyToken;

        uint256 successCount = 0;
        uint256 ethSpent = 0;
        for (uint i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address recipient");
            try IUniswapV2Router02(router).swapExactETHForTokens{value: buyAmounts[i]}(
                minTokensPerBuy[i],
                buyPath,
                recipients[i],
                deadline
            ) {
                successCount++;
                ethSpent += buyAmounts[i];
            } catch {}
        }

        // Refund unused proceeds to the seller (pull-fallback on failure).
        uint256 unspentEth = ethProceeds - ethSpent;
        _refundOrCredit(msg.sender, unspentEth);

        emit BundleBuy(msg.sender, buyToken, totalRequired, successCount);
    }

    /**
     * @dev Disperse ETH to multiple recipients (for funding wallets). A failed
     *      recipient is skipped-and-logged (never reverts the batch), and its
     *      ETH is folded into the sender refund (Sentinelle SC08).
     * @param recipients List of recipient addresses.
     * @param values     List of ETH amounts (wei) per recipient.
     */
    function disperseEther(
        address[] calldata recipients,
        uint256[] calldata values
    ) external payable nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        require(recipients.length == values.length, "Arrays length mismatch");

        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; i++) total += values[i];
        require(total <= msg.value, "Insufficient ETH sent");

        uint256 ethSent = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Zero address");
            (bool ok, ) = recipients[i].call{value: values[i]}("");
            if (ok) {
                ethSent += values[i];
            } else {
                // Skip the bad recipient — its value is refunded to the sender
                // via the unspent total below, instead of reverting everyone.
                emit DisperseSkipped(recipients[i], values[i]);
            }
        }

        uint256 unspentEth = msg.value - ethSent;
        _refundOrCredit(msg.sender, unspentEth);
    }

    // --- Admin ---

    /// @notice Step 1 of a router change: propose a new router. Takes effect
    ///         only after ROUTER_TIMELOCK via applyRouter(); cancellable
    ///         meanwhile. The router receives unlimited forceApprove allowances
    ///         per swap, so this delay makes a malicious swap observable
    ///         on-chain before it can drain anything (Sentinelle SC01).
    function proposeRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        pendingRouter = _router;
        routerChangeETA = block.timestamp + ROUTER_TIMELOCK;
        emit RouterChangeProposed(_router, routerChangeETA);
    }

    /// @notice Step 2: apply the pending router once the timelock has elapsed.
    function applyRouter() external onlyOwner {
        require(pendingRouter != address(0), "MagnetaBundler: no pending router");
        require(block.timestamp >= routerChangeETA, "MagnetaBundler: timelock active");
        emit RouterChanged(router, pendingRouter);
        router = pendingRouter;
        pendingRouter = address(0);
        routerChangeETA = 0;
    }

    /// @notice Cancel a pending router change before it is applied.
    function cancelRouterChange() external onlyOwner {
        require(pendingRouter != address(0), "MagnetaBundler: no pending router");
        emit RouterChangeCancelled(pendingRouter);
        pendingRouter = address(0);
        routerChangeETA = 0;
    }

    /// @notice Update the FeeVault address. Set to address(0) to fall back
    ///         to the legacy "fees stay in contract" mode (then use rescueETH).
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "MagnetaBundler: zero token");
        require(amount > 0, "MagnetaBundler: zero amount");
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Rescue idle native — bounded so it can never dip into funds owed
    ///         to pull-payment claimants (pendingWithdrawals).
    function rescueETH() external onlyOwner {
        uint256 rescuable = address(this).balance - totalPendingWithdrawals;
        require(rescuable > 0, "MagnetaBundler: nothing to rescue");
        (bool success, ) = msg.sender.call{value: rescuable}("");
        require(success, "Transfer failed");
    }

    /// @notice Update the per-tx fee cap. Owner-only.
    function setMaxFeePerTx(uint256 newCap) external onlyOwner {
        require(newCap > 0, "MagnetaBundler: zero cap");
        emit MaxFeePerTxUpdated(maxFeePerTx, newCap);
        maxFeePerTx = newCap;
    }

    /// @notice Grant an address the pauser role (human guardian, Defender
    ///         Relayer, or on-chain keeper). Owner-only.
    function addPauser(address account) public onlyOwner {
        require(account != address(0), "MagnetaBundler: zero pauser");
        isPauser[account] = true;
        emit PauserAdded(account);
    }

    /// @notice Revoke an address's pauser role. Owner-only.
    function removePauser(address account) external onlyOwner {
        require(account != address(0), "MagnetaBundler: zero pauser");
        isPauser[account] = false;
        emit PauserRemoved(account);
    }

    /// @notice Deprecated single-guardian setter, retained for back-compat.
    ///         Rotates the canonical {pauseGuardian} within {isPauser}.
    ///         Set to address(0) to disable the canonical guardian (only the
    ///         previous guardian is revoked; other pausers are untouched).
    function setPauseGuardian(address _guardian) external onlyOwner {
        address old = pauseGuardian;
        if (old != address(0)) {
            isPauser[old] = false;
            emit PauserRemoved(old);
        }
        pauseGuardian = _guardian;
        if (_guardian != address(0)) {
            isPauser[_guardian] = true;
            emit PauserAdded(_guardian);
        }
        emit PauseGuardianUpdated(old, _guardian);
    }

    function pause() external onlyOwnerOrPauser {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
