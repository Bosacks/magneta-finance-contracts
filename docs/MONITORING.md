# Monitoring & Incident Response

## Goals
1. Detect an exploit in < 5 minutes (before drain completes on a slow/large pool).
2. Pause all affected contracts in < 2 minutes after detection.
3. Know who to page, and what they should do.

## Monitoring stack

### Tier 1 — real-time alerting (mandatory before mainnet)

**Tenderly Web3 Actions** (or **OpenZeppelin Defender Sentinel**):
- One monitor per deployed contract per chain.
- Alert triggers:
  - Any `pause()` / `unpause()` event (verify source = guardian/Safe).
  - Any `setFeeRecipient`, `setRouter`, `setModule`, `setFeeVault`, `setPriceFeed` event.
  - Any transfer > 10% of pool reserves in a single tx.
  - Failed `latestRoundData` → Chainlink feed stale.
  - Reserve mismatch: `token0.balanceOf(pool) - reserve0 > 1%`.
- Alert channels: Slack `#magneta-alerts`, PagerDuty on-call, email fallback.

**Forta bots** (free tier):
- Subscribe to: `flash-loan-attack-detector`, `large-price-impact`, `anomalous-token-transfers`.
- Route alerts to the same Slack channel.

### Tier 2 — dashboards (should-have)

**Grafana** or **Dune Analytics**:
- TVL per pool, per chain.
- Daily fee revenue per chain.
- Admin action log (table of all `onlyOwner` events with tx hashes).
- Timelock pending operations (queued but not executed).

### Tier 3 — post-mortem data (nice-to-have)

- **Etherscan contract verification** on all chains — needed for public inspection after an incident.
- Full event indexing via **MagnetaScope** (our explorer).

## Incident response runbook

### P0 — Funds at immediate risk (reentrancy, price manipulation, drain in progress)

1. **PauseGuardian** calls `pause()` on the affected contract. This is an EOA, expected latency < 60s.
2. Post in `#magneta-incident` with:
   - tx hash of the attack
   - tx hash of the pause
   - affected contract + chain
3. Founder + on-call verify pause succeeded (`paused() == true`).
4. Gnosis Safe signers convene. Do NOT `unpause` until root cause identified.
5. If funds were lost, file Immunefi report within 24h (see bounty section below).

### P1 — Suspicious admin action (unauthorized `setX` call)

1. Check tx origin: Is it Safe? Timelock? An EOA?
2. If EOA and not our deployer → treat as P0 (compromised key).
3. If Timelock and we didn't schedule it → immediately `cancel` via Safe (timelock has a `cancel` role).

### P2 — Stale price feed / oracle degraded

1. Chainlink typically recovers on its own within 5 minutes.
2. If staleness > 30 minutes, `pause()` MagnetaLending to prevent mispriced liquidations.
3. Monitor Chainlink status page; `unpause` after feed resumes.

## On-call rotation

- **Primary**: founder (week 1), co-founder (week 2), alternating.
- **Secondary**: external trusted party (Class A multisig signer).
- **Escalation**: if primary is unreachable for 15 min, secondary takes over.

## Guardian key rotation

- **Trigger**: suspected compromise, quarterly scheduled rotation, or offboarding.
- **Procedure**:
  1. Generate new guardian EOA on hardware wallet.
  2. Safe calls `setPauseGuardian(newGuardian)` on each pausable contract.
  3. Verify events emitted for `PauseGuardianUpdated`.
  4. Burn old key (destroy hardware wallet seed if physical compromise suspected).

## Bug bounty (Immunefi)

Post-launch, register the program with these tiers (DeFi standard):

| Severity | Bounty (USD) | Examples |
|---|---|---|
| Critical | $50,000 | Drain TVL, mint unlimited tokens, hijack ownership |
| High | $10,000 | Freeze funds, partial drain, price oracle manipulation |
| Medium | $2,500 | Griefing, temporary DoS |
| Low | $500 | Minor accounting error, informational |

Scope: all deployed core contracts on mainnet. Test contracts / testnets excluded.

## Verification

Every contract deployed on mainnet must be verified on its chain's explorer before announcing launch:

```bash
./scripts/verify-all.sh <network>
```

See `scripts/verify-all.sh`.
