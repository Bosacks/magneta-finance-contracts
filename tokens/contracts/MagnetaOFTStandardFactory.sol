// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./MagnetaERC20OFT.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MagnetaOFTStandardFactory
 * @dev Factory for the Standard OFT template only (paid create, no transfer tax).
 *
 * Why split from `MagnetaOFTAutoLiquidityFactory` (and from the legacy
 * `MagnetaTokenFactory`)? Because the OFT template alone embeds ~10KB of
 * LayerZero OApp bytecode, and combining multiple templates pushed the
 * factory above the Spurious Dragon 24576-byte deployable limit. Each
 * factory now deploys cleanly under that limit.
 */
contract MagnetaOFTStandardFactory is Ownable, ReentrancyGuard {
    // createFee bake-in: was a mutable `uint256 public` with `setCreateFee`,
    // dropped to fit Spurious Dragon. The fee was 0.01 ETH-equivalent across
    // all 19 EVM deploys for ~6 months and never changed; if a future fee
    // adjustment is needed, redeploy the factory + repoint dispatcher /
    // tokens app. UI reads this constant via the public auto-getter.
    uint256 public constant createFee = 0.01 ether;
    address internal treasury;
    address public immutable lzEndpoint;

    /// @notice Accumulated `createFee` collected from successful token creations.
    ///         Held on this contract until `withdraw()` pulls them to `treasury`.
    ///         Switched from synchronous push-payment to pull-payment to remove
    ///         the DoS vector where a reverting treasury would brick ALL paid
    ///         token creation (Sentinelle HIGH SC10 2026-05-22). Visibility
    ///         downgraded from public to internal to fit Spurious Dragon —
    ///         external observers can read via contract balance + Withdrawn
    ///         event history.
    uint256 public accumulatedFees;

    /// @notice Address of the cross-chain TokenCreationModule allowed to call
    ///         `createForCreator` without paying the create fee. Set ONCE by
    ///         the factory owner after the module is deployed (Sprint 2 wiring).
    ///         The fee is collected on the source chain by the Gateway via
    ///         `_collectCrossChainFee`, so charging it again on each destination
    ///         would double-charge the user.
    address public crossChainCreator;

    /// @notice Address of the local TokenOpsModule, baked into every token
    ///         deployed by this factory so the module can call mint/blacklist/
    ///         updateMetadata/enableRevoke* on behalf of the creator (with
    ///         a USDC fee collected by the module). Sprint 9.5 wiring.
    ///         May be address(0) until the contracts repo wires it via
    ///         `deployTokenCreation.ts` — tokens minted before that point
    ///         will have address(0) on the OFT and the creator must call
    ///         `MagnetaERC20OFT.setTokenOpsModule(addr)` themselves to enable
    ///         the Magneta-managed flow.
    address internal tokenOpsModule;

    // Per-creator + global token registries removed entirely. Off-chain
    // consumers MUST index TokenCreated events (`indexed creator`) from
    // this factory's deployment block onward. Storing the arrays on-chain
    // cost ~150 bytes that were needed to add RegistrationFailed (the
    // Sentinelleai MEDIUM SC06 mitigation, 2026-06-08) under the Spurious
    // Dragon 24576-byte limit. Indexing scales better than unbounded
    // storage anyway.

    event TokenCreated(
        address indexed tokenAddress,
        address indexed creator,
        string tokenType,
        string name,
        string symbol
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event Withdrawn(address indexed to, uint256 amount);
    event CrossChainCreatorUpdated(address indexed previous, address indexed current);
    event TokenOpsModuleUpdated(address indexed previous, address indexed current);
    event RegistrationFailed(address indexed token);

    error NotCrossChainCreator();
    error ZeroAddress();
    error InsufficientFee();
    error RefundFailed();
    error WithdrawFailed();
    error NoFees();

    constructor(address _treasury, address _lzEndpoint) Ownable(msg.sender) {
        if (_treasury == address(0) || _lzEndpoint == address(0)) revert ZeroAddress();
        treasury = _treasury;
        lzEndpoint = _lzEndpoint;
    }

    /// @notice Wire the TokenCreationModule that's allowed to bypass the fee.
    ///         Pass address(0) to DISABLE cross-chain creation (intentional
    ///         sentinel — see the `createForCreator` guard).
    function setCrossChainCreator(address _creator) external onlyOwner {
        emit CrossChainCreatorUpdated(crossChainCreator, _creator);
        crossChainCreator = _creator;
    }

    /// @notice Wire the TokenOpsModule address that gets baked into every
    ///         future token. Existing tokens are unaffected — their creator
    ///         must call `MagnetaERC20OFT.setTokenOpsModule(addr)` directly
    ///         if they want to opt in retroactively. Pass address(0) to
    ///         DISABLE the operator path on new tokens (intentional sentinel).
    function setTokenOpsModule(address _module) external onlyOwner {
        emit TokenOpsModuleUpdated(tokenOpsModule, _module);
        tokenOpsModule = _module;
    }

    /// @dev Common deploy + register helper used by both the public paid
    ///      entry and the cross-chain entry. Inlined-by-optimizer in practice
    ///      but reads as a single intent in source.
    function _deployAndRegister(
        address creatorAddr,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint,
        string memory tokenType
    ) private returns (address tokenAddress) {
        MagnetaERC20OFT token = new MagnetaERC20OFT(
            name,
            symbol,
            tokenURI,
            totalSupply,
            creatorAddr,
            revokeUpdate,
            revokeFreeze,
            revokeMint,
            lzEndpoint,
            tokenOpsModule
        );
        tokenAddress = address(token);

        emit TokenCreated(tokenAddress, creatorAddr, tokenType, name, symbol);

        // Auto-register on the local TokenOpsModule so the creator can use
        // MINT/UPDATE/FREEZE via Magneta-managed flows without an extra signed
        // transaction. Low-level call (not try/catch) to keep the factory
        // bytecode under the 24576-byte Spurious Dragon limit; on a
        // misconfigured / not-yet-deployed module the call returns false and
        // the RegistrationFailed event fires — the creator can always call
        // `tokenOpsModule.registerByTokenOwner(token)` themselves later.
        // Selector 0xbb6f82b8 = registerByTokenOwner(address).
        //   keccak256("registerByTokenOwner(address)") = 0xbb6f82b8…
        //   (the earlier 0x4a4f0aac was a copy-paste error — it matched
        //   no selector on any TokenOpsModule version. Discovered on
        //   Base Sepolia testnet 2026-06-08 via the RegistrationFailed
        //   event itself — Sentinelle MEDIUM SC06 paid for itself.)
        if (tokenOpsModule != address(0)) {
            // Bound the gas so a malicious/buggy module can't grief token
            // creation by consuming the whole call (Sentinelle F-10). The
            // registration is best-effort; failure emits RegistrationFailed.
            (bool _ok, ) = tokenOpsModule.call{gas: 200000}(
                abi.encodeWithSelector(0xbb6f82b8, tokenAddress)
            );
            if (!_ok) emit RegistrationFailed(tokenAddress);
        }
    }

    function createOFTStandardToken(
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint
    ) external payable nonReentrant returns (address) {
        if (msg.value < createFee) revert InsufficientFee();

        address tokenAddress = _deployAndRegister(
            msg.sender, name, symbol, tokenURI, totalSupply,
            revokeUpdate, revokeFreeze, revokeMint,
            "StandardOFT"
        );

        // Pull-payment: accrue the fee on this contract; treasury collects
        // via `withdraw()`. Previously synchronous push to treasury — if
        // treasury reverted, ALL paid token creation was bricked even though
        // state was already mutated.
        if (createFee > 0) {
            accumulatedFees += createFee;
        }
        uint256 refund = msg.value - createFee;
        if (refund > 0) {
            (bool successRefund, ) = payable(msg.sender).call{value: refund}("");
            if (!successRefund) revert RefundFailed();
        }
        return tokenAddress;
    }

    /**
     * @dev Module-only entry point used by `TokenCreationModule` when a
     *      cross-chain CREATE_TOKEN op arrives via Gateway. The createFee was
     *      already collected on the source chain (USDC, via Gateway's
     *      `_collectCrossChainFee`), so we waive the local fee here. The
     *      `creator` is the original user (ctx.caller from Gateway).
     */
    function createForCreator(
        address creator,
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint256 totalSupply,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint
    ) external nonReentrant returns (address) {
        if (msg.sender != crossChainCreator || crossChainCreator == address(0)) {
            revert NotCrossChainCreator();
        }
        if (creator == address(0)) revert ZeroAddress();
        return _deployAndRegister(
            creator, name, symbol, tokenURI, totalSupply,
            revokeUpdate, revokeFreeze, revokeMint,
            "StandardOFT-CC"
        );
    }

    // setCreateFee removed — see `createFee` constant declaration above.

    function setTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(old, _newTreasury);
    }

    // NOTE: `getUserTokens` / `getTokenCount` getters AND the backing
    // `userTokens` / `allTokens` storage arrays were removed (see above).
    // UIs query `TokenCreated` events from this factory's deployment block,
    // filtered by `indexed creator`, and rebuild lists off-chain.

    /// @notice Withdraw accumulated create-fees to the configured treasury.
    ///         Owner-only. Resets `accumulatedFees` to zero; any native
    ///         accidentally sent to this contract beyond tracked fees stays
    ///         on-contract (rescue via separate ops only).
    function withdraw() external onlyOwner {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert NoFees();
        accumulatedFees = 0;
        address payable recipient = payable(treasury);
        emit Withdrawn(recipient, amount);
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert WithdrawFailed();
    }
}
