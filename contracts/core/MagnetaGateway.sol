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
import "../interfaces/ICCTP.sol";

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

    /// @notice Attested floor for this gateway's LayerZero receive-DVN quorum.
    ///         The protocol Safe sets this after verifying the actual LZ ULN
    ///         configuration off-chain (≥ 2 DVNs required and `confirmations`
    ///         meets policy). Downstream modules consume this in their
    ///         constructors to refuse wiring into a gateway whose attested
    ///         quorum is too low — the on-chain anchor for the Kelp-DAO-class
    ///         single-validator-risk mitigation.
    ///
    ///         IMPORTANT: setting this does NOT change the actual LZ config.
    ///         It is a Safe attestation. Operators must update it after any
    ///         LZ config change AND re-verify that no module's constructor
    ///         invariant is now violated. A planned downgrade ALSO requires
    ///         re-deploying any module that asserts ≥ 2.
    uint8 private _requiredDVNCount;

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

    /// @notice Upper bound on `crossChainCommandFee` (100 USDC). Above this,
    ///         operators could brick all cross-chain ops by overcharging.
    uint256 public constant MAX_CROSSCHAIN_COMMAND_FEE = 100_000_000; // $100

    /// @notice Upper bound on `crossChainValueFeeBps` (10%). Above this, the
    ///         protocol could skim arbitrary amounts of bridged value.
    uint16 public constant MAX_CROSSCHAIN_VALUE_FEE_BPS = 1000;

    /// @notice Circle CCTP TokenMessenger for burning/minting USDC cross-chain.
    ITokenMessenger public cctpMessenger;

    /// @notice CCTP domain of this chain (0=Eth, 1=Avax, 2=Op, 3=Arb, 6=Base, 7=Pol).
    uint32 public localCctpDomain;

    /// @notice Destination LZ EID → CCTP domain mapping.
    mapping(uint32 => uint32) public eidToCctpDomain;

    /// @notice Pending cross-chain value ops waiting for CCTP token arrival.
    struct PendingValueOp {
        OpType op;
        address caller;
        bytes params;
        address bridgedToken;
        uint256 bridgedAmount;
        uint256 createdAt;
    }
    mapping(bytes32 => PendingValueOp) public pendingValueOps;

    /// @notice Total USDC earmarked for pending value ops (prevents double-spend).
    uint256 public totalEarmarked;

    error ModuleNotSet(OpType op);
    error ZeroAddress();
    error ArrayLengthMismatch();
    error InsufficientLzFee();
    error FanOutEmpty();
    error NoPendingOp();
    error TokensNotArrived();
    error CctpNotConfigured();

    address public pauseGuardian;
    event PauseGuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event CrossChainOpSent(uint32 indexed dstEid, OpType indexed op, address indexed caller, bytes32 guid);
    event CrossChainFanOut(OpType indexed op, address indexed caller, uint256 chainCount);
    event EidMappingSet(uint32 eid, uint256 chainId);
    event CrossChainFeesUpdated(uint256 commandFee, uint16 valueFeeBps);
    event ValueOpPending(bytes32 indexed guid, OpType indexed op, address indexed caller, address token, uint256 amount);
    event ValueOpFulfilled(bytes32 indexed guid, OpType indexed op, address indexed caller);
    event CctpConfigUpdated(address messenger, uint32 localDomain);
    event UsdcSet(address indexed usdc);
    event EidCctpDomainSet(uint32 indexed eid, uint32 indexed cctpDomain);
    event Rescued(address indexed token, address indexed to, uint256 amount);

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
            feeVault: _feeVault,
            tokenSource: address(0)
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
        _collectCrossChainFee(0, 1);

        bytes memory payload = abi.encode(uint8(0), op, msg.sender, moduleParams);
        MessagingFee memory fee = _quote(dstEid, payload, lzOptions, false);
        if (msg.value < fee.nativeFee) revert InsufficientLzFee();

        MessagingReceipt memory receipt = _lzSend(
            dstEid, payload, lzOptions, fee, payable(msg.sender)
        );
        guid = receipt.guid;

        emit CrossChainOpSent(dstEid, op, msg.sender, guid);
    }

    // ───────────────────── cross-chain value ops ─────────────────────

    /// @notice Send a cross-chain VALUE operation: bridge USDC via CCTP, then
    ///         dispatch the op on the destination chain once tokens arrive.
    /// @param dstEid         Target chain LZ endpoint ID
    /// @param op             Operation to execute on destination
    /// @param moduleParams   ABI-encoded params for the target module
    /// @param usdcAmount     Amount of USDC to bridge (6 decimals)
    /// @param lzOptions      LayerZero executor options
    function sendCrossChainValueOp(
        uint32 dstEid,
        OpType op,
        bytes calldata moduleParams,
        uint256 usdcAmount,
        bytes calldata lzOptions
    ) external payable override nonReentrant whenNotPaused returns (bytes32 guid) {
        if (address(cctpMessenger) == address(0)) revert CctpNotConfigured();
        if (address(usdc) == address(0)) revert CctpNotConfigured();

        // Collect Magneta value-based fee (0.15% of USDC amount)
        _collectCrossChainFee(usdcAmount, 1);

        // Pull USDC from caller and burn via CCTP
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // CCTP mint recipient = the sibling gateway on destination chain
        bytes32 peer = peers[dstEid];
        require(peer != bytes32(0), "MagnetaGateway: no peer for dstEid");
        bytes32 mintRecipient = peer; // peer is already bytes32-padded address

        usdc.forceApprove(address(cctpMessenger), usdcAmount);
        cctpMessenger.depositForBurn(
            usdcAmount,
            eidToCctpDomain[dstEid],
            mintRecipient,
            address(usdc)
        );

        // Send LZ command (version 1 = value op)
        bytes memory payload = abi.encode(
            uint8(1), op, msg.sender, moduleParams, address(usdc), usdcAmount
        );
        MessagingFee memory fee = _quote(dstEid, payload, lzOptions, false);
        if (msg.value < fee.nativeFee) revert InsufficientLzFee();

        MessagingReceipt memory receipt = _lzSend(
            dstEid, payload, lzOptions, fee, payable(msg.sender)
        );
        guid = receipt.guid;

        emit CrossChainOpSent(dstEid, op, msg.sender, guid);
    }

    /// @notice Fulfill a pending cross-chain value op after CCTP tokens have
    ///         been minted to this gateway. Callable by anyone (permissionless
    ///         — the op was already authorized by LZ message verification).
    /// @dev    Permissionless by design: the Magneta relayer is the normal
    ///         caller, but anyone may fulfill so a stuck op is never censorable.
    ///         This is theft-safe — the op's params (incl. slippage minimums)
    ///         were fixed at send time on the origin chain and re-validated by
    ///         the module, the earmark invariant below blocks borrowing another
    ///         op's funds, and effects precede the module call under
    ///         nonReentrant. The residual is griefing/MEV (an adversary picking
    ///         an unfavorable block); bounded by the caller-supplied minimums,
    ///         so worst case the op reverts and stays pending. (Sentinelle
    ///         2026-05-25 SC01 MEDIUM — acknowledged, behaviour intentional.)
    function fulfillValueOp(bytes32 _guid) external override nonReentrant whenNotPaused {
        PendingValueOp memory p = pendingValueOps[_guid];
        require(p.bridgedAmount > 0, "MagnetaGateway: no pending op");

        uint256 available = IERC20(p.bridgedToken).balanceOf(address(this));
        require(available >= totalEarmarked, "MagnetaGateway: tokens not arrived");

        address module = _modules[p.op];
        if (module == address(0)) revert ModuleNotSet(p.op);

        totalEarmarked -= p.bridgedAmount;
        delete pendingValueOps[_guid];

        // Approve module to pull bridged tokens from this gateway
        IERC20(p.bridgedToken).forceApprove(module, p.bridgedAmount);

        IModule.Context memory ctx = IModule.Context({
            caller: p.caller,
            originChainId: 0, // cross-chain marker
            feeVault: _feeVault,
            tokenSource: address(this)
        });

        bytes memory result = IModule(module).execute(ctx, p.params);

        emit ValueOpFulfilled(_guid, p.op, p.caller);
        emit OperationExecuted(p.op, module, p.caller, 0, keccak256(result));
    }

    /// @notice Fan-out: broadcast the same op type to multiple chains in one tx.
    ///         The Magneta command fee is charged once per destination
    ///         chain (e.g. fan-out to 5 chains = 5 × `crossChainCommandFee`).
    ///         LayerZero native fees are charged per destination by the LZ
    ///         endpoint itself; any excess `msg.value` is refunded to the
    ///         caller at the end.
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

        // MG-3: charge the command fee once × n destinations (was once total).
        _collectCrossChainFee(0, n);

        guids = new bytes32[](n);
        uint256 totalSpent;

        for (uint256 i; i < n; ++i) {
            bytes memory payload = abi.encode(uint8(0), op, msg.sender, moduleParamsPerChain[i]);
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

    /// @notice Fan-out VALUE op: bridge USDC via CCTP + send LZ messages to N chains.
    ///         Each destination gets its own CCTP burn + version-1 LZ message.
    ///         Fee is charged once on the total USDC amount.
    function sendFanOutValueOp(
        uint32[] calldata dstEids,
        OpType op,
        bytes[] calldata moduleParamsPerChain,
        uint256[] calldata usdcAmountsPerChain,
        bytes calldata lzOptions
    ) external payable override nonReentrant whenNotPaused returns (bytes32[] memory guids) {
        if (address(cctpMessenger) == address(0)) revert CctpNotConfigured();
        uint256 n = dstEids.length;
        if (n == 0) revert FanOutEmpty();
        if (moduleParamsPerChain.length != n || usdcAmountsPerChain.length != n) revert ArrayLengthMismatch();

        uint256 totalUsdc;
        for (uint256 i; i < n; ++i) totalUsdc += usdcAmountsPerChain[i];

        // Value fee is proportional to total bridged USDC; nDestinations=1
        // because we want one BPS application to the aggregate, not n.
        _collectCrossChainFee(totalUsdc, 1);

        usdc.safeTransferFrom(msg.sender, address(this), totalUsdc);
        usdc.forceApprove(address(cctpMessenger), totalUsdc);

        guids = new bytes32[](n);
        uint256 totalLzSpent;

        for (uint256 i; i < n; ++i) {
            bytes32 peer = peers[dstEids[i]];
            require(peer != bytes32(0), "MagnetaGateway: no peer for dstEid");

            cctpMessenger.depositForBurn(
                usdcAmountsPerChain[i],
                eidToCctpDomain[dstEids[i]],
                peer,
                address(usdc)
            );

            bytes memory payload = abi.encode(
                uint8(1), op, msg.sender, moduleParamsPerChain[i], address(usdc), usdcAmountsPerChain[i]
            );
            MessagingFee memory fee = _quote(dstEids[i], payload, lzOptions, false);
            MessagingReceipt memory receipt = _lzSend(
                dstEids[i], payload, lzOptions, fee, payable(msg.sender)
            );
            guids[i] = receipt.guid;
            totalLzSpent += fee.nativeFee;

            emit CrossChainOpSent(dstEids[i], op, msg.sender, receipt.guid);
        }

        if (msg.value < totalLzSpent) revert InsufficientLzFee();

        uint256 excess = msg.value - totalLzSpent;
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
        bytes memory payload = abi.encode(uint8(0), op, msg.sender, moduleParams);
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
            bytes memory payload = abi.encode(uint8(0), op, msg.sender, moduleParamsPerChain[i]);
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
        // Defense-in-depth trusted-sender check. OAppReceiver.lzReceive already
        // enforces OnlyPeer (`_getPeerOrRevert(srcEid) == sender`) before
        // dispatching here, so this is redundant today — but asserting it
        // locally keeps the cross-chain-forgery invariant inside _lzReceive
        // itself, surviving any future refactor of the inherited entrypoint.
        // (Sentinelle 2026-05-25 SC05 / DVN-spoof class, Kelp DAO $292M pattern.)
        require(
            peers[_origin.srcEid] != bytes32(0) && _origin.sender == peers[_origin.srcEid],
            "MagnetaGateway: unauthorized sender"
        );

        require(!processedGuid[_guid], "MagnetaGateway: guid already processed");
        processedGuid[_guid] = true;

        uint8 version = abi.decode(_payload[:32], (uint8));

        if (version == 0) {
            // Command op — execute immediately
            (, OpType op, address caller, bytes memory params) =
                abi.decode(_payload, (uint8, OpType, address, bytes));

            address module = _modules[op];
            if (module == address(0)) revert ModuleNotSet(op);

            IModule.Context memory ctx = IModule.Context({
                caller: caller,
                originChainId: _srcEidToChainId(_origin.srcEid),
                feeVault: _feeVault,
                tokenSource: address(0)
            });

            bytes memory result = IModule(module).execute(ctx, params);
            emit OperationExecuted(op, module, caller, ctx.originChainId, keccak256(result));

        } else if (version == 1) {
            // Value op — store as pending, wait for CCTP tokens.
            //
            // The source-chain payload includes its own `address(usdc)` for
            // traceability, but CCTP V1 mints LOCAL USDC on the destination
            // (Circle's USDC has a different address on every chain). We
            // store this gateway's configured `usdc` so fulfillValueOp can
            // check the right balance and approve the module on the right
            // ERC-20. The source-encoded address is intentionally discarded.
            (, OpType op, address caller, bytes memory params,
             /* address payloadBridgedToken */, uint256 bridgedAmount) =
                abi.decode(_payload, (uint8, OpType, address, bytes, address, uint256));

            pendingValueOps[_guid] = PendingValueOp({
                op: op,
                caller: caller,
                params: params,
                bridgedToken: address(usdc),
                bridgedAmount: bridgedAmount,
                createdAt: block.timestamp
            });
            totalEarmarked += bridgedAmount;

            emit ValueOpPending(_guid, op, caller, address(usdc), bridgedAmount);
        }
    }

    // ───────────────────────────── admin ─────────────────────────────

    /// @inheritdoc IMagnetaGateway
    function setModule(OpType op, address module) external override onlyOwner {
        // Zero-address would silently brick all executeOperation /
        // _lzReceive paths for this op (every call reverts ModuleNotSet,
        // and any in-flight LZ messages targeting it land permanently
        // stuck in pendingValueOps). Force callers to use a real
        // implementation; nothing in the protocol uses address(0) as a
        // 'disable' sentinel. (Sentinelle 2026-05-30 SC01 MEDIUM.)
        if (module == address(0)) revert ZeroAddress();
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

    /// @inheritdoc IMagnetaGateway
    function requiredDVNCount() external view override returns (uint8) {
        return _requiredDVNCount;
    }

    /// @inheritdoc IMagnetaGateway
    function setRequiredDVNCount(uint8 newCount) external override onlyOwner {
        uint8 previous = _requiredDVNCount;
        _requiredDVNCount = newCount;
        emit RequiredDVNCountSet(previous, newCount);
    }

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setPauseGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "MagnetaGateway: zero guardian");
        address old = pauseGuardian;
        pauseGuardian = _guardian;
        emit PauseGuardianUpdated(old, _guardian);
    }

    /// @notice Set the USDC token used for cross-chain fee collection.
    function setUsdc(address _usdc) external onlyOwner {
        require(_usdc != address(0), "MagnetaGateway: zero usdc");
        usdc = IERC20(_usdc);
        emit UsdcSet(_usdc);
    }

    /// @notice Set cross-chain fees: flat command fee (USDC 6d) and value fee (BPS).
    function setCrossChainFees(uint256 commandFee, uint16 valueFeeBps) external onlyOwner {
        require(commandFee <= MAX_CROSSCHAIN_COMMAND_FEE, "MagnetaGateway: commandFee too high");
        require(valueFeeBps <= MAX_CROSSCHAIN_VALUE_FEE_BPS, "MagnetaGateway: valueFeeBps too high");
        crossChainCommandFee = commandFee;
        crossChainValueFeeBps = valueFeeBps;
        emit CrossChainFeesUpdated(commandFee, valueFeeBps);
    }

    /// @notice Configure Circle CCTP for cross-chain USDC bridging.
    /// @dev Note: localDomain may be 0 (Ethereum mainnet is Circle CCTP domain 0).
    ///      Only the messenger address is required to be non-zero.
    function setCctp(address messenger, uint32 _localDomain) external onlyOwner {
        require(messenger != address(0), "MagnetaGateway: zero messenger");
        cctpMessenger = ITokenMessenger(messenger);
        localCctpDomain = _localDomain;
        emit CctpConfigUpdated(messenger, _localDomain);
    }

    /// @notice Map a destination LZ EID to its CCTP domain.
    function setEidCctpDomain(uint32 eid, uint32 cctpDomain) external onlyOwner {
        eidToCctpDomain[eid] = cctpDomain;
        emit EidCctpDomainSet(eid, cctpDomain);
    }

    /// @notice Batch-set EID → CCTP domain mappings.
    function setEidCctpDomainBatch(
        uint32[] calldata eids,
        uint32[] calldata domains
    ) external onlyOwner {
        if (eids.length != domains.length) revert ArrayLengthMismatch();
        for (uint256 i; i < eids.length; ++i) {
            eidToCctpDomain[eids[i]] = domains[i];
            emit EidCctpDomainSet(eids[i], domains[i]);
        }
    }

    // ─────────────────────────── rescue (MG-1) ───────────────────────────

    /// @notice Owner-only rescue of arbitrary ERC20 stuck in the gateway.
    ///         For the USDC bridged token, the rescue is bounded by
    ///         `totalEarmarked` so it cannot dip into funds reserved for
    ///         pending cross-chain value ops. Other tokens (donations or
    ///         accidental sends) are rescuable in full.
    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "MagnetaGateway: zero to");
        require(amount > 0, "MagnetaGateway: zero amount");
        if (tokenAddr == address(usdc)) {
            uint256 balance = IERC20(tokenAddr).balanceOf(address(this));
            require(balance >= totalEarmarked + amount, "MagnetaGateway: would dip into earmark");
        }
        IERC20(tokenAddr).safeTransfer(to, amount);
        emit Rescued(tokenAddr, to, amount);
    }

    /// @notice Owner-only rescue of native (donated/refunded ETH) — the
    ///         gateway never reads `address(this).balance` for accounting,
    ///         so all native here is rescuable.
    function rescueETH(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "MagnetaGateway: zero to");
        require(amount > 0, "MagnetaGateway: zero amount");
        // onlyOwner + nonReentrant already bound the reentrancy risk. To be
        // strict-CEI compliant (Sentinelle 2026-05-30 SC08 LOW), emit the
        // Rescued event AFTER the require(ok), so a failed call doesn't log
        // an event for a transfer that didn't happen.
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "MagnetaGateway: rescue failed");
        emit Rescued(address(0), to, amount);
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
    ///      valueUsdc6d = 0 for command ops (flat fee × nDestinations); >0 for
    ///      value ops (BPS on aggregate value). Reverts if USDC not configured
    ///      — silent-skip would let an unsetUsdc deployment process all
    ///      cross-chain ops for free (MG-2).
    function _collectCrossChainFee(uint256 valueUsdc6d, uint256 nDestinations) internal {
        require(address(usdc) != address(0), "MagnetaGateway: usdc not set");

        uint256 fee;
        if (valueUsdc6d > 0 && crossChainValueFeeBps > 0) {
            fee = (valueUsdc6d * crossChainValueFeeBps) / 10_000;
        } else if (crossChainCommandFee > 0) {
            // MG-3: command fee is per destination, not flat per call.
            fee = crossChainCommandFee * nDestinations;
        }

        if (fee > 0) {
            usdc.safeTransferFrom(msg.sender, _feeVault, fee);
        }
    }

    /// @notice Owner-only escape hatch for a pending value op that can never
    ///         be fulfilled (e.g. CCTP attestation lost; module misconfigured
    ///         when the op was queued; pre-MG-7 ops with the wrong bridgedToken).
    /// @dev    Clears the pending op and decrements totalEarmarked, freeing
    ///         the corresponding USDC for rescueERC20. Does NOT refund the
    ///         caller directly — the operator is expected to reimburse off-
    ///         chain (or use rescueERC20 to send the USDC back).
    function adminClearPendingValueOp(bytes32 guid) external onlyOwner {
        PendingValueOp memory p = pendingValueOps[guid];
        require(p.bridgedAmount > 0, "MagnetaGateway: no pending op");
        totalEarmarked -= p.bridgedAmount;
        delete pendingValueOps[guid];
        emit ValueOpFulfilled(guid, p.op, p.caller);
    }

    /// @dev Override OAppSender._payNative to relax the default strict
    ///      `msg.value == _nativeFee` to `msg.value >= _nativeFee`. The
    ///      default check is broken for two of our flows:
    ///        1. Fan-out (sendFanOut*Op): the loop calls _lzSend per
    ///           destination. msg.value covers the SUM of all per-leg fees,
    ///           but each leg's _payNative compares the whole msg.value to
    ///           that ONE leg's fee — guaranteed to revert when N > 1 or
    ///           even N == 1 if the SDK quoted from a slightly different
    ///           block (gas oracle drift).
    ///        2. Single-leg value op (sendCrossChainValueOp): the SDK can't
    ///           predict the block-current fee exactly, so any drift between
    ///           quote-time and execute-time reverts the entire tx.
    ///      Accept any over-payment and forward only what's needed; the
    ///      callers already refund the excess at the end (see lines 318,
    ///      381) so no value gets stuck.
    function _payNative(uint256 _nativeFee)
        internal
        override
        returns (uint256 nativeFee)
    {
        if (msg.value < _nativeFee) revert NotEnoughNative(msg.value);
        return _nativeFee;
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
