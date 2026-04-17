// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IMagnetaGateway.sol";
import "../interfaces/IModule.sol";

/// @title MagnetaGateway
/// @notice Per-chain facade for the chain-service SDK. Dispatches local calls
///         from the SDK and incoming LayerZero messages from sibling gateways
///         to the registered module for the given OpType.
/// @dev    One instance deployed per chain. Uses OApp (LZ v2) as message bus.
contract MagnetaGateway is IMagnetaGateway, OApp, Ownable2Step, ReentrancyGuard, Pausable {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Registry OpType -> module implementation.
    mapping(OpType => address) private _modules;

    /// @notice USDC vault that collects the Magneta markup on this chain.
    address private _feeVault;

    /// @notice Guards against replayed LZ messages at the gateway level
    ///         (OApp already deduplicates, but we track processed GUIDs so a
    ///         module callback never re-enters the dispatcher for a given msg).
    mapping(bytes32 => bool) public processedGuid;

    /// @notice LayerZero EID ↔ EVM chain ID mappings (covers all 30 chains).
    mapping(uint32 => uint256) private _eidToChainId;
    mapping(uint256 => uint32) private _chainIdToEid;

    /// @notice USDC token for cross-chain fee collection on source chain.
    IERC20 public usdc;

    /// @notice Flat fee per cross-chain command op (USDC, 6 decimals). Default: $1.
    uint256 public crossChainCommandFee = 1_000_000;

    /// @notice Basis-point fee for value-carrying cross-chain ops. Default: 15 (0.15%).
    uint16 public crossChainValueFeeBps = 15;

    error ModuleNotSet(OpType op);
    error ZeroAddress();
    error ArrayLengthMismatch();
    error InsufficientLzFee();
    error FanOutEmpty();

    address public pauseGuardian;
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event CrossChainOpSent(uint32 indexed dstEid, OpType indexed op, address indexed caller, bytes32 guid);
    event CrossChainFanOut(OpType indexed op, address indexed caller, uint256 chainCount);
    event EidMappingSet(uint32 eid, uint256 chainId);
    event CrossChainFeesUpdated(uint256 commandFee, uint16 valueFeeBps);

    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == pauseGuardian,
            "MagnetaGateway: not owner or guardian"
        );
        _;
    }

    /// @param _endpoint   LayerZero endpoint for this chain
    /// @param _delegate   Delegate (OApp owner on LZ side, usually the deployer)
    /// @param _feeVaultIn USDC vault that collects Magneta markup on this chain
    constructor(address _endpoint, address _delegate, address _feeVaultIn)
        OApp(_endpoint, _delegate)
    {
        if (_feeVaultIn == address(0)) revert ZeroAddress();
        _feeVault = _feeVaultIn;
        _transferOwnership(_delegate);
    }

    // ───────────────────────────── external API ─────────────────────────────

    /// @inheritdoc IMagnetaGateway
    function executeOperation(OpType op, bytes calldata params)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        returns (bytes memory result)
    {
        address module = _modules[op];
        if (module == address(0)) revert ModuleNotSet(op);

        IModule.Context memory ctx = IModule.Context({
            caller: msg.sender,
            originChainId: block.chainid,
            feeVault: _feeVault
        });

        result = IModule(module).execute{value: msg.value}(ctx, params);

        emit OperationExecuted(op, module, msg.sender, block.chainid, keccak256(result));
    }

    // ───────────────────────── cross-chain send ─────────────────────────

    /// @notice Send a cross-chain operation to a sibling gateway via LayerZero.
    ///         Collects the Magneta fee in USDC on the source chain; the target
    ///         module skips fee collection (originChainId != block.chainid).
    /// @param dstEid        LayerZero endpoint ID of the target chain
    /// @param op            Operation type to execute on the target chain
    /// @param moduleParams  ABI-encoded params for the target module
    /// @param lzOptions     LayerZero executor options (gas, value)
    /// @return guid         Unique message identifier for tracking
    function sendCrossChainOp(
        uint32 dstEid,
        OpType op,
        bytes calldata moduleParams,
        bytes calldata lzOptions
    ) external payable override nonReentrant whenNotPaused returns (bytes32 guid) {
        _collectCrossChainFee(0);

        bytes memory payload = abi.encode(op, msg.sender, moduleParams);
        MessagingFee memory fee = _quote(dstEid, payload, lzOptions, false);
        if (msg.value < fee.nativeFee) revert InsufficientLzFee();

        MessagingReceipt memory receipt = _lzSend(
            dstEid, payload, lzOptions, fee, payable(msg.sender)
        );
        guid = receipt.guid;

        emit CrossChainOpSent(dstEid, op, msg.sender, guid);
    }

    /// @notice Fan-out: broadcast the same op type to multiple chains in one tx.
    ///         Fee is charged once per destination chain.
    /// @param dstEids              Target chain LZ endpoint IDs
    /// @param op                   Operation type for all destinations
    /// @param moduleParamsPerChain Per-chain module params (length must match dstEids)
    /// @param lzOptions            Shared LZ options for all destinations
    /// @return guids               Per-chain message GUIDs
    function sendFanOut(
        uint32[] calldata dstEids,
        OpType op,
        bytes[] calldata moduleParamsPerChain,
        bytes calldata lzOptions
    ) external payable override nonReentrant whenNotPaused returns (bytes32[] memory guids) {
        uint256 n = dstEids.length;
        if (n == 0) revert FanOutEmpty();
        if (moduleParamsPerChain.length != n) revert ArrayLengthMismatch();

        _collectCrossChainFee(0);

        guids = new bytes32[](n);
        uint256 totalSpent;

        for (uint256 i; i < n; ++i) {
            bytes memory payload = abi.encode(op, msg.sender, moduleParamsPerChain[i]);
            MessagingFee memory fee = _quote(dstEids[i], payload, lzOptions, false);
            MessagingReceipt memory receipt = _lzSend(
                dstEids[i], payload, lzOptions, fee, payable(msg.sender)
            );
            guids[i] = receipt.guid;
            totalSpent += fee.nativeFee;

            emit CrossChainOpSent(dstEids[i], op, msg.sender, receipt.guid);
        }

        if (msg.value < totalSpent) revert InsufficientLzFee();

        // Refund excess native fee
        uint256 excess = msg.value - totalSpent;
        if (excess > 0) {
            (bool ok,) = payable(msg.sender).call{value: excess}("");
            require(ok, "MagnetaGateway: refund failed");
        }

        emit CrossChainFanOut(op, msg.sender, n);
    }

    /// @notice Estimate LZ fee for a single cross-chain op.
    function quoteCrossChainFee(
        uint32 dstEid,
        OpType op,
        bytes calldata moduleParams,
        bytes calldata lzOptions,
        bool payInLzToken
    ) external view override returns (uint256 nativeFee, uint256 lzTokenFee) {
        bytes memory payload = abi.encode(op, msg.sender, moduleParams);
        MessagingFee memory fee = _quote(dstEid, payload, lzOptions, payInLzToken);
        nativeFee = fee.nativeFee;
        lzTokenFee = fee.lzTokenFee;
    }

    /// @notice Estimate total LZ fees for a fan-out across multiple chains.
    function quoteFanOutFee(
        uint32[] calldata dstEids,
        OpType op,
        bytes[] calldata moduleParamsPerChain,
        bytes calldata lzOptions,
        bool payInLzToken
    ) external view override returns (uint256 totalNativeFee, uint256 totalLzTokenFee) {
        for (uint256 i; i < dstEids.length; ++i) {
            bytes memory payload = abi.encode(op, msg.sender, moduleParamsPerChain[i]);
            MessagingFee memory fee = _quote(dstEids[i], payload, lzOptions, payInLzToken);
            totalNativeFee += fee.nativeFee;
            totalLzTokenFee += fee.lzTokenFee;
        }
    }

    // ───────────────────────────── LZ receive ─────────────────────────────

    /// @dev Handle a cross-chain command forwarded by a sibling MagnetaGateway.
    ///      Payload layout: abi.encode(OpType op, address caller, bytes params).
    ///      Native fee for destination-chain execution must be provisioned by
    ///      the source call (attached as msg.value on _lzSend); any leftover is
    ///      forwarded to the module, which is expected to use USDC for ops.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        require(!processedGuid[_guid], "MagnetaGateway: guid already processed");
        processedGuid[_guid] = true;

        (OpType op, address caller, bytes memory params) =
            abi.decode(_payload, (OpType, address, bytes));

        address module = _modules[op];
        if (module == address(0)) revert ModuleNotSet(op);

        IModule.Context memory ctx = IModule.Context({
            caller: caller,
            originChainId: _srcEidToChainId(_origin.srcEid),
            feeVault: _feeVault
        });

        bytes memory result = IModule(module).execute(ctx, params);

        emit OperationExecuted(op, module, caller, ctx.originChainId, keccak256(result));
    }

    // ───────────────────────────── admin ─────────────────────────────

    /// @inheritdoc IMagnetaGateway
    function setModule(OpType op, address module) external override onlyOwner {
        _modules[op] = module;
        emit ModuleSet(op, module);
    }

    /// @inheritdoc IMagnetaGateway
    function setFeeVault(address vault) external override onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        address previous = _feeVault;
        _feeVault = vault;
        emit FeeVaultSet(previous, vault);
    }

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setPauseGuardian(address _guardian) external onlyOwner {
        address old = pauseGuardian;
        pauseGuardian = _guardian;
        emit PauseGuardianUpdated(old, _guardian);
    }

    /// @notice Set the USDC token used for cross-chain fee collection.
    function setUsdc(address _usdc) external onlyOwner {
        usdc = IERC20(_usdc);
    }

    /// @notice Set cross-chain fees: flat command fee (USDC 6d) and value fee (BPS).
    function setCrossChainFees(uint256 commandFee, uint16 valueFeeBps) external onlyOwner {
        crossChainCommandFee = commandFee;
        crossChainValueFeeBps = valueFeeBps;
        emit CrossChainFeesUpdated(commandFee, valueFeeBps);
    }

    /// @notice Map a LayerZero endpoint ID to an EVM chain ID (bidirectional).
    function setEidMapping(uint32 eid, uint256 chainId) external onlyOwner {
        _eidToChainId[eid] = chainId;
        _chainIdToEid[chainId] = eid;
        emit EidMappingSet(eid, chainId);
    }

    /// @notice Batch-set EID ↔ chain ID mappings for all supported chains.
    function setEidMappingBatch(
        uint32[] calldata eids,
        uint256[] calldata chainIds
    ) external onlyOwner {
        if (eids.length != chainIds.length) revert ArrayLengthMismatch();
        for (uint256 i; i < eids.length; ++i) {
            _eidToChainId[eids[i]] = chainIds[i];
            _chainIdToEid[chainIds[i]] = eids[i];
            emit EidMappingSet(eids[i], chainIds[i]);
        }
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @inheritdoc IMagnetaGateway
    function moduleFor(OpType op) external view override returns (address) {
        return _modules[op];
    }

    /// @inheritdoc IMagnetaGateway
    function feeVault() external view override returns (address) {
        return _feeVault;
    }

    /// @notice Get EVM chain ID for a LayerZero endpoint ID.
    function eidToChainId(uint32 eid) external view returns (uint256) {
        return _eidToChainId[eid];
    }

    /// @notice Get LayerZero endpoint ID for an EVM chain ID.
    function chainIdToEid(uint256 chainId) external view returns (uint32) {
        return _chainIdToEid[chainId];
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// @dev Resolve LZ EID to EVM chain ID using the on-chain mapping.
    function _srcEidToChainId(uint32 srcEid) internal view virtual returns (uint256) {
        return _eidToChainId[srcEid];
    }

    /// @dev Collect Magneta fee in USDC on the source chain for cross-chain ops.
    ///      valueUsdc6d = 0 for command ops (flat fee); >0 for value ops (BPS).
    function _collectCrossChainFee(uint256 valueUsdc6d) internal {
        if (address(usdc) == address(0)) return;

        uint256 fee;
        if (valueUsdc6d > 0 && crossChainValueFeeBps > 0) {
            fee = (valueUsdc6d * crossChainValueFeeBps) / 10_000;
        } else if (crossChainCommandFee > 0) {
            fee = crossChainCommandFee;
        }

        if (fee > 0) {
            usdc.safeTransferFrom(msg.sender, _feeVault, fee);
        }
    }

    /// @dev Ownable2Step requires overriding `_transferOwnership`? No —
    ///      OApp inherits from OAppCore which uses OZ Ownable. Ownable2Step
    ///      extends Ownable without clashing, but `transferOwnership` must
    ///      be explicitly resolved between Ownable and Ownable2Step.
    function transferOwnership(address newOwner)
        public
        override(Ownable, Ownable2Step)
        onlyOwner
    {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner)
        internal
        override(Ownable, Ownable2Step)
    {
        Ownable2Step._transferOwnership(newOwner);
    }

    /// @dev Accept native refunds from LayerZero endpoint during fan-out.
    receive() external payable {}
}
