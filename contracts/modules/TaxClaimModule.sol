// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

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
contract TaxClaimModule is IModule, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint16  public constant FEE_BPS = 15;       // 0.15%
    uint256 public minUsdc = 20_000_000;         // $20.00 default threshold (6 decimals)

    address public immutable gateway;
    address public immutable router;
    address public immutable usdc;

    /// @notice Circle CCTP TokenMessenger on this chain (zero-address disables CCTP).
    address public cctpMessenger;

    /// @notice Destination CCTP domain (set per deployment: 0=Eth, 1=Avax, 3=Arb, 6=Base, 7=Polygon).
    uint32  public treasuryDomain;

    /// @notice Magneta treasury mint recipient on the destination domain (bytes32-padded).
    bytes32 public treasuryRecipient;

    /// @notice token => user admin (same semantics as TokenOpsModule.tokenAdmin).
    mapping(address => address) public tokenAdmin;

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

    error OnlyGateway();
    error NotRegistered();
    error NotAdmin();
    error BelowThreshold(uint256 gross);
    error NothingToClaim();

    constructor(address _gateway, address _router, address _usdc) {
        require(_gateway != address(0) && _router != address(0) && _usdc != address(0), "zero address");
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
    ///      fees withdrawn via token.withdrawFees() land here.
    function registerToken(address token, address admin) external {
        require(token != address(0) && admin != address(0), "zero address");
        require(tokenAdmin[token] == address(0), "already registered");
        bool ok = (msg.sender == owner())
            || (IMagnetaManagedTokenTax(token).marketingWallet() == address(this) && msg.sender == admin);
        require(ok, "not authorized");
        tokenAdmin[token] = admin;
        emit TokenRegistered(token, admin);
    }

    function setCctpRoute(address messenger, uint32 domain, bytes32 recipient) external onlyOwner {
        cctpMessenger = messenger;
        treasuryDomain = domain;
        treasuryRecipient = recipient;
        emit CctpRouteSet(messenger, domain, recipient);
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
        ClaimParams memory p = abi.decode(params, (ClaimParams));
        address admin = tokenAdmin[p.token];
        if (admin == address(0)) revert NotRegistered();
        if (ctx.caller != admin) revert NotAdmin();

        // 1. Pull fees out of the token contract (we are its marketingWallet).
        uint256 beforeBal = IERC20(p.token).balanceOf(address(this));
        IMagnetaManagedTokenTax(p.token).withdrawFees();
        uint256 tokensWithdrawn = IERC20(p.token).balanceOf(address(this)) - beforeBal;
        if (tokensWithdrawn == 0) revert NothingToClaim();

        // 2. Swap token → WETH → USDC on the local V2 router.
        IERC20(p.token).forceApprove(router, tokensWithdrawn);
        address[] memory path = new address[](3);
        path[0] = p.token;
        path[1] = IV2RouterSwapper(router).WETH();
        path[2] = usdc;

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        IV2RouterSwapper(router).swapExactTokensForTokens(
            tokensWithdrawn,
            p.amountOutMin,
            path,
            address(this),
            p.deadline
        );
        uint256 usdcGross = IERC20(usdc).balanceOf(address(this)) - usdcBefore;

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
            IERC20(usdc).forceApprove(cctpMessenger, adminNet);
            ICCTPTokenMessenger(cctpMessenger).depositForBurn(
                adminNet,
                treasuryDomain,
                treasuryRecipient,
                usdc
            );
            bridged = true;
        } else {
            IERC20(usdc).safeTransfer(admin, adminNet);
        }

        emit TaxClaimed(p.token, admin, tokensWithdrawn, usdcGross, magnetaFee, adminNet, bridged);
        return abi.encode(tokensWithdrawn, usdcGross, magnetaFee, adminNet, bridged);
    }
}
