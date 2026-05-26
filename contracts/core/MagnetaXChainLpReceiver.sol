// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IUniswapV2Router02 {
    function WETH() external view returns (address);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/**
 * @title MagnetaXChainLpReceiver
 * @notice Destination-chain receiver that turns bridged NATIVE into a token/native
 *         V2 LP position, sending the LP tokens (plus dust) to the user. Two entry
 *         paths, sharing the same build logic:
 *
 *           1. addLiquidityNative (payable) — the LI.FI *destination-call* path:
 *              LI.FI's executor bridges + calls this with the bridged native as
 *              msg.value. Works only where LI.FI supports destination contract
 *              execution (CCTP-type chains).
 *
 *           2. fulfillSigned (keeper) — the *relayer/intent* path for the chains
 *              LI.FI can bridge to but NOT execute on (the non-CCTP chains; verified
 *              2026-05-26). The user bridges native to THIS contract via a plain
 *              LI.FI bridge and signs an EIP-712 LpIntent; a Magneta keeper, once
 *              the native lands here, calls fulfillSigned to build the LP from the
 *              contract's balance. (memory: project_xchain_lp_relayer_intent)
 *
 * @dev    Security model:
 *           - NON-CUSTODIAL. Funds only ever sit in THIS contract (briefly, between
 *             bridge-arrival and fulfilment) and leave as the user's LP — no Magneta
 *             EOA ever holds them. Each path spends only its own native (msg.value,
 *             or intent.amountNative), bounded against a tx-scoped balance baseline,
 *             so concurrent intents and donations can't be cross-spent or drained.
 *           - The keeper is a TRUSTED TRIGGER, not a custodian. fulfillSigned is
 *             onlyKeeper and only ever builds an LP to the address that SIGNED the
 *             intent (signer == intent.to), so a compromised keeper cannot redirect
 *             funds to itself — worst case it fulfils a valid intent against
 *             already-arrived funds (bounded griefing; mitigated by only fulfilling
 *             confirmed bridges + monitoring).
 *           - All slippage bounds + deadline are caller/signer-supplied (no
 *             unprotected swap, no oracle). Token amounts measured by balance delta
 *             (fee-on-transfer safe). Router + wnative immutable per chain.
 */
