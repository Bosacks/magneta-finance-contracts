# Deployment Hardening Plan

Pre-deployment checklist for moving admin control from a hot deployer EOA to a hardened 2-layer model:

```
┌─────────────────────────┐      48h queue       ┌────────────────────┐
│  Gnosis Safe (3/5)      │ ───────────────────▶ │ TimelockController │ ──▶ Contract.setX()
│  Signers = founders     │   schedule/execute   │   48h delay        │
└─────────────────────────┘                      └────────────────────┘
         │ (fast path for pause only)
         ▼
   PauseGuardian EOA  ──▶  Contract.pause()
```

## Admin functions — classification

### Class A — CRITICAL (Safe → Timelock 48h)
Any of these can drain or redirect funds. MUST go through Safe + Timelock.

| Contract | Function | Risk |
|---|---|---|
| `MagnetaBundler` | `setRouter`, `rescueTokens`, `rescueETH` | Redirect swaps / drain |
| `MagnetaGateway` | `setModule`, `setFeeVault`, `setUsdc`, `setCctp`, `setCrossChainFees`, `setEidCctpDomain`, `setEidMapping` | Swap business logic / redirect fees / break CCTP routing |
| `MagnetaLending` | `setPriceFeed`, `addAsset`, `setLTV` | Mispriced liquidations → drain |
| `MagnetaSwap` | `setFeeRecipient`, `setFeeExempt`, `setWhitelistedToken`, `whitelistTokenBatch`, `emergencyWithdraw` | Redirect fees / drain |
| `MagnetaPool` | `setPoolCreationEnabled`, `setLiquidityAdditionEnabled`, `emergencyWithdraw` | Grief / drain |
| `MagnetaProxy` | `setFeeRecipient`, `setFeeBps` | Redirect fees |
| `MagnetaFactory` | `setFactoryFee`, `setTreasury` | Redirect deploy fees |
| `MagnetaFarm` | `setRewardPerBlock`, `emergencyRewardWithdraw`, `addPool`, `setPool` | Inflate rewards / drain |
| `MagnetaDLMM` | `setFeeRecipient` | Redirect fees |
| `MagnetaBridgeOApp` | `setFeeRecipient`, `setPeer`, `setTrustedRemote`, `setFees` | Redirect fees / malicious routing |

### Class B — FAST (Safe only, no Timelock)
Response to an attack in progress cannot wait 48h.

| Contract | Function | Why fast |
|---|---|---|
| All | `pause()` | Incident response |
| All | `setPauseGuardian(addr)` | Rotate compromised guardian |

`pause()` already accepts `onlyOwnerOrGuardian` on: `MagnetaPool`, `MagnetaSwap`, `MagnetaDLMM`, `MagnetaLending`, `MagnetaGateway`, `MagnetaFactory`, `MagnetaBridgeOApp`.
Gap: `MagnetaBundler`, `MagnetaMultiPool`, `MagnetaFarm` — pause is onlyOwner. Add a PauseGuardian-only fast path in a follow-up if fast pause on these is needed.

### Class C — NEUTRAL (Safe direct)
No Timelock needed, but still multisig.

| Contract | Function |
|---|---|
| All | `unpause()` |
| All | `transferOwnership` / `acceptOwnership` |

## Gnosis Safe configuration

**Per chain** (Base mainnet, Arbitrum, Polygon, Optimism, later BSC/Avalanche):

- **Type**: Gnosis Safe multisig
- **Signers**: 5 keys — suggested split:
  1. Founder (hardware wallet, cold)
  2. Co-founder / second founder (hardware, cold)
  3. Treasury ops (hardware, warm)
  4. External trusted party (legal / advisor)
  5. Emergency recovery (secondary hardware, offline)
- **Threshold**: 3-of-5
- **Nonce**: monotonic per Safe

**PauseGuardian** (fast pause, no funds custody):
- Single hot EOA or 1-of-N multisig
- Stored in HSM / cloud KMS
- Can `pause()` any contract, cannot `unpause()` (that requires Safe)
- Key rotation procedure documented — see MONITORING.md

## TimelockController parameters

Deploy `@openzeppelin/contracts/governance/TimelockController.sol`:

```solidity
new TimelockController(
    minDelay:   48 * 60 * 60,    // 48 hours
    proposers:  [gnosisSafe],
    executors:  [gnosisSafe, address(0)],  // 0 = anyone can execute after delay
    admin:      address(0)       // self-administered (Safe controls via proposer)
);
```

Rationale:
- **48h delay** standard in DeFi (Aave, Compound, Uniswap governance). Long enough for community to detect malicious proposals, short enough to respond to legit ops.
- **Anyone can execute** (`address(0)` in executors) — prevents griefing if Safe is slow; timelock output is public.
- **Self-administered** — Safe schedules via `proposer` role; no emergency bypass.

## Deployment order

1. Deploy all core contracts with **deployer EOA** as initial owner (current flow).
2. Deploy Gnosis Safe (via safe.global UI) on each chain with correct signer set.
3. Deploy `TimelockController` with Safe as sole proposer.
4. For each Class-A contract:
   - `transferOwnership(timelock)` from deployer.
   - Safe verifies ownership in block explorer.
5. For each Class-B/C contract:
   - `transferOwnership(gnosisSafe)` from deployer.
6. Set `PauseGuardian` on each pausable contract via Safe (direct, no timelock).
7. Verify deployer EOA has NO remaining ownership — `owner()` returns Safe or Timelock.
8. Burn / rotate deployer private key.

## Ownership transfer script

See `scripts/deploy/transferOwnership.ts`.

## Monitoring

See `docs/MONITORING.md`.
