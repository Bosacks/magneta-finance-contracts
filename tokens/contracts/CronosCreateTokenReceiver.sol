// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
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
contract CronosCreateTokenReceiver is Ownable, ReentrancyGuard, Pausable {
    // ─── EIP-712 ──────────────────────────────────────────────────────────────

    /// @dev Must exactly match lib/relayer/cronosRelayer.ts CREATE_TOKEN_INTENT_TYPES.
    ///      keccak256("CreateTokenIntent(address creator,string template,string name,string symbol,string tokenURI,uint256 totalSupply,uint256 liquidityToBurn,bool revokeUpdate,bool revokeFreeze,bool revokeMint,uint256 destinationChainId,uint256 nonce,uint256 expiry)")
    bytes32 public constant CREATE_INTENT_TYPEHASH =
        0xaf516d335be6edbabf649fddb89d81ac49fb39eec7a5aa554fd4b227fccbda82;

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

    // ─── Storage ──────────────────────────────────────────────────────────────

    /// @notice Local Cronos factory that mints the ERC20 token. Set ONCE at
    ///         construction; the receiver itself must be set as the factory's
    ///         `crossChainCreator` via factory.setCrossChainCreator(this).
    IMagnetaTokenFactory public immutable factory;

    /// @notice Off-chain relayer wallet allowed to submit intents. The relayer
    ///         is GAS-PAYER only — it cannot influence the `creator` field,
    ///         which is bound to the EIP-712 signer. Settable so the Magneta
    ///         Safe can rotate the relayer key without redeploying.
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

    // ─── Errors ───────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotRelayer();
    error UntrustedSource(uint256 sourceChainId, address sourceGateway);
    error IntentReplay(bytes32 digest);
    error IntentExpired(uint256 expiry, uint256 nowTs);
    error WrongDestinationChain(uint256 expected, uint256 actual);
    error BadSignature(address recovered, address creator);
    error UnknownTemplate();

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

        // 4. Expiry guard
        if (intent.expiry < block.timestamp) revert IntentExpired(intent.expiry, block.timestamp);

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
