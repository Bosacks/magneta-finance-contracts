// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IMagnetaTokenFactory {
    function createStandardForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint
    ) external returns (address);

    function createAutoLiquidityForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        uint256 liquidityToBurn
    ) external returns (address);
}

/// @title CronosCreateTokenReceiver
/// @notice On-chain destination for cross-chain CREATE_TOKEN intents on Cronos.
///         Cronos lacks LayerZero V2, so the Magneta CreateTokenDispatcher
///         pattern (LZ V2 OApp) cannot reach it. Instead, an off-chain Relayer
///         submits EIP-712-signed intents to this contract; the contract
///         verifies the signature on-chain before calling the legacy
///         `MagnetaTokenFactory.createXxxForCreator` entry points.
///
///         **Trust upgrade over the pure-Relayer Sprint 5 flow.** In the
///         original pattern the Relayer wallet WAS the `crossChainCreator` on
///         the factory, so a Relayer-key compromise let an attacker mint
///         tokens with any chosen `creator` address (waste-of-gas attack;
///         no fund theft). With this receiver wired as the `crossChainCreator`
///         instead, a compromised Relayer can only re-broadcast intents that
///         were validly signed by real users — they cannot forge new ones,
///         and replays are blocked by the on-chain processed-hash set.
///
///         The Relayer wallet remains useful: it pays Cronos gas and queues
///         intents off-chain. The Relayer DOES NOT gain any privilege over
///         token issuance beyond submitting valid signed intents.
///
///         **EIP-712 domain note.** Intents are signed against the SOURCE
///         chain's domain (chainId = source, verifyingContract = source
///         Gateway), not Cronos. The receiver reconstructs that domain at
///         verification time and checks (chainId, gateway) against the
///         `trustedSource` whitelist so unknown source chains can't submit
///         arbitrary intents.
///
///         **Receiver/factory binding (Sentinelle audit #14, F-2).** The
///         EIP-712 *domain* is bound to the source chain, not to this
///         contract, so on its own it does nothing to stop a validly-signed
///         intent from being replayed against a DIFFERENT receiver instance
///         (e.g. a v2 receiver deployed during a migration, with its own
///         empty `processedIntents` set). To close that gap the signed
///         *struct* itself carries `destinationReceiver` and
///         `destinationFactory`, which `executeCreate` requires to equal
///         `address(this)` and `address(factory)` — a digest computed for
///         one receiver instance can never validate against another.
///
///         ⚠ BREAKING CHANGE: adding these two fields changes
///         `CREATE_INTENT_TYPEHASH` (see below). Any intent signed under the
///         OLD typehash will no longer recover the right digest and must be
///         re-signed. `lib/relayer/cronosRelayer.ts` (magneta-finance-tokens
///         repo, out of scope for this file) MUST update its
///         `CREATE_TOKEN_INTENT_TYPES` to match before this contract is
///         redeployed, or every relayed intent will revert with
///         `BadSignature`.
///
///         **Known, deliberately-deferred limitations (Sentinelle re-scan
///         #16, F-2/F-4 — documented, not fixed, per that report):**
///         - **Single relayer, not a set.** `relayer` is one address at a
///           time (rotatable via {setRelayer}), not a whitelisted set of
///           gas-payers. A relayer outage stalls all Cronos CREATE_TOKEN
///           intents until the owner rotates it; this is an accepted
///           liveness trade-off, not a fund-safety issue (the relayer holds
///           no minting authority of its own — see the trust-upgrade note
///           above).
///         - **EOA-only signers.** Signature verification uses
///           `ECDSA.recover` (raw ECDSA, EIP-712), not ERC-1271. A creator
///           whose source-chain wallet is a smart-contract wallet / Safe
///           cannot produce a signature this contract will accept. Adding
///           ERC-1271 support is deferred; documented here as an assumed
///           product decision (creators must sign from an EOA).
contract CronosCreateTokenReceiver is Ownable2Step, ReentrancyGuard, Pausable {
    // ─── EIP-712 ──────────────────────────────────────────────────────────────

    /// @dev Must exactly match lib/relayer/cronosRelayer.ts CREATE_TOKEN_INTENT_TYPES.
    ///      ⚠ BREAKING (Sentinelle audit #14, F-2): this typehash changed to
    ///      add `destinationReceiver`/`destinationFactory` — see contract-level
    ///      doc comment above. Old signatures no longer verify.
    ///      (Sentinelle re-scan #16, F-3): expressed as `keccak256(...)` over
    ///      the canonical type string instead of an opaque bytes32 literal,
    ///      so the value is verifiably derived at compile time rather than
    ///      trusted from a comment. This is NOT a value change — the string
    ///      below hashes to the exact same
    ///      0x3a18bf21af8814f022a2d9158fca22f47530fba5c97ac36f8478847033f431eb
    ///      the old literal held (see the regression test asserting this).
    bytes32 public constant CREATE_INTENT_TYPEHASH = keccak256(
        "CreateTokenIntent(address creator,string template,string name,string symbol,string tokenURI,uint256 totalSupply,uint256 liquidityToBurn,bool revokeUpdate,bool revokeFreeze,bool revokeMint,uint256 destinationChainId,address destinationReceiver,address destinationFactory,uint256 nonce,uint256 expiry)"
    );

    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    /// @dev keccak256("MagnetaCronosRelayer") — name field of the domain
    bytes32 internal constant DOMAIN_NAME_HASH = keccak256(bytes("MagnetaCronosRelayer"));
    /// @dev keccak256("1") — version field of the domain
    bytes32 internal constant DOMAIN_VERSION_HASH = keccak256(bytes("1"));

    /// @dev keccak256("standard") + keccak256("autoLiquidity") — string fields
    ///      are encoded as their keccak256 in EIP-712 struct hashes.
    bytes32 internal constant TEMPLATE_STANDARD_HASH      = keccak256(bytes("standard"));
    bytes32 internal constant TEMPLATE_AUTO_LIQUIDITY_HASH = keccak256(bytes("autoLiquidity"));

    /// @notice Maximum remaining lifetime a signed intent may still have AT
    ///         EXECUTION TIME (Sentinelle re-scan #16, F-1). `expiry` is a
    ///         signed field chosen by the creator's frontend, not bounded by
    ///         this contract at signing time — a signer (or a buggy
    ///         frontend) could set `expiry` decades out, and the intent
    ///         would then stay executable indefinitely with no way to
    ///         invalidate it short of {cancelIntent}. This constant caps how
    ///         far in the future `expiry` may still be when `executeCreate`
    ///         runs: `require(intent.expiry <= block.timestamp +
    ///         MAX_INTENT_TTL)`. It bounds the window without requiring a
    ///         new signed field or breaking the typehash.
    uint256 public constant MAX_INTENT_TTL = 30 days;

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @notice Local Cronos factory that mints the ERC20 token. Set ONCE at
    ///         construction; the receiver itself must be set as the factory's
    ///         `crossChainCreator` via factory.setCrossChainCreator(this).
    IMagnetaTokenFactory public immutable factory;

    /// @notice Off-chain relayer wallet allowed to submit intents. The relayer
    ///         is GAS-PAYER only — it cannot influence the `creator` field,
    ///         which is bound to the EIP-712 signer. Settable so the Magneta
    ///         Safe can rotate the relayer key without redeploying.
    ///         (Sentinelle re-scan #16, F-2 — documented, not fixed): this is
    ///         always exactly ONE address, not a whitelisted set. A relayer
    ///         outage stalls all Cronos intent submission until the owner
    ///         calls {setRelayer}; accepted as a liveness trade-off since the
    ///         relayer has no minting authority of its own.
    address public relayer;

    /// @notice Allowed (sourceChainId → sourceGateway) pairs for intent
    ///         signing. A non-zero entry means "we accept intents signed
    ///         against this domain". Owner manages.
    mapping(uint256 => address) public trustedSource;

    /// @notice Intent dedup. Key = the EIP-712 digest (final 32-byte hash).
    ///         Insert-on-execute prevents replay of the same intent.
    mapping(bytes32 => bool) public processedIntents;

    // ─── Events ───────────────────────────────────────────────────────────────

    event RelayerUpdated(address indexed previous, address indexed current);
    event TrustedSourceUpdated(uint256 indexed sourceChainId, address indexed previous, address indexed current);
    event IntentExecuted(
        bytes32 indexed digest,
        address indexed creator,
        address indexed token,
        uint256 sourceChainId,
        uint8 templateKind
    );
    /// @dev Sentinelle re-scan #16, F-1: emitted by {cancelIntent} when a
    ///      creator invalidates their own not-yet-executed intent.
    event IntentCancelled(bytes32 indexed digest, address indexed creator);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotRelayer();
    error UntrustedSource(uint256 sourceChainId, address sourceGateway);
    error IntentReplay(bytes32 digest);
    error IntentExpired(uint256 expiry, uint256 nowTs);
    /// @dev Sentinelle re-scan #16, F-1: `expiry` is further in the future
    ///      than MAX_INTENT_TTL allows, evaluated at execution time.
    error IntentExpiryTooFarInFuture(uint256 expiry, uint256 maxAllowedExpiry);
    /// @dev Sentinelle re-scan #16, F-1: {cancelIntent} caller is not
    ///      `intent.creator`.
    error NotIntentCreator(address caller, address creator);
    error WrongDestinationChain(uint256 expected, uint256 actual);
    /// @dev F-2: intent signed for a different receiver instance (e.g. a
    ///      superseded/migrated deployment) — see contract-level doc comment.
    error WrongDestinationReceiver(address expected, address actual);
    /// @dev F-2: intent signed for a different factory than the one this
    ///      receiver is wired to.
    error WrongDestinationFactory(address expected, address actual);
    error BadSignature(address recovered, address creator);
    error UnknownTemplate();
    /// @dev F-1: `autoLiquidity` tokens (ERC20TokenAutoLiquidity) have no
    ///      revocable update/freeze/mint switches at all — there is no way to
    ///      honour a signed revocation on that template. Rather than silently
    ///      drop a flag the user cryptographically approved (producing an
    ///      on-chain result that diverges from the signed intent), refuse to
    ///      execute intents that assert a non-neutral value.
    error AutoLiquidityRevokeFlagsUnsupported();
    /// @dev F-1: `standard` tokens (ERC20Token) have no liquidity-burn concept;
    ///      `liquidityToBurn` is documented as zero for standard intents but
    ///      was previously accepted-and-ignored. Reject non-zero values so a
    ///      signed-but-unapplied field can never diverge from execution.
    error StandardLiquidityToBurnUnsupported();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _factory, address _relayer, address _owner) Ownable(_owner) {
        if (_factory == address(0) || _relayer == address(0) || _owner == address(0)) revert ZeroAddress();
        factory = IMagnetaTokenFactory(_factory);
        relayer = _relayer;
        emit RelayerUpdated(address(0), _relayer);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setRelayer(address _relayer) external onlyOwner {
        if (_relayer == address(0)) revert ZeroAddress();
        emit RelayerUpdated(relayer, _relayer);
        relayer = _relayer;
    }

    /// @notice Whitelist a source chain. Pass address(0) to revoke.
    function setTrustedSource(uint256 sourceChainId, address sourceGateway) external onlyOwner {
        emit TrustedSourceUpdated(sourceChainId, trustedSource[sourceChainId], sourceGateway);
        trustedSource[sourceChainId] = sourceGateway;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── Intent struct mirrors the off-chain TypeScript shape ────────────────

    struct CreateTokenIntent {
        address creator;
        string  template;          // "standard" | "autoLiquidity"
        string  name;
        string  symbol;
        string  tokenURI;
        uint256 totalSupply;
        uint256 liquidityToBurn;   // 0 for standard
        bool    revokeUpdate;
        bool    revokeFreeze;
        bool    revokeMint;        // ignored for autoLiquidity
        uint256 destinationChainId; // must equal block.chainid (Cronos = 25)
        address destinationReceiver; // F-2: must equal address(this)
        address destinationFactory;  // F-2: must equal address(factory)
        uint256 nonce;
        uint256 expiry;
    }

    // ─── Entry point ──────────────────────────────────────────────────────────

    /// @notice Verify a signed intent and execute the corresponding factory
    ///         call. Only the registered relayer may submit; the relayer pays
    ///         Cronos gas. The token's `creator` is bound to the EIP-712
    ///         signer (verified via ecrecover), not to msg.sender, so a
    ///         compromised relayer cannot mint tokens with attacker-chosen
    ///         creator addresses.
    /// @param sourceChainId  The chain whose domain was used for signing
    /// @param sourceGateway  The MagnetaGateway address used as verifyingContract
    /// @param intent         The signed payload
    /// @param signature      EIP-712 signature (65 bytes r||s||v)
    function executeCreate(
        uint256 sourceChainId,
        address sourceGateway,
        CreateTokenIntent calldata intent,
        bytes calldata signature
    ) external nonReentrant whenNotPaused returns (address token) {
        // 1. Gas-payer guard
        if (msg.sender != relayer) revert NotRelayer();

        // 2. Trusted source guard — only whitelisted (chainId, gateway) pairs
        //    can produce valid intents. Prevents accidental misuse with
        //    arbitrary "fake" source domains.
        address expectedGateway = trustedSource[sourceChainId];
        if (expectedGateway == address(0) || expectedGateway != sourceGateway) {
            revert UntrustedSource(sourceChainId, sourceGateway);
        }

        // 3. Destination chain guard — intent must target Cronos (i.e. us).
        if (intent.destinationChainId != block.chainid) {
            revert WrongDestinationChain(intent.destinationChainId, block.chainid);
        }

        // 3b. Receiver/factory binding guard (F-2). Without this, a digest
        //     computed for THIS receiver's constants would still recover the
        //     same signature if replayed against a different receiver
        //     instance authorized on the same factory (e.g. during a
        //     migration) — processedIntents is per-contract, not global.
        //     Requiring these fields to equal our own address(this)/
        //     address(factory) makes the digest itself instance-specific.
        if (intent.destinationReceiver != address(this)) {
            revert WrongDestinationReceiver(intent.destinationReceiver, address(this));
        }
        if (intent.destinationFactory != address(factory)) {
            revert WrongDestinationFactory(intent.destinationFactory, address(factory));
        }

        // 4. Expiry guard
        if (intent.expiry < block.timestamp) revert IntentExpired(intent.expiry, block.timestamp);

        // 4b. TTL guard (Sentinelle re-scan #16, F-1). Evaluated at EXECUTION
        //     time against `block.timestamp`, not at signing time — bounds
        //     how far in the future an already-signed `expiry` may still be
        //     when a relayer actually submits it, independent of whatever
        //     the signer originally put in that field. Does not require a
        //     new signed field / does not change the typehash.
        if (intent.expiry > block.timestamp + MAX_INTENT_TTL) {
            revert IntentExpiryTooFarInFuture(intent.expiry, block.timestamp + MAX_INTENT_TTL);
        }

        // 5. Compute EIP-712 digest + verify signer
        bytes32 digest = _digest(sourceChainId, sourceGateway, intent);

        // 6. Replay guard — single-use intent
        if (processedIntents[digest]) revert IntentReplay(digest);
        processedIntents[digest] = true;

        address signer = ECDSA.recover(digest, signature);
        if (signer != intent.creator) revert BadSignature(signer, intent.creator);

        // 7. Route to the correct factory entry
        bytes32 templateHash = keccak256(bytes(intent.template));
        uint8 templateKind;
        if (templateHash == TEMPLATE_STANDARD_HASH) {
            templateKind = 0;
            // F-1: `liquidityToBurn` has no meaning for the standard template
            // (ERC20Token has no liquidity-burn step) and was previously
            // accepted-and-silently-ignored. Reject non-zero values instead
            // of letting a signed field diverge from what gets executed.
            if (intent.liquidityToBurn != 0) revert StandardLiquidityToBurnUnsupported();
            token = factory.createStandardForCreator(
                intent.creator,
                intent.name,
                intent.symbol,
                intent.tokenURI,
                intent.totalSupply,
                intent.revokeUpdate,
                intent.revokeFreeze,
                intent.revokeMint
            );
        } else if (templateHash == TEMPLATE_AUTO_LIQUIDITY_HASH) {
            templateKind = 1;
            // F-1: ERC20TokenAutoLiquidity has no revokeUpdate/revokeFreeze/
            // revokeMint concept at all (setTokenURI, pause/unpause, and the
            // absence of a mint function are permanent regardless of these
            // flags). Forwarding none of them to the factory used to mean a
            // user who signed revokeUpdate=true (say) got a token where
            // metadata updates were still possible forever — an on-chain
            // result that silently contradicts the signed intent. Refuse to
            // execute instead.
            if (intent.revokeUpdate || intent.revokeFreeze || intent.revokeMint) {
                revert AutoLiquidityRevokeFlagsUnsupported();
            }
            token = factory.createAutoLiquidityForCreator(
                intent.creator,
                intent.name,
                intent.symbol,
                intent.tokenURI,
                intent.totalSupply,
                intent.liquidityToBurn
            );
        } else {
            revert UnknownTemplate();
        }

        emit IntentExecuted(digest, intent.creator, token, sourceChainId, templateKind);
    }

    /// @notice Let the creator of a signed-but-not-yet-executed intent
    ///         invalidate it (Sentinelle re-scan #16, F-1). Without this, a
    ///         signed intent is executable by the relayer at any point up to
    ///         `expiry` (itself now bounded by {MAX_INTENT_TTL} — see
    ///         {executeCreate}) with no way for the signer to back out, e.g.
    ///         if they change their mind about the token parameters or
    ///         suspect the relayer might submit it maliciously-late.
    ///
    ///         Recomputes the exact same digest {executeCreate} would use —
    ///         `sourceChainId`/`sourceGateway` are NOT part of the signed
    ///         `CreateTokenIntent` struct (they select the EIP-712 domain the
    ///         creator actually signed against, exactly like the
    ///         `executeCreate` parameters of the same name), so both must be
    ///         supplied here to land on the identical `processedIntents` key.
    ///         Marks that digest processed, so a subsequent
    ///         `executeCreate` call for the same intent reverts with
    ///         {IntentReplay} — reusing the existing replay-guard mapping
    ///         rather than adding a parallel "cancelled" set.
    /// @dev No signature is required: msg.sender being intent.creator IS the
    ///      authorization (the creator doesn't need to re-sign anything to
    ///      cancel their own intent, and nobody else can cancel it for them).
    function cancelIntent(
        uint256 sourceChainId,
        address sourceGateway,
        CreateTokenIntent calldata intent
    ) external returns (bytes32 digest) {
        if (msg.sender != intent.creator) revert NotIntentCreator(msg.sender, intent.creator);

        digest = _digest(sourceChainId, sourceGateway, intent);
        if (processedIntents[digest]) revert IntentReplay(digest);
        processedIntents[digest] = true;

        emit IntentCancelled(digest, intent.creator);
    }

    // ─── EIP-712 internals ────────────────────────────────────────────────────

    function _domainSeparator(uint256 sourceChainId, address sourceGateway)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            DOMAIN_NAME_HASH,
            DOMAIN_VERSION_HASH,
            sourceChainId,
            sourceGateway
        ));
    }

    function _structHash(CreateTokenIntent calldata i) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            CREATE_INTENT_TYPEHASH,
            i.creator,
            keccak256(bytes(i.template)),
            keccak256(bytes(i.name)),
            keccak256(bytes(i.symbol)),
            keccak256(bytes(i.tokenURI)),
            i.totalSupply,
            i.liquidityToBurn,
            i.revokeUpdate,
            i.revokeFreeze,
            i.revokeMint,
            i.destinationChainId,
            i.destinationReceiver,
            i.destinationFactory,
            i.nonce,
            i.expiry
        ));
    }

    function _digest(uint256 sourceChainId, address sourceGateway, CreateTokenIntent calldata i)
        internal pure returns (bytes32)
    {
        // EIP-712 final digest: keccak256("\x19\x01" || domainSeparator || structHash).
        // Inlined here because OZ MessageHashUtils requires solc ^0.8.24 and
        // this contract targets 0.8.20 to match the rest of the codebase.
        return keccak256(abi.encodePacked(
            "\x19\x01",
            _domainSeparator(sourceChainId, sourceGateway),
            _structHash(i)
        ));
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /// @notice Recompute the EIP-712 digest for a candidate intent without
    ///         executing it. Useful for off-chain pre-validation and for
    ///         frontends that want to display the hash before signing.
    function digestOf(uint256 sourceChainId, address sourceGateway, CreateTokenIntent calldata i)
        external pure returns (bytes32)
    {
        return _digest(sourceChainId, sourceGateway, i);
    }
}
