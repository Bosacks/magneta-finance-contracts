// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

import "../interfaces/IMagnetaGateway.sol";
import "../interfaces/IModule.sol";

/// @title MagnetaGateway
/// @notice Per-chain facade for the chain-service SDK. Dispatches local calls
///         from the SDK and incoming LayerZero messages from sibling gateways
///         to the registered module for the given OpType.
/// @dev    One instance deployed per chain. Uses OApp (LZ v2) as message bus.
contract MagnetaGateway is IMagnetaGateway, OApp, Ownable2Step, ReentrancyGuard, Pausable {
    using Address for address;

    /// @notice Registry OpType -> module implementation.
    mapping(OpType => address) private _modules;

    /// @notice USDC vault that collects the Magneta markup on this chain.
    address private _feeVault;

    /// @notice Guards against replayed LZ messages at the gateway level
    ///         (OApp already deduplicates, but we track processed GUIDs so a
    ///         module callback never re-enters the dispatcher for a given msg).
    mapping(bytes32 => bool) public processedGuid;

    error ModuleNotSet(OpType op);
    error ZeroAddress();
    error SameChainIdRequired();
    error CrossChainDispatchDisabled();

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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
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

    // ───────────────────────────── internals ─────────────────────────────

    /// @dev LZ EIDs don't map 1:1 to chain ids. Modules that need the true
    ///      origin chain id should maintain their own mapping; this default
    ///      returns 0 when unknown so modules can detect and reject.
    /// @notice Override in a subclass or extend if the origin chain id is
    ///         required for business logic on this chain.
    function _srcEidToChainId(uint32 /*srcEid*/) internal view virtual returns (uint256) {
        return 0;
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
}
