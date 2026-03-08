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

    // Bridge fee in basis points (100 = 1%)
    uint256 public constant BRIDGE_FEE_BPS = 10; // 0.1%
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    // Fee recipient
    address public feeRecipient;

    // Local endpoint ID (stored at deployment)
    uint32 public localEid;

    // Mapping: endpointId => token => isSupported
    mapping(uint32 => mapping(address => bool)) public supportedTokens;

    // Mapping: endpointId => token => bridgeable
    mapping(uint32 => mapping(address => bool)) public bridgeableTokens;

    // Mapping: guid => bridge transaction info (for tracking)
    mapping(bytes32 => BridgeTransaction) public bridgeTransactions;

    // Mapping: endpointId => token => available balance for bridging
    mapping(uint32 => mapping(address => uint256)) public bridgeLiquidity;

    // Paused state
    bool public paused;

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


    modifier whenNotPaused() {
        require(!paused, "MagnetaBridgeOApp: paused");
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

        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate fee
        uint256 fee = (amount * BRIDGE_FEE_BPS) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Transfer fee to fee recipient
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
        }

        // Prepare message payload
        bytes memory payload = abi.encode(token, to, amountAfterFee);

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
        (address token, address to, uint256 amount) = abi.decode(_payload, (address, address, uint256));

        require(supportedTokens[_origin.srcEid][token], "MagnetaBridgeOApp: token not supported from source");
        require(amount > 0, "MagnetaBridgeOApp: invalid amount");
        
        // Check if bridge has enough liquidity for this token on the local endpoint
        // localEid is the endpoint ID of the current chain (where this contract is deployed)
        require(
            bridgeLiquidity[localEid][token] >= amount,
            "MagnetaBridgeOApp: insufficient bridge liquidity"
        );

        // Transfer tokens to recipient
        IERC20(token).safeTransfer(to, amount);
        
        // Update liquidity tracking
        bridgeLiquidity[localEid][token] -= amount;

        // Mark transaction as completed
        bridgeTransactions[_guid].completed = true;

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
    ) external {
        require(msg.sender == owner(), "MagnetaBridgeOApp: not owner");
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
    ) external {
        require(msg.sender == owner(), "MagnetaBridgeOApp: not owner");
        require(token != address(0), "MagnetaBridgeOApp: invalid token");
        bridgeableTokens[endpointId][token] = bridgeable;
        emit BridgeableTokenSet(endpointId, token, bridgeable);
    }


    /**
     * @dev Update fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external {
        require(msg.sender == owner(), "MagnetaBridgeOApp: not owner");
        require(_feeRecipient != address(0), "MagnetaBridgeOApp: invalid fee recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external {
        require(msg.sender == owner(), "MagnetaBridgeOApp: not owner");
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external {
        require(msg.sender == owner(), "MagnetaBridgeOApp: not owner");
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @dev Emergency withdraw tokens (only owner)
     * @param token Address of the token to withdraw
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external {
        require(msg.sender == owner(), "MagnetaBridgeOApp: not owner");
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
    ) external {
        require(msg.sender == owner(), "MagnetaBridgeOApp: not owner");
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
    ) external {
        require(msg.sender == owner(), "MagnetaBridgeOApp: not owner");
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

