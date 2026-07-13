// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { OApp, MessagingFee, MessagingReceipt, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMagnetaOFTStandardFactory {
    function createForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint
    ) external returns (address);
}

interface IMagnetaOFTAutoLiquidityFactory {
    function createForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        uint256 liquidityToBurn
    ) external returns (address);
}

/// @title CreateTokenDispatcher v3
/// @notice Sprint 9.7 — extends Sprint 9.6's CreateTokenDispatcher with a
///         single-tx `createTokenAtomic` that bundles:
///           1. Magneta service fee → FeeVault
///           2. Local create via `factory.createForCreator(msg.sender, …)`
///           3. Cross-chain fan-out via internal `_lzSend(...)`
///           4. Refund of excess `msg.value` to caller
///
///         The user signs ONCE; the contract dispatches everything.
///         `msg.sender` is preserved across all sub-paths because:
///           - `createForCreator` takes `creator` explicitly (this contract,
///             once registered as the factories' `crossChainCreator`, is
///             allowed to set arbitrary creators).
///           - The LZ payload encodes `msg.sender` so the destination-side
///             `_lzReceive` deploys the token with the original user as owner.
///
///         The Sprint 9.6 v2 entry points (`fanOutCreate`, `quoteFanOutFee`,
///         `_lzReceive`, `setStandardFactory`, `setAutoLiquidityFactory`,
///         `pause`, `unpause`, `setPeer`) are preserved with identical
///         behaviour so the SDK migration is incremental and the cross-chain
///         destination-side handler is unchanged.
contract CreateTokenDispatcherV3 is OApp, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    enum TemplateKind {
        Standard,
        AutoLiquidity
    }

    address public standardFactory;
    address public autoLiquidityFactory;

    /// @notice Where the Magneta service fee component of `createTokenAtomic`
    ///         is forwarded. Set immutably at construction.
    address public immutable feeVault;

    /// @notice Defense-in-depth replay guard at the application level. LZ V2
    ///         endpoint deduplicates by guid, but we also track it on-chain
    ///         to neutralise the 2026 replay-semantic divergence attack class
    ///         (CrossCurve $3M, 2026-02).
    mapping(bytes32 => bool) public processedGuids;

    // ─── Events ─────────────────────────────────────────────────────────────

    event StandardFactoryUpdated(address indexed previous, address indexed current);
    event AutoLiquidityFactoryUpdated(address indexed previous, address indexed current);
    event TokenCreateRequested(uint32 indexed dstEid, address indexed caller, bytes32 guid);
    event TokenSpawned(
        address indexed token, address indexed creator,
        TemplateKind indexed kind, uint256 originChainId,
        string name, string symbol
    );
    event CrossChainFanOut(address indexed caller, uint256 destinationCount);
    event AtomicCreate(
        address indexed caller,
        address indexed localToken,        // address(0) if no local create
        uint256 destinationCount,
        uint256 magnetaServiceFee
    );
    event NativeRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    // ─── Errors ─────────────────────────────────────────────────────────────

    error UnsupportedTemplate();
    error FactoryNotSet();
    error FanOutEmpty();
    error ArrayLengthMismatch();
    error InsufficientLzFee();
    error InvalidPayload();
    error NotAContract();
    error NothingToDo();
    error FeeVaultZero();
    error UntrustedSender(uint32 srcEid, bytes32 sender);
    error GuidReplayed(bytes32 guid);
    error ZeroCreator();
    error FeeVaultTransferFailed();
    error RefundFailed();
    error RescueToZero();
    error RescueFailed();

    constructor(
        address _endpoint,
        address _delegate,
        address _standardFactory,
        address _autoLiquidityFactory,
        address _feeVault
    )
        OApp(_endpoint, _delegate)
        Ownable(_delegate)
    {
        if (_feeVault == address(0)) revert FeeVaultZero();
        feeVault = _feeVault;

        if (_standardFactory != address(0))
            standardFactory = _standardFactory;
        if (_autoLiquidityFactory != address(0))
            autoLiquidityFactory = _autoLiquidityFactory;
        emit StandardFactoryUpdated(address(0), _standardFactory);
        emit AutoLiquidityFactoryUpdated(address(0), _autoLiquidityFactory);
    }

    // ─── Admin ──────────────────────────────────────────────────────────────

    function setStandardFactory(address f) external onlyOwner {
        if (f != address(0) && f.code.length == 0) revert NotAContract();
        emit StandardFactoryUpdated(standardFactory, f);
        standardFactory = f;
    }

    function setAutoLiquidityFactory(address f) external onlyOwner {
        if (f != address(0) && f.code.length == 0) revert NotAContract();
        emit AutoLiquidityFactoryUpdated(autoLiquidityFactory, f);
        autoLiquidityFactory = f;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Recover native left on the contract. The bare `receive()` lets
    ///         callers over-send / mis-route native that the happy-path LZ
    ///         refund (to msg.sender) never claws back, so without this the
    ///         funds would be stranded permanently (Sentinelle H-1).
    /// @dev    onlyOwner; sweeps the full balance to `to`.
    function rescueNative(address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = address(this).balance;
        (bool ok, ) = payable(to).call{ value: amount }("");
        if (!ok) revert RescueFailed();
        emit NativeRescued(to, amount);
    }

    /// @notice Recover ERC-20 tokens accidentally sent to the dispatcher.
    /// @dev    onlyOwner; sweeps the full token balance to `to`.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    // ─── Source-chain quotes ────────────────────────────────────────────────

    /// @notice Quote the total native fee required to fan out a CREATE_TOKEN
    ///         to N destinations (without a local create). Frontend reads this
    ///         BEFORE asking the user to sign the actual `fanOutCreate`.
    function quoteFanOutFee(
        uint32[] calldata dstEids,
        bytes[] calldata moduleParamsPerChain,
        bytes calldata lzOptions,
        bool payInLzToken
    ) external view returns (uint256 totalNativeFee, uint256 totalLzTokenFee) {
        uint256 n = dstEids.length;
        if (n == 0 || moduleParamsPerChain.length != n) revert ArrayLengthMismatch();
        for (uint256 i; i < n; ++i) {
            bytes memory payload = abi.encode(uint8(0), msg.sender, moduleParamsPerChain[i]);
            MessagingFee memory fee = _quote(dstEids[i], payload, lzOptions, payInLzToken);
            totalNativeFee += fee.nativeFee;
            totalLzTokenFee += fee.lzTokenFee;
        }
    }

    /// @notice Quote the LZ fee component of a `createTokenAtomic` call. The
    ///         total `msg.value` to send is `lzFee + magnetaServiceFee +
    ///         (any factory createFee, currently 0 for the cross-chain creator
    ///         path)`. The frontend computes the Magneta service fee off-chain
    ///         from the displayed pricing and passes it as `magnetaServiceFee`.
    function quoteCreateAtomic(
        uint32[] calldata dstEids,
        bytes[] calldata moduleParamsPerChain,
        bytes calldata lzOptions,
        bool payInLzToken
    ) external view returns (uint256 totalNativeFee, uint256 totalLzTokenFee) {
        // Same math as quoteFanOutFee — the local-create path doesn't consume
        // native value (createForCreator is fee-less; service fee is a
        // straight transfer to FeeVault).
        if (dstEids.length == 0) return (0, 0);
        if (moduleParamsPerChain.length != dstEids.length) revert ArrayLengthMismatch();
        for (uint256 i; i < dstEids.length; ++i) {
            bytes memory payload = abi.encode(uint8(0), msg.sender, moduleParamsPerChain[i]);
            MessagingFee memory fee = _quote(dstEids[i], payload, lzOptions, payInLzToken);
            totalNativeFee += fee.nativeFee;
            totalLzTokenFee += fee.lzTokenFee;
        }
    }

    // ─── Source-chain dispatch ──────────────────────────────────────────────

    /// @notice Single-tx token creation across the source chain + N destinations.
    ///
    /// @param localParams        Encoded local-create params (template byte ||
    ///                           abi.encode(StandardParams|AutoLiquidityParams)).
    ///                           Empty bytes (`""`) skips local create.
    /// @param dstEids            Cross-chain destinations. Empty array skips fanout.
    /// @param paramsPerChain     Per-destination params, same encoding as `localParams`.
    /// @param lzOptions          LZ V2 Type 3 options blob.
    /// @param magnetaServiceFee  Off-chain Magneta service fee, forwarded to FeeVault.
    function createTokenAtomic(
        bytes calldata localParams,
        uint32[] calldata dstEids,
        bytes[] calldata paramsPerChain,
        bytes calldata lzOptions,
        uint256 magnetaServiceFee
    )
        external payable nonReentrant whenNotPaused
        returns (address localToken, bytes32[] memory guids)
    {
        bool hasLocal = localParams.length > 0;
        uint256 n = dstEids.length;
        if (!hasLocal && n == 0) revert NothingToDo();
        if (paramsPerChain.length != n) revert ArrayLengthMismatch();

        // 1. Forward Magneta service fee to FeeVault.
        if (magnetaServiceFee > 0) {
            if (msg.value < magnetaServiceFee) revert InsufficientLzFee();
            (bool ok, ) = payable(feeVault).call{value: magnetaServiceFee}("");
            if (!ok) revert FeeVaultTransferFailed();
        }

        // 2. Local create — preserve msg.sender as creator via createForCreator.
        if (hasLocal) {
            localToken = _executeCreate(msg.sender, localParams, block.chainid);
        }

        // 3. Cross-chain fan-out — encode msg.sender so destination knows the creator.
        guids = new bytes32[](n);
        uint256 lzSpent;
        for (uint256 i; i < n; ++i) {
            bytes memory payload = abi.encode(uint8(0), msg.sender, paramsPerChain[i]);
            MessagingFee memory fee = _quote(dstEids[i], payload, lzOptions, false);
            MessagingReceipt memory receipt = _lzSend(
                dstEids[i], payload, lzOptions, fee, payable(msg.sender)
            );
            guids[i] = receipt.guid;
            lzSpent += fee.nativeFee;
            emit TokenCreateRequested(dstEids[i], msg.sender, receipt.guid);
        }

        // 4. Refund any leftover native to the caller.
        uint256 totalSpent = magnetaServiceFee + lzSpent;
        if (msg.value < totalSpent) revert InsufficientLzFee();
        uint256 excess = msg.value - totalSpent;
        if (excess > 0) {
            (bool ok, ) = payable(msg.sender).call{value: excess}("");
            if (!ok) revert RefundFailed();
        }

        emit AtomicCreate(msg.sender, localToken, n, magnetaServiceFee);
    }

    /// @notice Sprint 9.6 v2 entry point — kept for legacy SDK callers and for
    ///         cases where the caller wants a fan-out without any local create
    ///         or service fee. Same semantics as v2.
    function fanOutCreate(
        uint32[] calldata dstEids,
        bytes[] calldata moduleParamsPerChain,
        bytes calldata lzOptions
    )
        external payable nonReentrant whenNotPaused
        returns (bytes32[] memory guids)
    {
        uint256 n = dstEids.length;
        if (n == 0) revert FanOutEmpty();
        if (moduleParamsPerChain.length != n) revert ArrayLengthMismatch();

        guids = new bytes32[](n);
        uint256 totalSpent;

        for (uint256 i; i < n; ++i) {
            bytes memory payload = abi.encode(uint8(0), msg.sender, moduleParamsPerChain[i]);
            MessagingFee memory fee = _quote(dstEids[i], payload, lzOptions, false);
            MessagingReceipt memory receipt = _lzSend(
                dstEids[i], payload, lzOptions, fee, payable(msg.sender)
            );
            guids[i] = receipt.guid;
            totalSpent += fee.nativeFee;

            emit TokenCreateRequested(dstEids[i], msg.sender, receipt.guid);
        }

        if (msg.value < totalSpent) revert InsufficientLzFee();

        uint256 excess = msg.value - totalSpent;
        if (excess > 0) {
            (bool ok,) = payable(msg.sender).call{value: excess}("");
            require(ok, "CTD: refund failed");
        }

        emit CrossChainFanOut(msg.sender, n);
    }

    // ─── Destination receive (LZ V2 hook) ───────────────────────────────────

    /// @notice LZ V2 receive hook with three explicit guards (defense-in-depth):
    ///         1. trusted-sender — `_origin.sender` must equal the registered
    ///            peer for `_origin.srcEid` (DVN-spoof guard, Kelp DAO pattern).
    ///         2. processedGuids — application-level dedup on top of LZ V2
    ///            endpoint guid (replay-semantic divergence, CrossCurve pattern).
    ///         3. zero-creator — a malformed payload with `creator =
    ///            address(0)` would permanently lock token ownership.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _payload,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) internal override whenNotPaused {
        bytes32 expectedPeer = _getPeerOrRevert(_origin.srcEid);
        if (expectedPeer != _origin.sender) revert UntrustedSender(_origin.srcEid, _origin.sender);

        if (processedGuids[_guid]) revert GuidReplayed(_guid);
        processedGuids[_guid] = true;

        if (_payload.length < 64) revert InvalidPayload();
        (, address creator, bytes memory params) = abi.decode(_payload, (uint8, address, bytes));
        if (creator == address(0)) revert ZeroCreator();
        _executeCreate(creator, params, _srcEidToChainId(_origin.srcEid));
    }

    function _srcEidToChainId(uint32 srcEid) internal pure returns (uint256) {
        if (srcEid == 30101) return 1;
        if (srcEid == 30110) return 42161;
        if (srcEid == 30184) return 8453;
        if (srcEid == 30109) return 137;
        if (srcEid == 30102) return 56;
        if (srcEid == 30111) return 10;
        if (srcEid == 30106) return 43114;
        if (srcEid == 30183) return 59144;
        if (srcEid == 30181) return 5000;
        if (srcEid == 30145) return 100;
        if (srcEid == 30125) return 42220;
        if (srcEid == 30295) return 14;
        if (srcEid == 30280) return 1329;
        if (srcEid == 30362) return 80094;
        if (srcEid == 30375) return 747474;
        if (srcEid == 30390) return 143;
        if (srcEid == 30383) return 9745;
        if (srcEid == 30332) return 146;
        if (srcEid == 30320) return 130;
        if (srcEid == 30324) return 2741;
        return 0;
    }

    // ─── Internal create dispatch ───────────────────────────────────────────

    struct StandardParams {
        string name;
        string symbol;
        string tokenURI;
        uint256 totalSupply;
        bool revokeUpdate;
        bool revokeFreeze;
        bool revokeMint;
    }

    struct AutoLiquidityParams {
        string name;
        string symbol;
        string tokenURI;
        uint256 totalSupply;
        uint256 liquidityToBurn;
    }

    function _executeCreate(address creator, bytes memory params, uint256 originChainId)
        internal
        returns (address)
    {
        if (params.length == 0) revert InvalidPayload();
        TemplateKind kind = TemplateKind(uint8(params[0]));
        bytes memory inner = _slice(params, 1);

        if (kind == TemplateKind.Standard) {
            return _createStandard(creator, inner, originChainId);
        } else if (kind == TemplateKind.AutoLiquidity) {
            return _createAutoLiquidity(creator, inner, originChainId);
        }
        revert UnsupportedTemplate();
    }

    function _createStandard(address creator, bytes memory raw, uint256 originChainId)
        internal returns (address)
    {
        if (standardFactory == address(0)) revert FactoryNotSet();
        StandardParams memory p = abi.decode(raw, (StandardParams));
        address token = IMagnetaOFTStandardFactory(standardFactory).createForCreator(
            creator,
            p.name,
            p.symbol,
            p.tokenURI,
            p.totalSupply,
            p.revokeUpdate,
            p.revokeFreeze,
            p.revokeMint
        );
        emit TokenSpawned(token, creator, TemplateKind.Standard, originChainId, p.name, p.symbol);
        return token;
    }

    function _createAutoLiquidity(address creator, bytes memory raw, uint256 originChainId)
        internal returns (address)
    {
        if (autoLiquidityFactory == address(0)) revert FactoryNotSet();
        AutoLiquidityParams memory p = abi.decode(raw, (AutoLiquidityParams));
        address token = IMagnetaOFTAutoLiquidityFactory(autoLiquidityFactory).createForCreator(
            creator,
            p.name,
            p.symbol,
            p.tokenURI,
            p.totalSupply,
            p.liquidityToBurn
        );
        emit TokenSpawned(token, creator, TemplateKind.AutoLiquidity, originChainId, p.name, p.symbol);
        return token;
    }

    // ─── Encoding helpers (mirror Sprint 4 SDK) ─────────────────────────────

    function encodeStandardParams(StandardParams calldata p)
        external pure returns (bytes memory)
    {
        return bytes.concat(bytes1(uint8(TemplateKind.Standard)), abi.encode(p));
    }

    function encodeAutoLiquidityParams(AutoLiquidityParams calldata p)
        external pure returns (bytes memory)
    {
        return bytes.concat(bytes1(uint8(TemplateKind.AutoLiquidity)), abi.encode(p));
    }

    // ─── LZ payment override ────────────────────────────────────────────────

    /// @dev Same override as v2 — accept msg.value >= per-call fee (the v2
    ///      OAppSender default uses strict equality, which blocks any drift
    ///      buffer). The `createTokenAtomic` and `fanOutCreate` loops enforce
    ///      the cumulative bound.
    function _payNative(uint256 _nativeFee) internal override returns (uint256 nativeFee) {
        if (msg.value < _nativeFee) revert NotEnoughNative(msg.value);
        return _nativeFee;
    }

    // ─── Internal utility ───────────────────────────────────────────────────

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        uint256 len = data.length;
        require(len >= start, "CTD: out of range");
        bytes memory result = new bytes(len - start);
        for (uint256 i; i < result.length; ++i) {
            result[i] = data[start + i];
        }
        return result;
    }

    receive() external payable {}
}
