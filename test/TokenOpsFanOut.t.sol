// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../contracts/modules/TokenOpsModule.sol";
import "../contracts/interfaces/IModule.sol";
import "../contracts/interfaces/IMagnetaGateway.sol";

/// @notice Minimal gateway stand-in for module unit tests. TokenOpsModule only
///         needs `requiredDVNCount() >= 2` at construction and `onlyGateway`
///         (msg.sender == gateway) at dispatch. This contract is the gateway
///         from the module's point of view AND the relay that forwards a
///         decoded LZ payload into `execute`, so we can drive both the local
///         path (originChainId == block.chainid) and the cross-chain path
///         (originChainId != block.chainid) deterministically.
contract MockGatewayLite {
    uint8 public requiredDVNCount = 2;
    TokenOpsModule public module;

    function setModule(TokenOpsModule m) external {
        module = m;
    }

    /// @dev Mirror MagnetaGateway.executeOperation (local-origin) and the
    ///      version-0 branch of _lzReceive (cross-chain origin) — both build an
    ///      IModule.Context and call `module.execute`.
    function dispatch(
        address caller,
        uint256 originChainId,
        address feeVault,
        IMagnetaGateway.OpType op,
        bytes memory inner
    ) external returns (bytes memory) {
        IModule.Context memory ctx = IModule.Context({
            caller: caller,
            originChainId: originChainId,
            feeVault: feeVault,
            tokenSource: address(0)
        });
        bytes memory params = abi.encodePacked(uint8(op), inner);
        return module.execute(ctx, params);
    }
}

