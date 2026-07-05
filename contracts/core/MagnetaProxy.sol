// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title MagnetaProxy
 * @dev Proxy contract for executing swaps via 0x API while collecting fees.
 */
contract MagnetaProxy is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Fee in basis points (100 = 1%)
    uint256 public feeBps = 30; // 0.3%
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    // Fee recipient
    address public feeRecipient;

    // Owner-managed whitelist of swapTarget addresses that callers may route
    // through. Closes the unrestricted-external-call class (Sentinelle audit
    // 2026-05-22, CVSS 7.8 SC06) and the donation/approval-drain attack
    // surface (CVSS 7.5 SC02) by ensuring only known-good routers can be
    // invoked. Each EVM chain's V2 router (PancakeSwap, QuickSwap, Sushi,
    // etc.) must be whitelisted post-deploy by the owner Safe before the
    // proxy can be used on that chain.
    mapping(address => bool) public allowedSwapTargets;

    // Owner-managed whitelist of spender addresses the proxy may approve
    // tokens to. In practice this is the same set as allowedSwapTargets
    // (routers approve themselves), but kept separate so e.g. PermitV2 can
    // be added later without touching the swap-target list.
    mapping(address => bool) public allowedSpenders;

    /// @notice Multi-pauser set. Any address with isPauser[addr] == true may
    ///         call {pause}. UNPAUSE remains owner-only. Defense-in-depth
    ///         kill-switch: executeSwap/executeSwapETH/executeSwapToETH move
    ///         user funds through an owner-allowlisted but otherwise
    ///         arbitrary `.call()` target; if a listed router is ever
    ///         compromised, this lets ops halt all swap execution instantly
    ///         instead of racing to de-list every affected entry one by one.
    mapping(address => bool) public isPauser;

    // Events
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event SwapTargetAllowed(address indexed target, bool allowed);
    event SpenderAllowed(address indexed spender, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount); // token == address(0) for ETH
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event PauserAdded(address indexed account);
    event PauserRemoved(address indexed account);

    modifier onlyOwnerOrPauser() {
        require(
            msg.sender == owner() || isPauser[msg.sender],
            "MagnetaProxy: not owner or pauser"
        );
        _;
    }

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Execute a swap via 0x API (or any spender/target)
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @param minAmountOut Minimum amount of output tokens expected
     * @param spender Address to approve (0x Router)
     * @param swapTarget Address to call (0x Router)
     * @param swapCallData Calldata for the swap
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address spender,
        address swapTarget,
        bytes calldata swapCallData
    ) external payable nonReentrant whenNotPaused {
        require(amountIn > 0, "Invalid amount");
        require(allowedSpenders[spender], "MagnetaProxy: spender not allowed");
        require(allowedSwapTargets[swapTarget], "MagnetaProxy: target not allowed");
        require(tokenIn != tokenOut, "Same token");

        uint256 fee = 0;
        uint256 amountToSwap = amountIn;

        // 1. Transfer tokens from user to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // 2. Calculate and deduct fee
        if (feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountToSwap = amountIn - fee;
            // Send fee to recipient
            IERC20(tokenIn).safeTransfer(feeRecipient, fee);
        }

        // 3. Approve 0x Router to spend tokens
        IERC20(tokenIn).forceApprove(spender, amountToSwap);

        // 4. Record balance before swap to verify output
        uint256 initialBalanceOut = IERC20(tokenOut).balanceOf(address(this));

        // 5. Execute Exchange Call
        (bool success, ) = swapTarget.call(swapCallData);
        require(success, "Swap failed");

        // 6. Verify output
        uint256 finalBalanceOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 amountReceived = finalBalanceOut - initialBalanceOut;
        require(amountReceived >= minAmountOut, "Insufficient output amount");

        // 7. Transfer output tokens to user
        IERC20(tokenOut).safeTransfer(msg.sender, amountReceived);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountReceived, fee);
    }

    /**
     * @dev Execute a swap with ETH as input
     */
    function executeSwapETH(
        address tokenOut,
        uint256 minAmountOut,
        address spender,
        address swapTarget,
        bytes calldata swapCallData
    ) external payable nonReentrant whenNotPaused {
        require(msg.sender != address(0), "Invalid sender");
        require(msg.value > 0, "Invalid ETH amount");
        require(allowedSpenders[spender], "MagnetaProxy: spender not allowed");
        require(allowedSwapTargets[swapTarget], "MagnetaProxy: target not allowed");

        uint256 amountIn = msg.value;
        uint256 fee = 0;
        uint256 amountToSwap = amountIn;

        // 1. Deduct fee
        if (feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountToSwap = amountIn - fee;
            // Send fee to recipient
            (bool feeSuccess, ) = feeRecipient.call{value: fee}("");
            require(feeSuccess, "Fee transfer failed");
        }

        // 2. Record balance before swap
        uint256 initialBalanceOut = IERC20(tokenOut).balanceOf(address(this));

        // 3. Execute Exchange Call (Send ETH along with call)
        (bool success, ) = swapTarget.call{value: amountToSwap}(swapCallData);
        require(success, "Swap failed");

        // 4. Verify output
        uint256 finalBalanceOut = IERC20(tokenOut).balanceOf(address(this));
        uint256 amountReceived = finalBalanceOut - initialBalanceOut;
        require(amountReceived >= minAmountOut, "Insufficient output amount");

        // 5. Transfer output tokens to user
        IERC20(tokenOut).safeTransfer(msg.sender, amountReceived);

        emit Swapped(msg.sender, address(0), tokenOut, amountIn, amountReceived, fee);
    }

    /**
     * @dev Execute a swap with ERC20 input and native (ETH/POL/etc.) output.
     *      Symmetric to executeSwapETH (which is native input, ERC20 output).
     *      Required for any swap where the router returns native to the proxy
     *      (e.g. V2's swapExactTokensForETH). Without this path, the existing
     *      executeSwap reverts on IERC20(0).balanceOf when tokenOut is native.
     *
     * @param tokenIn       ERC20 input token (USDC, WETH-wrapped, etc.)
     * @param amountIn      Amount of tokenIn to pull from msg.sender
     * @param minAmountOut  Minimum native received after the swap
     * @param spender       Address approved to pull tokenIn (router)
     * @param swapTarget    Address called with swapCallData (router)
     * @param swapCallData  Encoded call that routes tokenIn -> native and
     *                      sends the native to this proxy (recipient = self)
     */
    function executeSwapToETH(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address spender,
        address swapTarget,
        bytes calldata swapCallData
    ) external nonReentrant whenNotPaused {
        require(amountIn > 0, "Invalid amount");
        require(allowedSpenders[spender], "MagnetaProxy: spender not allowed");
        require(allowedSwapTargets[swapTarget], "MagnetaProxy: target not allowed");

        // 1. Pull input tokens from user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // 2. Deduct fee in the input token
        uint256 fee = 0;
        uint256 amountToSwap = amountIn;
        if (feeBps > 0) {
            fee = (amountIn * feeBps) / 10000;
            amountToSwap = amountIn - fee;
            IERC20(tokenIn).safeTransfer(feeRecipient, fee);
        }

        // 3. Approve router and record native balance before
        IERC20(tokenIn).forceApprove(spender, amountToSwap);
        uint256 initialNativeBalance = address(this).balance;

        // 4. Execute swap — router must send native back to this contract
        (bool success, ) = swapTarget.call(swapCallData);
        require(success, "Swap failed");

        // 5. Verify native received and forward to user
        uint256 amountReceived = address(this).balance - initialNativeBalance;
        require(amountReceived >= minAmountOut, "Insufficient output amount");

        (bool sent, ) = payable(msg.sender).call{value: amountReceived}("");
        require(sent, "Native transfer failed");

        emit Swapped(msg.sender, tokenIn, address(0), amountIn, amountReceived, fee);
    }

    /**
     * @dev Admin functions
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid recipient");
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, "Fee too high");
        emit FeeBpsUpdated(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    /**
     * @dev Whitelist (or de-whitelist) a swapTarget address. Routers must be
     *      enabled here before users can route swaps through them. Owner-only.
     *      Setting `allowed=false` disables an existing entry (e.g. on
     *      vulnerable-router incident).
     */
    function setAllowedSwapTarget(address target, bool allowed) external onlyOwner {
        require(target != address(0), "MagnetaProxy: zero target");
        allowedSwapTargets[target] = allowed;
        emit SwapTargetAllowed(target, allowed);
    }

    /**
     * @dev Whitelist (or de-whitelist) a spender address. Typically the same
     *      address as the swapTarget (the router approves itself), but kept
     *      separate so Permit2 / aggregator helpers can be added without
     *      relisting routers.
     */
    function setAllowedSpender(address spender, bool allowed) external onlyOwner {
        require(spender != address(0), "MagnetaProxy: zero spender");
        allowedSpenders[spender] = allowed;
        emit SpenderAllowed(spender, allowed);
    }

    /**
     * @dev Convenience: whitelist many targets/spenders in one transaction.
     *      Used by the post-deploy configuration script to populate the
     *      per-chain router set in a single Safe batch.
     */
    function setAllowedSwapTargets(address[] calldata targets, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < targets.length; ++i) {
            require(targets[i] != address(0), "MagnetaProxy: zero target");
            allowedSwapTargets[targets[i]] = allowed;
            emit SwapTargetAllowed(targets[i], allowed);
        }
    }

    function setAllowedSpenders(address[] calldata spenders, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < spenders.length; ++i) {
            require(spenders[i] != address(0), "MagnetaProxy: zero spender");
            allowedSpenders[spenders[i]] = allowed;
            emit SpenderAllowed(spenders[i], allowed);
        }
    }

    /**
     * @dev Rescue ERC20 tokens accidentally sent to the contract or stuck
     *      after a failed swap. Owner-only. Limited to amounts ≤ the
     *      contract's idle balance so rescue can't be used to drain an
     *      in-flight swap (functions hold tokens transiently inside
     *      nonReentrant which would block this).
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(0), "MagnetaProxy: zero token");
        require(to != address(0), "MagnetaProxy: zero recipient");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /**
     * @dev Rescue native ETH (e.g. WETH unwrapping refunds, donation grief).
     *      Owner-only. nonReentrant for defence in depth.
     */
    function rescueETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "MagnetaProxy: zero recipient");
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "MagnetaProxy: ETH rescue failed");
        emit Rescued(address(0), to, amount);
    }

    // Allow receiving ETH (required for unwrapping WETH or refunds)
    receive() external payable {}

    // ─── Emergency pause ──────────────────────────────────────────────────

    /**
     * @dev Defense-in-depth kill-switch for compromised-router scenarios.
     *      Pauses executeSwap/executeSwapETH/executeSwapToETH so no new
     *      funds can be routed through a listed swapTarget while the owner
     *      Safe investigates and de-lists the affected entry. Owner config
     *      setters (fee/whitelist) and the rescue* recovery paths remain
     *      callable while paused so ops can still remediate and recover
     *      stuck funds during an incident.
     */
    function pause() external onlyOwnerOrPauser {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Grant an address the pauser role. Owner-only.
    function addPauser(address account) public onlyOwner {
        require(account != address(0), "MagnetaProxy: zero pauser");
        isPauser[account] = true;
        emit PauserAdded(account);
    }

    /// @notice Revoke an address's pauser role. Owner-only.
    function removePauser(address account) external onlyOwner {
        require(account != address(0), "MagnetaProxy: zero pauser");
        isPauser[account] = false;
        emit PauserRemoved(account);
    }
}
