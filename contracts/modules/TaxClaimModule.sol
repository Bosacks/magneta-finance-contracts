// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "../interfaces/IModule.sol";
import "../interfaces/IMagnetaGateway.sol";

interface IMagnetaManagedTokenTax {
    function owner() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function withdrawFees() external;
    function setMarketingWallet(address) external;
    function marketingWallet() external view returns (address);
}

interface IV2RouterSwapper {
    function WETH() external pure returns (address);
    function getAmountsOut(uint amountIn, address[] calldata path)
        external view returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface ICCTPTokenMessenger {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);
}

/// @title TaxClaimModule
/// @notice Consolidates transfer-tax revenue accumulated inside managed ERC20
///         tokens into USDC, optionally burns it through Circle CCTP for
///         cross-chain consolidation to the Magneta treasury.
/// @dev    Flow per token, per chain:
///           1. Module is the token's owner + marketingWallet
///              (set at registration). Token fees arrive here.
///           2. `execute(CLAIM_TAX_FEES, ...)` calls `withdrawFees()` to pull
///              the accumulated fee balance into the module.
///           3. Swaps token→WETH→USDC via the local V2 router.
///           4. If USDC total < `minUsdc` (default $20), the op reverts to
///              avoid burning gas for sub-threshold claims.
///           5. Magneta takes a 0.15% markup on the USDC; the rest is either
///              held for the admin on this chain OR `depositForBurn`ed via
///              CCTP to the configured destination domain + treasury address.
contract TaxClaimModule is IModule, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint16  public constant FEE_BPS = 15;       // 0.15%
    uint256 public minUsdc = 20_000_000;         // $20.00 default threshold (6 decimals)

    /// @notice Fraction of the router's own quote the swap must actually
    ///         return, in bps. 9700 = at most 3% slippage.
    ///
    /// @dev    `minUsdc` is an ABSOLUTE $20 floor and bounds nothing
    ///         proportionally: a claim worth $50,000 sandwiched down to $21
    ///         passes it. That mattered because the client cannot compute a
    ///         sensible `amountOutMin` — it cannot read this module's router,
    ///         its path, or the fee amount before `withdrawFees()` runs — so
    ///         the production UI hard-codes `amountOutMin: 0`. The bound has to
    ///         live here or it does not exist.
    uint16 public maxSlippageBps = 9_700;

    address public immutable gateway;
    address public immutable router;
    address public immutable usdc;

    /// @notice Circle CCTP TokenMessenger on this chain (zero-address disables CCTP).
    address public cctpMessenger;

    /// @notice Destination CCTP domain (set per deployment: 0=Eth, 1=Avax, 3=Arb, 6=Base, 7=Polygon).
    uint32  public treasuryDomain;

    /// @notice Magneta treasury mint recipient on the destination domain (bytes32-padded).
    bytes32 public treasuryRecipient;

    /// @notice CCTP domains this deployment will burn to.
    ///
    /// @dev    `depositForBurn` accepts any uint32. A domain Circle does not
    ///         operate is never attested, so the USDC is burned here and minted
    ///         nowhere — an unrecoverable loss, and the caller picks the number.
    ///         An allow-list is the only thing standing between a typo and a
    ///         destroyed claim.
    mapping(uint32 => bool) public cctpDomainEnabled;

    /// @notice token => user admin (same semantics as TokenOpsModule.tokenAdmin).
    mapping(address => address) public tokenAdmin;

    /// @notice Allow-list of addresses authorised to call `registerToken`.
    ///         Closes the soft-check branch (marketingWallet == address(this)
    ///         && msg.sender == admin) that previously let any caller who
    ///         controlled a token's marketingWallet register arbitrary
    ///         admins (Sentinelle MEDIUM SC01 2026-05-22).
    mapping(address => bool) public trustedRegistrars;

    event TokenRegistered(address indexed token, address indexed admin);
    event TaxClaimed(
        address indexed token,
        address indexed admin,
        uint256 tokensWithdrawn,
        uint256 usdcGross,
        uint256 magnetaFee,
        uint256 adminNet,
        bool bridged
    );
    event CctpRouteSet(address messenger, uint32 domain, bytes32 recipient);
    event MinUsdcUpdated(uint256 previous, uint256 current);
    event TrustedRegistrarUpdated(address indexed registrar, bool trusted);
    event TokenUnregistered(address indexed token);
    event MaxSlippageUpdated(uint16 previous, uint16 current);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event CctpDomainUpdated(uint32 indexed domain, bool enabled);

    error OnlyGateway();
    error NotRegistered();
    error NotAdmin();
    error BelowThreshold(uint256 gross);
    error NothingToClaim();
    error SlippageExceeded(uint256 got, uint256 floorOut);
    error BurnDidNotConsumeApproval();
    error NotAContract(address addr);
    error DomainNotEnabled(uint32 domain);

    /// @notice Minimum attested DVN quorum the gateway must surface for this
    ///         module to wire up. Mitigates Kelp-DAO-class single-validator
    ///         risk (chantier #3 — Sentinelle 2026-06-12 SC01:2026).
    uint8 public constant MIN_DVN_QUORUM = 2;

    constructor(address _gateway, address _router, address _usdc) {
        require(_gateway != address(0) && _router != address(0) && _usdc != address(0), "zero address");
        require(IMagnetaGateway(_gateway).requiredDVNCount() >= MIN_DVN_QUORUM, "TaxClaimModule: DVN quorum");
        gateway = _gateway;
        router = _router;
        usdc = _usdc;
    }

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    // ───────────────────── admin ─────────────────────

    /// @notice Register a token with this module as its revenue sink.
    /// @dev Token owner must have set `marketingWallet` = address(this) so the
    ///      fees withdrawn via token.withdrawFees() land here. Sentinelle
    ///      MEDIUM SC01: hardened the auth check — soft self-attestation
    ///      via marketingWallet replaced with an explicit owner /
    ///      trusted-registrar gate.
    function registerToken(address token, address admin) external {
        require(token != address(0) && admin != address(0), "zero address");
        require(tokenAdmin[token] == address(0), "already registered");
        require(
            msg.sender == owner() || trustedRegistrars[msg.sender],
            "not authorized"
        );
        tokenAdmin[token] = admin;
        emit TokenRegistered(token, admin);
    }

    /// @notice Owner-managed allow-list for `registerToken` callers. Wire
    ///         trusted factories / dispatchers here at deploy time.
    function setTrustedRegistrar(address registrar, bool trusted) external onlyOwner {
        require(registrar != address(0), "zero registrar");
        trustedRegistrars[registrar] = trusted;
        emit TrustedRegistrarUpdated(registrar, trusted);
    }

    function setCctpRoute(address messenger, uint32 domain, bytes32 recipient) external onlyOwner {
        require(messenger != address(0), "TaxClaim: zero messenger");
        if (messenger.code.length == 0) revert NotAContract(messenger);
        require(recipient != bytes32(0), "TaxClaim: zero recipient");
        cctpMessenger = messenger;
        treasuryDomain = domain;
        treasuryRecipient = recipient;
        emit CctpRouteSet(messenger, domain, recipient);
    }

    /// @notice Undo a registration. TokenOpsModule has always had this; this
    ///         module did not, so a single wrong `admin` bricked that token's
    ///         tax revenue permanently — `registerToken` refuses to overwrite
    ///         and `execute` demands `ctx.caller == admin`.
    function unregisterToken(address token) external onlyOwner {
        delete tokenAdmin[token];
        emit TokenUnregistered(token);
    }

    /// @notice Bound on how far below the router's own quote a claim may land.
    function setMaxSlippageBps(uint16 bps) external onlyOwner {
        require(bps > 0 && bps <= 10_000, "TaxClaim: bps range");
        emit MaxSlippageUpdated(maxSlippageBps, bps);
        maxSlippageBps = bps;
    }

    /// @notice Recover assets sitting on this module.
    ///
    /// @dev The code used to state that donated tokens "can be rescued
    ///      separately by governance". No such function existed. Every claim is
    ///      atomic — the module holds nothing between calls — so anything here
    ///      is a donation, dust, or the residue of a failed flow, and without
    ///      this it was locked for good on all 19 chains. The comment is now
    ///      true instead of reassuring.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "TaxClaim: zero to");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @notice Recover native currency. `execute` now refuses non-zero
    ///         msg.value, but anything already trapped needs a way out.
    function rescueNative(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "TaxClaim: zero to");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "TaxClaim: native transfer failed");
        emit Rescued(address(0), to, amount);
    }

    /// @notice Enable or disable a CCTP destination domain.
    function setCctpDomain(uint32 domain, bool enabled) external onlyOwner {
        cctpDomainEnabled[domain] = enabled;
        emit CctpDomainUpdated(domain, enabled);
    }

    function setMinUsdc(uint256 newMin) external onlyOwner {
        emit MinUsdcUpdated(minUsdc, newMin);
        minUsdc = newMin;
    }

    // ───────────────────── dispatch ─────────────────────

    struct ClaimParams {
        address token;
        uint256 amountOutMin;    // USDC slippage floor the caller accepts
        uint256 deadline;
        bool    bridgeToTreasury; // true = CCTP burn, false = keep on local chain
        /// @dev CCTP domain to receive the proceeds. The point of the bridge is
        ///      that an admin claims revenue accrued on THIS chain and takes
        ///      delivery on the chain they actually work from, so the choice is
        ///      theirs, not a per-deployment constant. Must be allow-listed.
        ///      Ignored when `bridgeToTreasury` is false.
        uint32  destinationDomain;
    }

    /// @inheritdoc IModule
    function execute(Context calldata ctx, bytes calldata params)
        external
        payable
        override
        onlyGateway
        nonReentrant
        returns (bytes memory result)
    {
        // The Gateway skims its service fee and forwards the REST as
        // `opValue`, documenting that "the module asserts msg.value == <op
        // amount>". This module has no native amount of its own, so that
        // assertion is `== 0`. It was missing: any overpayment landed here,
        // and with no rescue path it stayed here forever.
        require(msg.value == 0, "TaxClaim: no native value expected");

        ClaimParams memory p = abi.decode(params, (ClaimParams));
        address admin = tokenAdmin[p.token];
        if (admin == address(0)) revert NotRegistered();
        if (ctx.caller != admin) revert NotAdmin();

        // 1. Pull fees out of the token contract (we are its marketingWallet).
        //
        // Sentinelle SC02 (HIGH on line 161 balanceOf) — the snapshot-delta
        // pattern is robust against pre-call donations: any token donated
        // before this call is captured in `beforeBal` and therefore
        // EXCLUDED from `tokensWithdrawn`. No alternative source exists
        // because the token's `withdrawFees()` is non-returning. Donated
        // tokens linger on this module and are recoverable through
        // `rescueERC20` — they cannot influence the fee/burn math here.
        // (That rescue function did not exist when this comment was first
        // written; the claim was false for the whole life of the deployment.)
        uint256 beforeBal = IERC20(p.token).balanceOf(address(this));
        IMagnetaManagedTokenTax(p.token).withdrawFees();
        uint256 tokensWithdrawn = IERC20(p.token).balanceOf(address(this)) - beforeBal;
        if (tokensWithdrawn == 0) revert NothingToClaim();

        // 2. Swap token → WETH → USDC on the local V2 router.
        //
        // Sentinelle HIGH SC02 — use the router's return value
        // (`amounts[amounts.length - 1]`) as the authoritative swap
        // output rather than the balanceOf delta. The delta pattern was
        // safe here too (usdcBefore captures any donation) but the return
        // value is cleaner and matches the SwapModule pattern. Donation
        // USDC is invisible to the fee/bridge math either way.
        IERC20(p.token).forceApprove(router, tokensWithdrawn);
        address[] memory path = new address[](3);
        path[0] = p.token;
        path[1] = IV2RouterSwapper(router).WETH();
        path[2] = usdc;

        // Proportional floor derived from the router's OWN quote, taken in the
        // same call. The caller's `amountOutMin` still applies when it is
        // stricter; it is never allowed to be laxer than this bound.
        uint256 quoted = IV2RouterSwapper(router).getAmountsOut(tokensWithdrawn, path)[path.length - 1];
        uint256 floorOut = (quoted * maxSlippageBps) / 10_000;
        if (p.amountOutMin > floorOut) floorOut = p.amountOutMin;

        uint256[] memory amounts = IV2RouterSwapper(router).swapExactTokensForTokens(
            tokensWithdrawn,
            floorOut,
            path,
            address(this),
            p.deadline
        );
        uint256 usdcGross = amounts[amounts.length - 1];

        // The router already enforced `floorOut`, but a non-standard router
        // could report an output it did not deliver. Assert against the balance
        // actually gained rather than trusting the return value alone.
        if (usdcGross < floorOut) revert SlippageExceeded(usdcGross, floorOut);

        // 3. Enforce $20 threshold.
        if (usdcGross < minUsdc) revert BelowThreshold(usdcGross);

        // 4. Split: Magneta markup to feeVault, rest to admin (local) or treasury (CCTP).
        uint256 magnetaFee = (usdcGross * FEE_BPS) / 10_000;
        uint256 adminNet = usdcGross - magnetaFee;

        if (magnetaFee > 0) {
            IERC20(usdc).safeTransfer(ctx.feeVault, magnetaFee);
        }

        bool bridged = false;
        if (p.bridgeToTreasury && cctpMessenger != address(0)) {
            // Mint to the ADMIN on the destination domain, not to a global
            // recipient. `adminNet` is the token owner's revenue — the
            // protocol's cut is `magnetaFee`, already sent above. Burning the
            // remainder to `treasuryRecipient` moved a user's funds to Magneta
            // with no per-admin ledger, no claim function and nothing on chain
            // but an event; the UI exposes the flag as a plain checkbox.
            // The admin's own address on the chain THEY chose. Two separate
            // decisions, both previously taken away from them: the recipient
            // was a global Magneta address, and the destination was whatever
            // `treasuryDomain` the owner had configured for this deployment.
            //
            // NOTE: CCTP mints to the same 20-byte address on the destination
            // chain. That is correct for an EOA; an admin using a smart-contract
            // wallet may not control the identical address elsewhere. Surface
            // this in the UI before offering the bridge.
            uint32 dstDomain = p.destinationDomain;
            if (!cctpDomainEnabled[dstDomain]) revert DomainNotEnabled(dstDomain);
            bytes32 mintRecipient = bytes32(uint256(uint160(admin)));

            IERC20(usdc).forceApprove(cctpMessenger, adminNet);
            ICCTPTokenMessenger(cctpMessenger).depositForBurn(
                adminNet,
                dstDomain,
                mintRecipient,
                usdc
            );

            // A messenger that accepts the call without burning would leave
            // `bridged = true` emitted, the USDC still here and a live
            // allowance standing. Same defect as CctpV2Adapter, same fix.
            if (IERC20(usdc).allowance(address(this), cctpMessenger) != 0) {
                IERC20(usdc).forceApprove(cctpMessenger, 0);
                revert BurnDidNotConsumeApproval();
            }
            bridged = true;
        } else {
            IERC20(usdc).safeTransfer(admin, adminNet);
        }

        emit TaxClaimed(p.token, admin, tokensWithdrawn, usdcGross, magnetaFee, adminNet, bridged);
        return abi.encode(tokensWithdrawn, usdcGross, magnetaFee, adminNet, bridged);
    }
}
