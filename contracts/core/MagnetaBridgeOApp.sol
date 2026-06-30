// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppCore.sol";

// Note: OAppCore uses OpenZeppelin v4 Ownable which doesn't require constructor parameter
// Our project uses OpenZeppelin v5, but LayerZero packages include their own OpenZeppelin v4


/**
 * @title MagnetaBridgeOApp
 * @dev Cross-chain bridge contract using LayerZero OApp v2
 * This is the full implementation with LayerZero OApp integration
 */
contract MagnetaBridgeOApp is OApp, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // Fee cap (BPS, 10_000 = 100%) — owner cannot exceed
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    // LayerZero Endpoint ID for Ethereum mainnet — used to auto-bump the fee
    // on any route that touches Ethereum (source or destination) where LZ
    // native fees are dramatically higher than pure L2↔L2 routes.
    uint32 public constant ETHEREUM_EID = 30101;

    // Default protocol fee for L2↔L2 routes (0.1%)
    uint16 public defaultFeeBps = 10;

    // Higher protocol fee for any route touching Ethereum (0.2%)
    uint16 public ethereumFeeBps = 20;

    // Per-destination override: 0 means "use default/ethereum logic"
    mapping(uint32 => uint16) public dstFeeBpsOverride;

    // Fee recipient
    address public feeRecipient;

    // Local endpoint ID (stored at deployment)
    uint32 public localEid;

    // Mapping: endpointId => token => isSupported
    mapping(uint32 => mapping(address => bool)) public supportedTokens;

    // Mapping: endpointId => token => bridgeable
    mapping(uint32 => mapping(address => bool)) public bridgeableTokens;

    // Mapping: guid => bridge transaction info (for tracking outgoing txs)
    mapping(bytes32 => BridgeTransaction) public bridgeTransactions;

    // Mapping: guid => already-processed flag for INCOMING messages.
    // bridgeTransactions[].completed only gets set for outgoing txs; for
    // incoming messages we need a dedicated replay guard or every replayed
    // _lzReceive would pass the completed==false check. Closes the CrossCurve
    // 2026 ($3M) replay-semantic divergence attack class.
    mapping(bytes32 => bool) public processedIncomingGuids;

    // Mapping: endpointId => token => available balance for bridging
    mapping(uint32 => mapping(address => uint256)) public bridgeLiquidity;

    // F22: canonical cross-chain token mapping. remoteToken[eid][localToken] =
    // that token's address on chain `eid`. Set per route (both directions) by the
    // owner; gates both the outgoing translation and the incoming acceptance.
    mapping(uint32 => mapping(address => address)) public remoteToken;

    // Paused state
    bool public paused;

    // Guardian role: can pause but not unpause. Lets ops/SOC kill the bridge
    // in seconds during an incident without holding owner keys.
    // Canonical human guardian (back-compat view); kept in sync with {isPauser}
    // by {setPauseGuardian}. Prefer {addPauser}/{removePauser}.
    address public pauseGuardian;

    // Multi-pauser set: human EOA + Defender Relayer + future on-chain keeper.
    // Any address with isPauser[addr] == true may call {pause}. UNPAUSE stays
    // owner-only.
    mapping(address => bool) public isPauser;

    // Per-tx amount cap: maxAmountPerTx[token]. 0 = no cap.
    mapping(address => uint256) public maxAmountPerTx;

    // Rolling 24h volume cap per token. 0 = no cap.
    mapping(address => uint256) public dailyLimit;

    // Tracking for the rolling window: dailyWindowStart resets after 24h,
    // dailyVolume accumulates within the window.
    mapping(address => uint256) public dailyWindowStart;
    mapping(address => uint256) public dailyVolume;

    // Cumulative volume tracking per route (src is always localEid)
    // routeVolume[dstEid][token] = lifetime volume sent to dstEid
    mapping(uint32 => mapping(address => uint256)) public routeVolume;

    // Bridge transaction structure
    struct BridgeTransaction {
        address token;
        address from;
        address to;
        uint256 amount;
        uint32 dstEid;
        uint256 timestamp;
        bool completed;
    }

    // Events
    event TokenBridged(
        address indexed token,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint32 dstEid,
        bytes32 guid
    );

    event TokenReceived(
        address indexed token,
        address indexed to,
        uint256 amount,
        uint32 srcEid,
        bytes32 guid
    );

    event TokenSupported(uint32 endpointId, address token, bool supported);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event Paused(address account);
    event Unpaused(address account);
    event BridgeLiquidityAdded(uint32 endpointId, address indexed token, uint256 amount);
    event BridgeLiquidityRemoved(uint32 endpointId, address indexed token, uint256 amount);
    event BridgeableTokenSet(uint32 endpointId, address indexed token, bool bridgeable);
    event RemoteTokenSet(uint32 indexed endpointId, address indexed localToken, address remote);
    event DefaultFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event EthereumFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    event DstFeeBpsOverrideUpdated(uint32 indexed dstEid, uint16 oldBps, uint16 newBps);
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event PauserAdded(address indexed account);
    event PauserRemoved(address indexed account);
    event MaxAmountPerTxUpdated(address indexed token, uint256 oldCap, uint256 newCap);
    event DailyLimitUpdated(address indexed token, uint256 oldLimit, uint256 newLimit);
    event DailyWindowReset(address indexed token, uint256 newWindowStart);
    event RouteVolumeUpdated(uint32 indexed dstEid, address indexed token, uint256 added, uint256 cumulative);


    modifier whenNotPaused() {
        require(!paused, "MagnetaBridgeOApp: paused");
        _;
    }

    modifier onlyOwnerOrPauser() {
        require(
            msg.sender == owner() || isPauser[msg.sender],
            "MagnetaBridgeOApp: not owner or pauser"
        );
        _;
    }

    /**
     * @dev Constructor
     * @param _endpoint LayerZero endpoint address
     * @param _delegate Delegate address (for OAppCore, typically the owner)
     * @param _feeRecipient Fee recipient address
     */
    constructor(
        address _endpoint,
        address _delegate,
        address _feeRecipient,
        uint32 _localEid
    ) OApp(_endpoint, _delegate) {
        require(_feeRecipient != address(0), "MagnetaBridgeOApp: invalid fee recipient");
        require(_endpoint != address(0), "MagnetaBridgeOApp: invalid endpoint");
        require(_delegate != address(0), "MagnetaBridgeOApp: invalid delegate");
        require(_localEid != 0, "MagnetaBridgeOApp: invalid local endpoint ID");
        feeRecipient = _feeRecipient;
        localEid = _localEid;
    }

    /**
     * @dev Bridge tokens to another chain
     * @param token Address of the token to bridge
     * @param amount Amount of tokens to bridge
     * @param dstEid Destination endpoint ID (LayerZero endpoint ID)
     * @param to Recipient address on destination chain
     * @param options Message execution options
     * @param payInLzToken Whether to pay in LZ token
     */
    function bridgeTokens(
        address token,
        uint256 amount,
        uint32 dstEid,
        address to,
        bytes calldata options,
        bool payInLzToken
    ) external payable nonReentrant whenNotPaused {

        require(token != address(0), "MagnetaBridgeOApp: invalid token");
        require(amount > 0, "MagnetaBridgeOApp: invalid amount");
        require(to != address(0), "MagnetaBridgeOApp: invalid recipient");
        require(supportedTokens[dstEid][token], "MagnetaBridgeOApp: token not supported on destination");
        require(bridgeableTokens[dstEid][token], "MagnetaBridgeOApp: token not bridgeable");

        // Per-tx cap (0 = no cap)
        uint256 txCap = maxAmountPerTx[token];
        require(txCap == 0 || amount <= txCap, "MagnetaBridgeOApp: amount exceeds per-tx cap");

        // Rolling 24h volume cap (0 = no cap). Reset window if expired.
        uint256 dayCap = dailyLimit[token];
        if (dayCap > 0) {
            if (block.timestamp >= dailyWindowStart[token] + 1 days) {
                dailyWindowStart[token] = block.timestamp;
                dailyVolume[token] = 0;
                emit DailyWindowReset(token, block.timestamp);
            }
            require(
                dailyVolume[token] + amount <= dayCap,
                "MagnetaBridgeOApp: amount exceeds 24h cap"
            );
            dailyVolume[token] += amount;
        }

        // Transfer tokens from user, measuring the ACTUAL received amount via a
        // balance delta. Fee-on-transfer / deflationary tokens credit less than
        // the nominal `amount`; computing fee and the bridged payload from the
        // nominal value would let the bridge release more than it received and
        // bleed liquidity. Snapshot balance before/after and use the delta as
        // the authoritative received amount for everything downstream.
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        require(received > 0, "MagnetaBridgeOApp: nothing received");

        // Calculate fee — per-route override takes precedence, otherwise
        // routes touching Ethereum pay the ethereumFeeBps, all others pay
        // defaultFeeBps. Fee is taken from the actually-received amount.
        uint16 feeBps = dstFeeBpsOverride[dstEid];
        if (feeBps == 0) {
            feeBps = (dstEid == ETHEREUM_EID || localEid == ETHEREUM_EID)
                ? ethereumFeeBps
                : defaultFeeBps;
        }
        uint256 fee = (received * feeBps) / 10000;
        uint256 amountAfterFee = received - fee;

        // Transfer fee to fee recipient
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
        }

        // F22: translate the local token to its CANONICAL address on the
        // destination chain. Encoding the source address verbatim would make the
        // destination release the wrong asset (or lock funds) because the same
        // token has a different address per chain. Require an owner-configured
        // route mapping so an unmapped token can never be bridged.
        address dstToken = remoteToken[dstEid][token];
        require(dstToken != address(0), "MagnetaBridgeOApp: no canonical token for route");

        // Prepare message payload (carries the DESTINATION-chain token address)
        bytes memory payload = abi.encode(dstToken, to, amountAfterFee);

        // Estimate fee and send message via LayerZero
        MessagingFee memory fee_ = _quote(dstEid, payload, options, payInLzToken);
        
        require(msg.value >= fee_.nativeFee, "MagnetaBridgeOApp: insufficient native fee");

        // Send message via LayerZero
        MessagingReceipt memory receipt = _lzSend(
            dstEid,
            payload,
            options,
            MessagingFee(msg.value, 0),
            payInLzToken ? msg.sender : payable(msg.sender)
        );
        
        bytes32 guid = receipt.guid;

        // Store bridge transaction info
        bridgeTransactions[guid] = BridgeTransaction({
            token: token,
            from: msg.sender,
            to: to,
            amount: amountAfterFee,
            dstEid: dstEid,
            timestamp: block.timestamp,
            completed: false
        });

        // Track cumulative volume per route for monitoring/dashboards
        routeVolume[dstEid][token] += amountAfterFee;
        emit RouteVolumeUpdated(dstEid, token, amountAfterFee, routeVolume[dstEid][token]);

        emit TokenBridged(token, msg.sender, to, amountAfterFee, dstEid, guid);
    }

    /**
     * @dev Receive bridged tokens (called by LayerZero)
     * @param _origin Origin information
     * @param _guid Message GUID
     * @param _payload Message payload
     * @param _executor Executor address
     * @param _extraData Extra data
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload,
        address _executor,
        bytes calldata _extraData
    ) internal override {
        // Inbound kill-switch. bridgeTokens() is guarded by whenNotPaused, but
        // _lzReceive is an internal LayerZero override and cannot wear the
        // modifier — so without this inline check a pause could not stop an
        // inbound drain from a forged/compromised peer. Mirror the same paused
        // flag here so {pause} freezes BOTH directions of the bridge.
        require(!paused, "MagnetaBridgeOApp: paused");

        // CRITICAL: validate the message comes from one of OUR remote bridge
        // contracts. Without this, any contract on any source chain can call
        // the LayerZero endpoint with a forged payload and drain our liquidity
        // — exact Kelp DAO 2026-04-19 $292M attack pattern. _getPeerOrRevert
        // reads peers[_origin.srcEid] (owner-managed via setPeer); if the
        // source eid has no peer configured it reverts with NoPeer(_eid),
        // which is also the correct behaviour (refuse messages from
        // un-peered chains).
        require(
            _getPeerOrRevert(_origin.srcEid) == _origin.sender,
            "MagnetaBridgeOApp: untrusted sender"
        );

        // Replay guard for INCOMING messages. The legacy
        // bridgeTransactions[_guid].completed check below is preserved as a
        // defence-in-depth signal (it would only ever be true for an outgoing
        // guid that somehow round-tripped, an anomaly worth reverting on),
        // but the authoritative replay protection is processedIncomingGuids.
        require(!processedIncomingGuids[_guid], "MagnetaBridgeOApp: incoming guid replayed");
        processedIncomingGuids[_guid] = true;

        (address token, address to, uint256 amount) = abi.decode(_payload, (address, address, uint256));

        require(!bridgeTransactions[_guid].completed, "MagnetaBridgeOApp: guid already processed");
        // F22: `token` is this chain's LOCAL token address (translated on send).
        // Only accept it if the owner configured a canonical mapping back to the
        // source — rejects a forged/divergent token instead of releasing a wrong
        // asset. The bridgeLiquidity check below is the second gate.
        require(remoteToken[_origin.srcEid][token] != address(0), "MagnetaBridgeOApp: unmapped token from source");
        require(amount > 0, "MagnetaBridgeOApp: invalid amount");
        require(to != address(0), "MagnetaBridgeOApp: zero recipient");

        require(
            bridgeLiquidity[localEid][token] >= amount,
            "MagnetaBridgeOApp: insufficient bridge liquidity"
        );

        // Effects before interactions (CEI)
        bridgeLiquidity[localEid][token] -= amount;
        bridgeTransactions[_guid].completed = true;

        IERC20(token).safeTransfer(to, amount);

        emit TokenReceived(token, to, amount, _origin.srcEid, _guid);
    }

    /**
     * @dev Set supported token for an endpoint
     * @param endpointId Endpoint ID
     * @param token Token address
     * @param supported Whether token is supported
     */
    function setSupportedToken(
        uint32 endpointId,
        address token,
        bool supported
    ) external onlyOwner {
        require(token != address(0), "MagnetaBridgeOApp: invalid token");
        supportedTokens[endpointId][token] = supported;
        emit TokenSupported(endpointId, token, supported);
    }

    /**
     * @dev Set bridgeable token for an endpoint
     * @param endpointId Endpoint ID
     * @param token Token address
     * @param bridgeable Whether token is bridgeable
     */
    function setBridgeableToken(
        uint32 endpointId,
        address token,
        bool bridgeable
    ) external onlyOwner {
        require(token != address(0), "MagnetaBridgeOApp: invalid token");
        bridgeableTokens[endpointId][token] = bridgeable;
        emit BridgeableTokenSet(endpointId, token, bridgeable);
    }

    /**
     * @dev F22: set the canonical address of `localToken` on chain `endpointId`.
     *      Configure BOTH directions per route: on the source set
     *      remoteToken[dstEid][srcToken]=dstToken (outgoing translation), and on
     *      the destination set remoteToken[srcEid][dstToken]=srcToken (incoming
     *      acceptance). Pass remote=address(0) to unmap a route.
     */
    function setRemoteToken(
        uint32 endpointId,
        address localToken,
        address remote
    ) external onlyOwner {
        require(localToken != address(0), "MagnetaBridgeOApp: invalid token");
        remoteToken[endpointId][localToken] = remote;
        emit RemoteTokenSet(endpointId, localToken, remote);
    }


    /**
     * @dev Update fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "MagnetaBridgeOApp: invalid fee recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }

    /**
     * @dev Update the default fee (applies to L2↔L2 routes without override)
     * @param _bps New fee in basis points (capped at MAX_FEE_BPS)
     */
    function setDefaultFeeBps(uint16 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "MagnetaBridgeOApp: fee exceeds cap");
        uint16 old = defaultFeeBps;
        defaultFeeBps = _bps;
        emit DefaultFeeBpsUpdated(old, _bps);
    }

    /**
     * @dev Update the Ethereum-route fee (applies when srcEid or dstEid is ETHEREUM_EID)
     * @param _bps New fee in basis points (capped at MAX_FEE_BPS)
     */
    function setEthereumFeeBps(uint16 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "MagnetaBridgeOApp: fee exceeds cap");
        uint16 old = ethereumFeeBps;
        ethereumFeeBps = _bps;
        emit EthereumFeeBpsUpdated(old, _bps);
    }

    /**
     * @dev Override the fee for a specific destination endpoint.
     *      Pass 0 to clear the override and fall back to default/ethereum logic.
     * @param dstEid Destination endpoint ID
     * @param _bps Fee in basis points (capped at MAX_FEE_BPS; 0 clears override)
     */
    function setDstFeeBpsOverride(uint32 dstEid, uint16 _bps) external onlyOwner {
        require(_bps <= MAX_FEE_BPS, "MagnetaBridgeOApp: fee exceeds cap");
        uint16 old = dstFeeBpsOverride[dstEid];
        dstFeeBpsOverride[dstEid] = _bps;
        emit DstFeeBpsOverrideUpdated(dstEid, old, _bps);
    }

    /**
     * @dev Pause the contract. Owner OR guardian — guardian exists so ops/SOC
     *      can react in seconds during an incident without holding owner keys.
     */
    function pause() external onlyOwnerOrPauser {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @dev Unpause the contract. Owner only — a pauser can stop the bleeding,
     *      but resuming the bridge requires a deliberate owner action.
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @dev Grant an address the pauser role (human guardian, Defender Relayer,
     *      or on-chain keeper). Owner-only.
     */
    function addPauser(address account) public onlyOwner {
        require(account != address(0), "MagnetaBridgeOApp: zero pauser");
        isPauser[account] = true;
        emit PauserAdded(account);
    }

    /**
     * @dev Revoke an address's pauser role. Owner-only. The owner always
     *      retains pause+unpause regardless of the pauser set.
     */
    function removePauser(address account) external onlyOwner {
        require(account != address(0), "MagnetaBridgeOApp: zero pauser");
        isPauser[account] = false;
        emit PauserRemoved(account);
    }

    /**
     * @dev Deprecated single-guardian setter, retained for deploy-script /
     *      Safe-batch back-compat. Rotates the canonical {pauseGuardian},
     *      revoking the old one and granting the new one in {isPauser}.
     *      address(0) is rejected to prevent accidental bricking of the
     *      emergency response flow. Prefer {addPauser}/{removePauser}.
     */
    function setPauseGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "MagnetaBridgeOApp: zero guardian");
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

    /**
     * @dev Set the per-tx amount cap for a token (0 = no cap).
     */
    function setMaxAmountPerTx(address token, uint256 cap) external onlyOwner {
        require(token != address(0), "MagnetaBridgeOApp: invalid token");
        uint256 old = maxAmountPerTx[token];
        maxAmountPerTx[token] = cap;
        emit MaxAmountPerTxUpdated(token, old, cap);
    }

    /**
     * @dev Set the rolling 24h volume cap for a token (0 = no cap).
     *      The window is per-token and resets lazily on the next bridge call.
     */
    function setDailyLimit(address token, uint256 limit) external onlyOwner {
        require(token != address(0), "MagnetaBridgeOApp: invalid token");
        uint256 old = dailyLimit[token];
        dailyLimit[token] = limit;
        emit DailyLimitUpdated(token, old, limit);
    }

    /**
     * @dev Emergency withdraw tokens (only owner)
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @dev Estimate bridge fee
     * @param dstEid Destination endpoint ID
     * @param options Message execution options
     * @param payInLzToken Whether to pay in LZ token
     */
    function estimateBridgeFee(
        uint32 dstEid,
        bytes calldata options,
        bool payInLzToken
    ) external view returns (uint256 nativeFee, uint256 lzTokenFee) {
        bytes memory payload = abi.encode(address(0), address(0), 0);
        MessagingFee memory fee = _quote(dstEid, payload, options, payInLzToken);
        return (fee.nativeFee, fee.lzTokenFee);
    }

    /**
     * @dev Get bridge transaction info
     * @param guid Transaction GUID
     */
    function getBridgeTransaction(bytes32 guid) external view returns (BridgeTransaction memory) {
        return bridgeTransactions[guid];
    }

    /**
     * @dev Add liquidity to bridge for a specific token and endpoint
     * @param endpointId Endpoint ID (chain where tokens will be distributed)
     * @param token Token address
     * @param amount Amount of tokens to add as liquidity
     * 
     * IMPORTANT: This function must be called on EACH chain where you want to receive bridged tokens.
     * For example:
     * - To receive USDC bridged from Base to Arbitrum, call this on Arbitrum
     * - To receive USDC bridged from Arbitrum to Base, call this on Base
     */
    function addBridgeLiquidity(
        uint32 endpointId,
        address token,
        uint256 amount
    ) external onlyOwner {
        require(token != address(0), "MagnetaBridgeOApp: invalid token");
        require(amount > 0, "MagnetaBridgeOApp: invalid amount");
        require(supportedTokens[endpointId][token], "MagnetaBridgeOApp: token not supported");

        // Transfer tokens from owner to bridge contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update liquidity tracking
        bridgeLiquidity[endpointId][token] += amount;

        emit BridgeLiquidityAdded(endpointId, token, amount);
    }

    /**
     * @dev Remove liquidity from bridge (only owner, for rebalancing)
     * @param endpointId Endpoint ID
     * @param token Token address
     * @param amount Amount of tokens to remove
     */
    function removeBridgeLiquidity(
        uint32 endpointId,
        address token,
        uint256 amount
    ) external onlyOwner {
        require(token != address(0), "MagnetaBridgeOApp: invalid token");
        require(amount > 0, "MagnetaBridgeOApp: invalid amount");
        require(
            bridgeLiquidity[endpointId][token] >= amount,
            "MagnetaBridgeOApp: insufficient liquidity"
        );

        // Update liquidity tracking
        bridgeLiquidity[endpointId][token] -= amount;

        // Transfer tokens back to owner
        IERC20(token).safeTransfer(owner(), amount);

        emit BridgeLiquidityRemoved(endpointId, token, amount);
    }

    /**
     * @dev Get available bridge liquidity for a token on an endpoint
     * @param endpointId Endpoint ID
     * @param token Token address
     * @return Available liquidity amount
     */
    function getBridgeLiquidity(
        uint32 endpointId,
        address token
    ) external view returns (uint256) {
        return bridgeLiquidity[endpointId][token];
    }

    /**
     * @dev Get contract balance for a token (total tokens held by bridge)
     * @param token Token address
     * @return Contract balance
     */
    function getContractBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}

