// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal view of the TokenOps registry, used so the registration call
///      is built from a compiler-checked selector instead of a hand-written
///      literal (report-17 F-6). Declared inline for the same
///      bytecode-budget reason as IMagnetaOFTTokenDeployer below.
interface ITokenOpsRegister {
    function registerByTokenOwner(address token) external;
}

/// @dev Declared inline rather than imported from MagnetaOFTTokenDeployer.sol
///      on purpose: importing that file would drag MagnetaERC20OFT's creation
///      code back into this factory's bytecode, which is the exact weight the
///      split exists to remove.
interface IMagnetaOFTTokenDeployer {
    /// @notice The one factory this deployer will accept calls from. Used by
    ///         {MagnetaOFTStandardFactory-setTokenDeployer} to prove the
    ///         deployer is bound to THIS factory before latching it forever
    ///         (report-17 F-4).
    function factory() external view returns (address);

    function deployToken(
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        uint256 totalSupply_,
        address initialOwner,
        bool revokeUpdate,
        bool revokeFreeze,
        bool revokeMint,
        address lzEndpoint,
        address tokenOpsModule
    ) external returns (address);
}

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
/// @dev Ownable2Step (report-17 F-8): ownership moves to a multisig/timelock
///      on every chain, and a single-step transfer to a mistyped address
///      would strand `withdraw()` and every future module/deployer setter
///      with no recovery. The destination must now call acceptOwnership().
contract MagnetaOFTStandardFactory is Ownable2Step, ReentrancyGuard {
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

    /// @notice Contract that actually runs `new MagnetaERC20OFT(...)`.
    ///         See MagnetaOFTTokenDeployer for why the deployment lives
    ///         outside this factory. Wired once after both contracts exist
    ///         (they reference each other), then frozen: re-pointing it would
    ///         let a swapped-in deployer issue a different token behind the
    ///         same factory address the frontend trusts.
    address public tokenDeployer;

    event TokenDeployerSet(address indexed deployer);

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
    error DeployerAlreadySet();
    error DeployerNotSet();
    /// @dev report-17 F-4 — candidate deployer has no code.
    error DeployerNotContract();
    /// @dev report-17 F-4 — candidate deployer is bound to another factory.
    error DeployerFactoryMismatch();

    /// @notice Gas forwarded to the best-effort TokenOps registration call.
    ///         Bounded so a malicious or buggy module cannot grief token
    ///         creation by consuming the entire call (report-17 F-7 asked for
    ///         a named, documented budget rather than a magic number).
    ///         Measured worst case for registerByTokenOwner across supported
    ///         TokenOpsModule versions is ~60k (one SLOAD-guard, one external
    ///         owner() call, one SSTORE, two events); 200k leaves >3x headroom
    ///         for gas repricing. Registration failure never blocks creation —
    ///         it emits RegistrationFailed for off-chain retry.
    uint256 private constant REGISTRATION_GAS_BUDGET = 200000;

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

    /// @notice Wire the MagnetaOFTTokenDeployer. Settable exactly once —
    ///         the frontend trusts this factory address, so an owner able to
    ///         swap the deployer later could silently change what users
    ///         actually receive when they pay the create fee.
    ///         report-17 F-4: because the setter is one-way, a wrong address
    ///         here is unrecoverable — it would revert every future paid and
    ///         cross-chain creation with no way to correct it short of
    ///         redeploying the factory and rewiring every integration. So the
    ///         candidate must prove it is a real deployer bound to THIS
    ///         factory before the address is latched: it must carry code, and
    ///         its immutable `factory()` must equal address(this). An EOA, an
    ///         unrelated contract, or a deployer wired to another factory now
    ///         reverts instead of bricking creation.
    function setTokenDeployer(address _deployer) external onlyOwner {
        if (_deployer == address(0)) revert ZeroAddress();
        if (tokenDeployer != address(0)) revert DeployerAlreadySet();
        if (_deployer.code.length == 0) revert DeployerNotContract();
        if (IMagnetaOFTTokenDeployer(_deployer).factory() != address(this)) {
            revert DeployerFactoryMismatch();
        }
        tokenDeployer = _deployer;
        emit TokenDeployerSet(_deployer);
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
        // Deployment is delegated so this factory does not carry
        // MagnetaERC20OFT's creation code (see MagnetaOFTTokenDeployer).
        address deployer_ = tokenDeployer;
        if (deployer_ == address(0)) revert DeployerNotSet();

        tokenAddress = IMagnetaOFTTokenDeployer(deployer_).deployToken(
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
        address ops = tokenOpsModule;
        if (ops != address(0)) {
            // report-17 F-5: a raw call to an address with NO code returns
            // success==true, so an EOA or not-yet-deployed module used to be
            // reported as a successful registration and the token shipped
            // silently unregistered. Treat "no code" as a failure explicitly.
            if (ops.code.length == 0) {
                emit RegistrationFailed(tokenAddress);
            } else {
                // Bound the gas so a malicious/buggy module can't grief token
                // creation by consuming the whole call (Sentinelle F-10). The
                // registration is best-effort; failure emits RegistrationFailed.
                // report-17 F-6: selector comes from the interface, so a rename
                // breaks the build instead of silently failing on-chain.
                // report-17 F-7: budget is a named constant, documented below.
                (bool _ok, ) = ops.call{gas: REGISTRATION_GAS_BUDGET}(
                    abi.encodeCall(ITokenOpsRegister.registerByTokenOwner, (tokenAddress))
                );
                if (!_ok) emit RegistrationFailed(tokenAddress);
            }
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
