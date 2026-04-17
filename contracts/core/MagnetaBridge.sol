// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MagnetaBridge
 * @dev Cross-chain bridge contract (simplified version)
 * This is a placeholder that will be enhanced with LayerZero OApp integration
 * For now, it provides the basic structure and will be updated once LayerZero is properly configured
 */
contract MagnetaBridge is Ownable2Step {
    using SafeERC20 for IERC20;

    // Bridge fee in basis points (100 = 1%)
    uint256 public constant BRIDGE_FEE_BPS = 10; // 0.1%
    uint256 public constant MAX_FEE_BPS = 1000; // 10%

    // Fee recipient
    address public feeRecipient;

    // Mapping: chainId => token => isSupported
    mapping(uint32 => mapping(address => bool)) public supportedTokens;

    // Mapping: chainId => token => bridgeable
    mapping(uint32 => mapping(address => bool)) public bridgeableTokens;

    // Paused state
    bool public paused;

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
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    address public pauseGuardian;

    modifier whenNotPaused() {
        require(!paused, "MagnetaBridge: paused");
        _;
    }

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == pauseGuardian,
            "MagnetaBridge: not owner or guardian"
        );
        _;
    }

    /**
     * @dev Constructor
     * @param _owner Owner address
     * @param _feeRecipient Fee recipient address
     */
    constructor(address _owner, address _feeRecipient) {
        require(_feeRecipient != address(0), "MagnetaBridge: invalid fee recipient");
        require(_owner != address(0), "MagnetaBridge: invalid owner");
        _transferOwnership(_owner);
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Bridge tokens to another chain
     * @param token Address of the token to bridge
     * @param amount Amount of tokens to bridge
     * @param dstEid Destination endpoint ID (LayerZero endpoint ID)
     * @param to Recipient address on destination chain
     * @param options Message execution options (for LayerZero)
     * @param payInLzToken Whether to pay in LZ token
     * 
     * Note: This is a placeholder function. LayerZero OApp integration will be added.
     * For now, tokens are held in this contract until LayerZero is properly integrated.
     */
    function bridgeTokens(
        address token,
        uint256 amount,
        uint32 dstEid,
        address to,
        bytes calldata options,
        bool payInLzToken
    ) external payable whenNotPaused {
        require(token != address(0), "MagnetaBridge: invalid token");
        require(amount > 0, "MagnetaBridge: invalid amount");
        require(to != address(0), "MagnetaBridge: invalid recipient");
        require(supportedTokens[dstEid][token], "MagnetaBridge: token not supported on destination");
        require(bridgeableTokens[dstEid][token], "MagnetaBridge: token not bridgeable");

        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate fee
        uint256 fee = (amount * BRIDGE_FEE_BPS) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Transfer fee to fee recipient
        if (fee > 0) {
            IERC20(token).safeTransfer(feeRecipient, fee);
        }

        // TODO: Integrate LayerZero OApp _lzSend here
        // For now, tokens are held in contract
        // Once LayerZero is properly configured, this will send cross-chain messages

        emit TokenBridged(token, msg.sender, to, amountAfterFee, dstEid, bytes32(0));
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
        require(token != address(0), "MagnetaBridge: invalid token");
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
        require(token != address(0), "MagnetaBridge: invalid token");
        bridgeableTokens[endpointId][token] = bridgeable;
    }

    /**
     * @dev Update fee recipient
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "MagnetaBridge: invalid fee recipient");
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyOwnerOrGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setPauseGuardian(address _guardian) external onlyOwner {
        address old = pauseGuardian;
        pauseGuardian = _guardian;
        emit PauseGuardianUpdated(old, _guardian);
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
     * 
     * Note: This is a placeholder. Will be implemented with LayerZero _quote function.
     */
    function estimateBridgeFee(
        uint32 dstEid,
        bytes calldata options,
        bool payInLzToken
    ) external pure returns (uint256 nativeFee, uint256 lzTokenFee) {
        // TODO: Implement with LayerZero _quote
        // For now, return placeholder values
        return (0, 0);
    }
}
