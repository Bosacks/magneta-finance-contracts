// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { OApp, MessagingFee, MessagingReceipt, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal interface to the Standard OFT factory's permissioned entrypoint.
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

/// @title CreateTokenDispatcher
/// @notice Dedicated LayerZero V2 OApp for cross-chain CREATE_TOKEN dispatch.
///
///         **Why a separate dispatcher?** The existing `MagnetaGateway` deployed
///         in Sprint 1 has an `OpType` enum capped at index 12 (CLAIM_TAX_FEES /
///         SWAP_LOCAL / SWAP_OUT). The Sprint 2 addition `CREATE_TOKEN = 13`
///         doesn't exist in the on-chain bytecode → `setModule(13, …)` reverts
///         with "invalid enum input". Redeploying the Gateway on 19 chains
///         would invalidate 1026 LZ peer wires + force redeploy of every
///         module (gateway is `immutable` on each).
///
///         This dispatcher sidesteps that by being its own OApp — it owns its
///         own peer mapping (19×18 = 342 wires) and dispatches CREATE_TOKEN
///         directly to local factories via their `crossChainCreator` slot.
///         The Gateway is left untouched, all existing ops (LP/SWAP/MINT/
///         FREEZE/REVOKE/TAX) keep working through it.
///
///         Sprint 9.6 — V1 launch.
contract CreateTokenDispatcher is OApp, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Sub-op selector encoded in the first byte of the params payload.
    enum TemplateKind {
        Standard,         // → IMagnetaOFTStandardFactory.createForCreator
        AutoLiquidity     // → IMagnetaOFTAutoLiquidityFactory.createForCreator
    }

    /// @notice Per-chain Standard OFT factory. May be address(0) on chains
    ///         where the Standard template isn't supported (e.g. abstract,
    ///         berachain — no V2 DEX → no factories deployed).
    address public standardFactory;

    /// @notice Per-chain AutoLiquidity OFT factory. Same nullable semantic.
    address public autoLiquidityFactory;

    /// @notice Defense-in-depth replay guard at the application level. LZ V2
    ///         endpoint deduplicates by guid, but we also track it on-chain
    ///         to neutralise the 2026 replay-semantic divergence attack class
    ///         (CrossCurve $3M, 2026-02) where chain-divergent or
    ///         endpoint-upgrade scenarios can alter guid semantics.
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
    error UntrustedSender(uint32 srcEid, bytes32 sender);
    error GuidReplayed(bytes32 guid);
    error ZeroCreator();
    error RescueToZero();
    error RescueFailed();

    /// @param _endpoint              LayerZero V2 endpoint for this chain
    /// @param _delegate              Initial owner (typically the deployer EOA;
    ///                               post-deploy transferred to the Magneta Safe)
    /// @param _standardFactory       Local Standard OFT factory (may be 0)
    /// @param _autoLiquidityFactory  Local AutoLiquidity OFT factory (may be 0)
    constructor(
        address _endpoint,
        address _delegate,
        address _standardFactory,
        address _autoLiquidityFactory
    )
        OApp(_endpoint, _delegate)
        Ownable(_delegate)
    {
        if (_standardFactory != address(0))
            standardFactory = _standardFactory;
        if (_autoLiquidityFactory != address(0))
            autoLiquidityFactory = _autoLiquidityFactory;
        emit StandardFactoryUpdated(address(0), _standardFactory);
        emit AutoLiquidityFactoryUpdated(address(0), _autoLiquidityFactory);
    }

    // ─── Admin: late-bind factories ─────────────────────────────────────────

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

    // ─── Source-chain dispatch ──────────────────────────────────────────────

    /// @notice Quote the total native fee required to fan out a CREATE_TOKEN
    ///         to N destinations. Frontend reads this BEFORE asking the user
    ///         to sign the actual `fanOutCreate` to set msg.value correctly.
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

    /// @notice Fan out a CREATE_TOKEN op to N destination chains in one user
    ///         signature. Each `paramsPerChain[i]` is `bytes1 templateKind ||
    ///         abi.encode(StandardParams or AutoLiquidityParams)`.
    /// @dev    Payload version byte = 0 (command op, no value bridged). Caller
    ///         identity (the original user) is included in the payload so the
    ///         remote dispatcher knows which EOA to register as the token's
    ///         owner. Excess `msg.value` after LZ fees is refunded.
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
    ///            peer for `_origin.srcEid` (DVN-spoof guard, Kelp DAO $292M
    ///            pattern). The OApp parent class also enforces this in its
    ///            public `lzReceive`, but we re-assert here for visibility.
    ///         2. processedGuids — application-level dedup on top of the LZ V2
    ///            endpoint guid (replay-semantic divergence guard, CrossCurve
    ///            $3M pattern).
    ///         3. zero-creator — a malformed payload encoding `creator =
    ///            address(0)` would mint a token whose ownership is
    ///            permanently locked at the zero address.
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

    /// @dev Best-effort EID → chainId lookup for event metadata. Returning 0
    ///      when unknown is acceptable — the event field is informational,
    ///      not load-bearing for the create itself.
    function _srcEidToChainId(uint32 srcEid) internal pure returns (uint256) {
        if (srcEid == 30101) return 1;       // ethereum
        if (srcEid == 30110) return 42161;   // arbitrum
        if (srcEid == 30184) return 8453;    // base
        if (srcEid == 30109) return 137;     // polygon
        if (srcEid == 30102) return 56;      // bsc
        if (srcEid == 30111) return 10;      // optimism
        if (srcEid == 30106) return 43114;   // avalanche
        if (srcEid == 30183) return 59144;   // linea
        if (srcEid == 30181) return 5000;    // mantle
        if (srcEid == 30145) return 100;     // gnosis
        if (srcEid == 30125) return 42220;   // celo
        if (srcEid == 30295) return 14;      // flare
        if (srcEid == 30280) return 1329;    // sei
        if (srcEid == 30362) return 80094;   // berachain
        if (srcEid == 30375) return 747474;  // katana
        if (srcEid == 30390) return 143;     // monad
        if (srcEid == 30383) return 9745;    // plasma
        if (srcEid == 30332) return 146;     // sonic
        if (srcEid == 30320) return 130;     // unichain
        if (srcEid == 30324) return 2741;    // abstract
        return 0;
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

    // ─── Per-template factory dispatch ──────────────────────────────────────

    struct StandardParams {
        string name;
        string symbol;
        string tokenURI;
        uint256 totalSupply;
        bool revokeUpdate;
        bool revokeFreeze;
        bool revokeMint;
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

    struct AutoLiquidityParams {
        string name;
        string symbol;
        string tokenURI;
        uint256 totalSupply;
        uint256 liquidityToBurn;
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

    /// @dev Override the default OAppSender `_payNative` (which requires
    ///      `msg.value == _nativeFee`, strict equality). For a multi-destination
    ///      fanOut, msg.value contains the SUM of all per-call fees plus a
    ///      caller-side buffer to absorb LZ price drift between the quote and
    ///      the actual `endpoint.send`. We accept any msg.value >= per-call
    ///      fee; the loop in `fanOutCreate` enforces the cumulative bound and
    ///      refunds the excess at the end. Without this override, even a
    ///      single-destination call with any drift buffer would revert with
    ///      `NotEnoughNative`.
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
