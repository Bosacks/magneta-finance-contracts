// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title MAGCronosToken
 * @notice Relayer-bridged representation of MAG on Cronos.
 *
 * Why this exists:
 *   Cronos has no LayerZero V2 endpoint, so the protocol MAG OFT cannot peer
 *   with Cronos via the standard cross-chain mesh. This token is the Cronos
 *   leg of the bridge — supply is gated 1:1 by what's locked/escrowed on the
 *   other 18 EVM chains where MAG OFT lives, and bookkeeping happens through
 *   an off-chain relayer the protocol controls.
 *
 * Conservation invariant (INV007):
 *   totalSupply(MAGCronosToken on Cronos)
 *     == sum of MAG escrowed/locked at the bridge sink on every source chain
 *
 *   This is now defended on-chain by three controls (Sentinelle 2026-06-22):
 *     1. Per-message replay protection — each bridged escrow event is consumed
 *        exactly once (`usedMessages`), keyed by the full source identity.
 *     2. An epoch mint cap — bounds the damage a compromised relayer can do
 *        before the Safe reacts (`mintCapPerEpoch`).
 *     3. Pausable mint — the Safe (or a PAUSER) can halt minting instantly
 *        without waiting for a role-revocation tx to land.
 *
 * Trust model:
 *   - MINTER_ROLE granted to the relayer wallet (tracked in `currentRelayer`).
 *   - DEFAULT_ADMIN_ROLE granted to the protocol Safe (rotates relayer,
 *     configures the cap, unpauses).
 *   - PAUSER_ROLE granted to the Safe (and optionally a fast guardian).
 */
contract MAGCronosToken is ERC20, ERC20Burnable, AccessControl, Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Cumulative supply minted by the relayer. Read-only ledger for
    ///         off-chain reconciliation against escrow balances on source chains.
    uint256 public cumulativeMinted;

    /// @notice Replay protection (Sentinelle F-1). Each bridged message is
    ///         consumed exactly once, keyed by the full source identity so the
    ///         same escrow event can never mint twice and distinct events within
    ///         a single source tx remain independent.
    mapping(bytes32 => bool) public usedMessages;

    /// @notice On-chain mint cap (Sentinelle F-2/F36). Set to a real bound at
    ///         deploy (constructor requires > 0). `mintCapPerEpoch == 0` now means
    ///         minting is DISABLED (kill-switch), never uncapped. `epochLength` is
    ///         the rolling window in seconds.
    uint256 public mintCapPerEpoch;
    uint256 public epochLength;
    uint256 public mintedThisEpoch;
    uint256 public epochStart;

    /// @notice The current MINTER relayer (Sentinelle F-5). Rotations revoke the
    ///         tracked relayer rather than a caller-supplied address.
    address public currentRelayer;

    event RelayerMint(address indexed to, uint256 amount, bytes32 indexed messageId, bytes32 sourceTxHash);
    event RelayerRotated(address indexed oldRelayer, address indexed newRelayer);
    event MintCapUpdated(uint256 capPerEpoch, uint256 epochLength);

    constructor(
        address admin,
        address relayer,
        uint256 _mintCapPerEpoch,
        uint256 _epochLength
    ) ERC20("MAG (Cronos bridged)", "MAG-CRO") {
        require(admin != address(0) && relayer != address(0), "MAGCronos: zero address");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, relayer);
        _grantRole(PAUSER_ROLE, admin);
        currentRelayer = relayer;
        // F36: a zero cap used to mean "uncapped" — letting a compromised relayer
        // mint unbounded until the Safe reacted. Require a real bound at deploy.
        require(_mintCapPerEpoch > 0, "MAGCronos: zero cap");
        mintCapPerEpoch = _mintCapPerEpoch;
        epochLength = _epochLength == 0 ? 1 days : _epochLength;
        epochStart = block.timestamp;
    }

    /**
     * @notice Mint freshly-bridged MAG to `to`.
     * @dev    F113: the messageId is keyed ONLY on the immutable source-event
     *         coordinates (chain id, tx hash, log index) — NOT on the
     *         relayer-supplied `to`/`amount`. Otherwise a compromised relayer
     *         could re-key the SAME escrow event with a different to/amount and
     *         mint it again. Each source event is therefore consumable exactly
     *         once. The epoch cap and pause further bound a compromised relayer.
     */
    function relayerMint(
        address to,
        uint256 amount,
        uint256 sourceChainId,
        bytes32 sourceTxHash,
        uint32 logIndex
    ) external onlyRole(MINTER_ROLE) whenNotPaused {
        require(to != address(0), "MAGCronos: mint to zero");

        bytes32 messageId = keccak256(abi.encode(sourceChainId, sourceTxHash, logIndex));
        require(!usedMessages[messageId], "MAGCronos: message already processed");
        usedMessages[messageId] = true;

        _consumeMintCap(amount);

        cumulativeMinted += amount;
        _mint(to, amount);
        emit RelayerMint(to, amount, messageId, sourceTxHash);
    }

    /// @dev Enforces the rolling-epoch mint cap. F36: a zero cap now FAILS CLOSED
    ///      (minting disabled) instead of meaning "uncapped".
    function _consumeMintCap(uint256 amount) internal {
        require(mintCapPerEpoch != 0, "MAGCronos: minting disabled"); // 0 = kill-switch, never uncapped
        if (block.timestamp >= epochStart + epochLength) {
            epochStart = block.timestamp;
            mintedThisEpoch = 0;
        }
        mintedThisEpoch += amount;
        require(mintedThisEpoch <= mintCapPerEpoch, "MAGCronos: epoch mint cap exceeded");
    }

    /// @notice Configure the per-epoch mint cap. Only the admin Safe.
    function setMintCap(uint256 capPerEpoch, uint256 _epochLength)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(_epochLength > 0, "MAGCronos: zero epoch");
        mintCapPerEpoch = capPerEpoch;
        epochLength = _epochLength;
        emit MintCapUpdated(capPerEpoch, _epochLength);
    }

    /**
     * @notice Rotate the relayer wallet. Revokes MINTER_ROLE from the tracked
     *         `currentRelayer` (not a caller-supplied address) and grants it to
     *         `newRelayer`. Only the admin Safe.
     */
    function setRelayer(address newRelayer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRelayer != address(0), "MAGCronos: zero address");
        address old = currentRelayer;
        if (old != address(0)) {
            _revokeRole(MINTER_ROLE, old);
        }
        _grantRole(MINTER_ROLE, newRelayer);
        currentRelayer = newRelayer;
        emit RelayerRotated(old, newRelayer);
    }

    /// @notice Emergency halt of minting. PAUSER (Safe / guardian).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume minting. Admin Safe only.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