contract MagnetaXChainLpReceiver is Ownable2Step, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice V2-compatible router used for the swap and addLiquidityETH.
    address public immutable router;
    /// @notice Wrapped-native token of this chain (must equal router.WETH()).
    address public immutable wnative;
    /// @notice Trusted keeper allowed to call fulfillSigned (Magneta-operated).
    address public keeper;

    /// @notice EIP-712 intent a user signs on the source chain; a keeper fulfils
    ///         it here once the bridged native has arrived.
    struct LpIntent {
        address token;        // token to pair against native (on THIS chain)
        address to;           // LP + dust recipient AND the required signer
        uint256 amountNative; // native (wei) the user bridged for this intent
        uint256 minTokenOut;  // swap floor
        uint256 minTokenLp;   // addLiquidityETH token floor
        uint256 minNativeLp;  // addLiquidityETH native floor
        uint256 deadline;     // unix expiry
        uint256 nonce;        // per-user uniqueness / replay scope
    }

    bytes32 private constant LP_INTENT_TYPEHASH = keccak256(
        "LpIntent(address token,address to,uint256 amountNative,uint256 minTokenOut,uint256 minTokenLp,uint256 minNativeLp,uint256 deadline,uint256 nonce)"
    );

    /// @notice Intent digests already fulfilled (replay protection).
    mapping(bytes32 => bool) public intentFulfilled;

    event LpAdded(
        address indexed caller,
        address indexed token,
        address indexed to,
        uint256 nativeIn,
        uint256 amountToken,
        uint256 amountNative,
        uint256 liquidity
    );
    event IntentFulfilled(bytes32 indexed intentDigest, address indexed to, address indexed token, uint256 amountNative, uint256 liquidity);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    event DustRefunded(address indexed to, address indexed token, uint256 tokenDust, uint256 nativeDust);
    event Rescued(address indexed token, address indexed to, uint256 amount); // token == address(0) for native

    error ZeroValue();
    error ZeroAddress();
    error NotAContract();
    error TokenIsNative();
    error InsufficientTokenOut();
    error NativeRefundFailed();
    error RescueFailed();
    error OnlyKeeper();
    error IntentAlreadyFulfilled();
    error BadSignature();
    error InsufficientBridgedNative();
    error Expired();

    /**
     * @param _router  V2-compatible DEX router for this chain (immutable).
     * @param _wnative Wrapped-native token; checked against router.WETH().
     */
    constructor(address _router, address _wnative)
        EIP712("MagnetaXChainLpReceiver", "1")
    {
        if (_router == address(0) || _wnative == address(0)) revert ZeroAddress();
        // Pin the path token to the router's own WETH so swapExactETHForTokens
        // and addLiquidityETH operate on the same pair the router expects.
        require(IUniswapV2Router02(_router).WETH() == _wnative, "router/WETH mismatch");
        router = _router;
        wnative = _wnative;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    /// @notice Set/rotate the trusted keeper. Owner-only.
    function setKeeper(address newKeeper) external onlyOwner {
        emit KeeperUpdated(keeper, newKeeper);
        keeper = newKeeper;
    }

    // ───────────────────────── path 1: LI.FI destination call ─────────────────

    /**
     * @notice Atomically turn bridged native (msg.value) into a token/native LP
     *         position. LP tokens and all dust go to `to`. Used by the LI.FI
     *         destination-call path on chains where LI.FI supports it.
     */
    function addLiquidityNative(
        address token,
        address to,
        uint256 minTokenOut,
        uint256 minTokenLp,
        uint256 minNativeLp,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        if (msg.value == 0) revert ZeroValue();
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) revert TokenIsNative();
        if (token.code.length == 0) revert NotAContract();

        // Baseline = balance excluding this tx's native, so dust refunds only
        // return this tx's unused native and never a pre-existing donation.
        uint256 nativeBaseline = address(this).balance - msg.value;
        (amountToken, amountNative, liquidity) =
            _buildLp(token, to, msg.value, minTokenOut, minTokenLp, minNativeLp, deadline, nativeBaseline);
    }

    // ───────────────────────── path 2: relayer/intent ─────────────────────────

    /// @notice EIP-712 digest of an intent (for the frontend to sign / verify).
    function hashIntent(LpIntent calldata intent) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            LP_INTENT_TYPEHASH,
            intent.token,
            intent.to,
            intent.amountNative,
            intent.minTokenOut,
            intent.minTokenLp,
            intent.minNativeLp,
            intent.deadline,
            intent.nonce
        )));
    }

    /**
     * @notice Build the LP for a user-signed intent using native ALREADY bridged
     *         into this contract. Callable only by the keeper. The LP + dust go to
     *         `intent.to`, which MUST be the signer — so the keeper can never
     *         redirect funds.
     */
    function fulfillSigned(LpIntent calldata intent, bytes calldata signature)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 amountToken, uint256 amountNative, uint256 liquidity)
    {
        if (block.timestamp > intent.deadline) revert Expired();
        if (intent.to == address(0)) revert ZeroAddress();
        if (intent.token == address(0)) revert TokenIsNative();
        if (intent.token.code.length == 0) revert NotAContract();
        if (intent.amountNative == 0) revert ZeroValue();

        bytes32 digest = hashIntent(intent);
        if (intentFulfilled[digest]) revert IntentAlreadyFulfilled();
        // The LP recipient must have signed — binds the funds' destination to the
        // user, so a compromised keeper cannot send the LP anywhere else.
        if (ECDSA.recover(digest, signature) != intent.to) revert BadSignature();
        intentFulfilled[digest] = true;

        // The user's bridged native must have landed here.
        if (address(this).balance < intent.amountNative) revert InsufficientBridgedNative();

        // Baseline = everything EXCEPT this intent's native, so the build spends
        // and refunds only intent.amountNative — never other pending intents'
        // funds or donations.
        uint256 nativeBaseline = address(this).balance - intent.amountNative;
        (amountToken, amountNative, liquidity) = _buildLp(
            intent.token, intent.to, intent.amountNative,
            intent.minTokenOut, intent.minTokenLp, intent.minNativeLp, intent.deadline,
            nativeBaseline
        );
        emit IntentFulfilled(digest, intent.to, intent.token, intent.amountNative, liquidity);
    }

    // ───────────────────────── shared LP build ────────────────────────────────

    /**
     * @dev Swap `nativeAmount/2` → token, pair it with the remainder via
     *      addLiquidityETH, LP + dust → `to`. Spends ONLY `nativeAmount`; the
     *      native-dust refund is computed against `nativeBaseline` so funds the
     *      caller didn't bring (other intents, donations) are never touched.
     *      Token amount measured by balance delta (fee-on-transfer safe).
     */
    function _buildLp(
        address token,
        address to,
        uint256 nativeAmount,
        uint256 minTokenOut,
        uint256 minTokenLp,
        uint256 minNativeLp,
        uint256 deadline,
        uint256 nativeBaseline
    ) internal returns (uint256 amountToken, uint256 amountNative, uint256 liquidity) {
        uint256 half = nativeAmount / 2;
        uint256 nativeForLp = nativeAmount - half; // remainder (covers odd wei)

        // 1. Swap half the native into `token`; measure by balance delta.
        address[] memory path = new address[](2);
        path[0] = wnative;
        path[1] = token;

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        IUniswapV2Router02(router).swapExactETHForTokens{value: half}(
            minTokenOut, path, address(this), deadline
        );
        uint256 tokenReceived = IERC20(token).balanceOf(address(this)) - tokenBefore;
        // Re-validate the MEASURED delta against the floor (Sentinelle SC02).
        if (tokenReceived < minTokenOut) revert InsufficientTokenOut();

        // 2. Add liquidity: token + native → LP, minted directly to `to`.
        IERC20(token).forceApprove(router, tokenReceived);
        (amountToken, amountNative, liquidity) = IUniswapV2Router02(router).addLiquidityETH{value: nativeForLp}(
            token, tokenReceived, minTokenLp, minNativeLp, to, deadline
        );
        IERC20(token).forceApprove(router, 0);

        // 3. Refund dust to `to`.
        uint256 tokenDust = tokenReceived - amountToken;
        if (tokenDust > 0) IERC20(token).safeTransfer(to, tokenDust);

        // Native dust = balance above the baseline = this call's unspent native.
        uint256 nativeDust = address(this).balance - nativeBaseline;
        if (nativeDust > 0) {
            (bool ok, ) = payable(to).call{value: nativeDust}("");
            if (!ok) revert NativeRefundFailed();
        }

        emit LpAdded(msg.sender, token, to, nativeAmount, amountToken, amountNative, liquidity);
        if (tokenDust > 0 || nativeDust > 0) emit DustRefunded(to, token, tokenDust, nativeDust);
    }

    // ───────────────────────── owner rescue ─────────────────────────

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    function rescueNative(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert RescueFailed();
        emit Rescued(address(0), to, amount);
    }

    /// @notice Accept native: LI.FI dest-call msg.value, plain-bridge deliveries
    ///         for pending intents, and the router's addLiquidityETH refund.
    receive() external payable {}
}