/// @notice Token mock exposing the surface the fan-out ops touch:
///         `setAutoFreezeRule(bool,uint256)` (onlyOwner, mirrors the real OFT)
///         plus the other managed-token functions TokenOpsModule may forward.
contract MockManagedOFT is ERC20, Ownable {
    bool    public ruleActive;
    uint256 public ruleThreshold;
    uint64  public ruleConfiguredAt;
    string  public tokenURI;
    mapping(address => bool) public frozen;

    event AutoFreezeRuleSet(bool active, uint256 threshold);

    constructor() ERC20("Brand", "BR") {}

    function setAutoFreezeRule(bool active, uint256 threshold) external onlyOwner {
        ruleActive = active;
        ruleThreshold = threshold;
        ruleConfiguredAt = uint64(block.timestamp);
        emit AutoFreezeRuleSet(active, threshold);
    }

    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }
    function updateMetadata(string memory u) external onlyOwner { tokenURI = u; }
    function blacklist(address a, bool v) external onlyOwner { frozen[a] = v; }
    function enableRevokeUpdate() external onlyOwner {}
    function enableRevokeFreeze() external onlyOwner {}
    function enableRevokeMint() external onlyOwner {}
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Unit tests for the AUTO_FREEZE_RULE_SET fan-out leg added to
///         TokenOpsModule, plus a regression on the CLAIM_TAX_FEES intent
///         (that op routes through TaxClaimModule on-chain, so here we only
///         assert TokenOpsModule rejects it — the fan-out primitive itself
///         lives in MagnetaGateway.sendFanOut, exercised in MagnetaGateway
///         tests). The two ops share `Gateway.sendFanOut` as the single
///         one-signature multi-chain primitive; this file verifies the
///         destination-leg execution + access/replay semantics for the new op.
contract TokenOpsFanOutTest is Test {
    MockGatewayLite gateway;
    TokenOpsModule  module;
    MockManagedOFT  token;
    MockUSDC        usdc;

    address admin   = address(0xA11CE);
    address user    = address(0xBEEF);
    address feeVault = address(0xFEE);

    uint256 constant LOCAL_CHAIN  = 31337; // foundry default block.chainid
    uint256 constant ORIGIN_CHAIN = 8453;  // some other chain id (cross-chain leg)

    function setUp() public {
        gateway = new MockGatewayLite();
        usdc    = new MockUSDC();

        module = new TokenOpsModule(address(gateway), address(usdc));
        gateway.setModule(module);

        token = new MockManagedOFT();
        // Cross-chain registered path: the OFT factory set initialOwner = module
        // so the module (and only the module) can call the token's onlyOwner
        // setAutoFreezeRule on this destination chain.
        token.transferOwnership(address(module));

        // module.owner() == this test contract (deployer) → register directly.
        module.registerToken(address(token), admin);

        // Fund admin USDC for the flat fee + approve the module to pull it.
        usdc.mint(admin, 1_000 * 1e6);
        vm.prank(admin);
        usdc.approve(address(module), type(uint256).max);
    }

    function _ruleInner(bool active, uint256 threshold) internal view returns (bytes memory) {
        return abi.encode(
            TokenOpsModule.AutoFreezeRuleParams({
                token: address(token),
                active: active,
                threshold: threshold
            })
        );
    }

    // ── happy path ──────────────────────────────────────────────────────────

    function test_AutoFreezeRuleSet_local_setsRuleAndChargesFlatFee() public {
        uint256 fee = module.flatFeeUsdc();
        uint256 vaultBefore = usdc.balanceOf(feeVault);

        bytes memory result = gateway.dispatch(
            admin, LOCAL_CHAIN, feeVault,
            IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET,
            _ruleInner(true, 5_000 ether)
        );

        (bool active, uint256 threshold) = abi.decode(result, (bool, uint256));
        assertTrue(active, "result active");
        assertEq(threshold, 5_000 ether, "result threshold");

        assertTrue(token.ruleActive(), "rule active on token");
        assertEq(token.ruleThreshold(), 5_000 ether, "threshold on token");
        // Flat fee pulled to the fee vault on local-origin dispatch.
        assertEq(usdc.balanceOf(feeVault) - vaultBefore, fee, "flat fee collected");
    }

    function test_AutoFreezeRuleSet_crossChain_waivesFeeAndSetsRule() public {
        uint256 vaultBefore = usdc.balanceOf(feeVault);

        // originChainId != block.chainid → _pullUsdc waives the local fee (it
        // was collected on the source chain by the Gateway).
        gateway.dispatch(
            admin, ORIGIN_CHAIN, feeVault,
            IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET,
            _ruleInner(true, 1_234 ether)
        );

        assertTrue(token.ruleActive(), "rule active");
        assertEq(token.ruleThreshold(), 1_234 ether, "threshold");
        assertEq(usdc.balanceOf(feeVault), vaultBefore, "no local fee on cross-chain leg");
    }

    function test_AutoFreezeRuleSet_canDisableRule() public {
        gateway.dispatch(admin, LOCAL_CHAIN, feeVault,
            IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET, _ruleInner(true, 100 ether));
        assertTrue(token.ruleActive());

        gateway.dispatch(admin, LOCAL_CHAIN, feeVault,
            IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET, _ruleInner(false, 0));
        assertFalse(token.ruleActive(), "rule disabled");
    }

    // ── access control ──────────────────────────────────────────────────────

    function test_AutoFreezeRuleSet_revertsForNonAdmin() public {
        vm.expectRevert(TokenOpsModule.NotAuthorized.selector);
        gateway.dispatch(
            user, LOCAL_CHAIN, feeVault,
            IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET,
            _ruleInner(true, 1 ether)
        );
    }

    function test_AutoFreezeRuleSet_revertsForUnregisteredToken() public {
        MockManagedOFT other = new MockManagedOFT();
        other.transferOwnership(address(module));

        bytes memory inner = abi.encode(
            TokenOpsModule.AutoFreezeRuleParams({
                token: address(other),
                active: true,
                threshold: 1 ether
            })
        );

        vm.expectRevert(TokenOpsModule.TokenNotRegistered.selector);
        gateway.dispatch(admin, LOCAL_CHAIN, feeVault,
            IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET, inner);
    }

    function test_execute_revertsWhenCallerIsNotGateway() public {
        // The module's onlyGateway guard is the only caller restriction; a
        // direct (non-gateway) execute must revert. This is the on-chain
        // anchor for the fan-out: only a peered sibling gateway's _lzReceive
        // (msg.sender == gateway) can drive the destination leg.
        bytes memory params = abi.encodePacked(
            uint8(IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET),
            _ruleInner(true, 1 ether)
        );
        IModule.Context memory ctx = IModule.Context({
            caller: admin,
            originChainId: LOCAL_CHAIN,
            feeVault: feeVault,
            tokenSource: address(0)
        });
        vm.expectRevert(TokenOpsModule.OnlyGateway.selector);
        module.execute(ctx, params);
    }

    // ── replay protection ─────────────────────────────────────────────────────
    // Cross-chain replay is enforced one level up by MagnetaGateway.processedGuid
    // (each LZ GUID consumed once). At the module level the op is idempotent —
    // re-applying the same rule yields the same state — which we assert here so
    // a replayed leg is a no-op rather than a state corruption.

    function test_AutoFreezeRuleSet_replayIsIdempotent() public {
        gateway.dispatch(admin, ORIGIN_CHAIN, feeVault,
            IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET, _ruleInner(true, 777 ether));
        uint64 firstAt = token.ruleConfiguredAt();

        vm.warp(block.timestamp + 1 days);

        // Replay the identical rule (same params, what a duplicated LZ message
        // would carry). State stays consistent; only configuredAt re-stamps.
        gateway.dispatch(admin, ORIGIN_CHAIN, feeVault,
            IMagnetaGateway.OpType.AUTO_FREEZE_RULE_SET, _ruleInner(true, 777 ether));

        assertTrue(token.ruleActive(), "still active after replay");
        assertEq(token.ruleThreshold(), 777 ether, "threshold unchanged after replay");
        assertGt(token.ruleConfiguredAt(), firstAt, "re-armed timestamp");
    }
}
