# Tenderly — On-Chain Alert Setup

Runbook for monitoring the 11 Arbitrum-deployed contracts via Tenderly.
Free tier gives 20 alert rules + unlimited contracts, so we stay well under.

## 1. Create the account + project

1. Go to https://dashboard.tenderly.co → Sign up with `info@magneta.finance`
2. Create a project: `magneta-finance` (keep it default / private)
3. Verify email

## 2. Add the 11 Arbitrum contracts

Project → Contracts → Add contract. Network = **Arbitrum One**.

Paste addresses one-by-one (Tenderly auto-fetches ABI + source if verified):

| Tag | Address | Purpose |
|-----|---------|---------|
| MagnetaPool | `0x9c276D7c7a39F67C152bb8192d83813D9c205384` | Core AMM pool |
| MagnetaSwap | `0xDa4321609bd5e28a20d69E8bEBe8a37f03CfAB5D` | Swap router entrypoint |
| MagnetaLending | `0xD75B8F68110129a0202b95894E6Fc3754b4A7de2` | Lending market |
| MagnetaFactory | `0xB48F81c6978b604Ed08fA09587c889f8029Cb552` | Pool factory |
| MagnetaBundler | `0xAC5b2e2cbe6502Ba348a1e7abaac071169612D9C` | Token+LP bundler |
| MagnetaGateway | `0x714d0Ae0Ba1420D046CD2818697E41EF69448Ff0` | Cross-chain gateway |
| MagnetaBridgeOApp | `0x9FF21887b355d06fB0A426E34857567b9D8bbD2a` | LayerZero bridge |
| LPModule | `0xae78a0d6d7E4536ADD1269f16E4fF28f7DB15Cd4` | Gateway LP submodule |
| SwapModule | `0xDbFb571F620f1c9C2dBf23aA065F6F1436bf3eE5` | Gateway swap submodule |
| TokenOpsModule | `0x56B1F90E863542e0491B0d5DbFD19c2d27529e88` | Token ops submodule |
| TaxClaimModule | `0x0581b673da0730e1adB054fB26d42108f13F62f9` | Tax claim submodule |

If a contract is not verified on Arbiscan, paste the ABI manually from
`contracts/solidity/artifacts/contracts/<Name>.sol/<Name>.json`.

## 3. Configure notification channels

Project → Alerts → Destinations:

- **Email** — `info@magneta.finance` (default)
- **Discord** — paste the same webhook URL used by BetterStack (`#alerts` channel
  on Magneta Discord — see `BETTERSTACK_SETUP.md` step 2)

Both destinations fire in parallel for critical alerts.

## 4. Alert rules (16 total — within 20/mo free limit)

Alerts → New Alert. Use **destination = Email + Discord** on every rule below.

### 4.1 — Pause/Unpause events (6 rules — critical, page immediately)

Any `Paused` event on the 3 Pausable contracts is either a real incident or
a guardian-initiated freeze. Either way: wake someone up.

| # | Contract | Event | Severity |
|---|----------|-------|----------|
| 1 | MagnetaPool | `Paused(address)` | **critical** |
| 2 | MagnetaPool | `Unpaused(address)` | info |
| 3 | MagnetaSwap | `Paused(address)` | **critical** |
| 4 | MagnetaSwap | `Unpaused(address)` | info |
| 5 | MagnetaBridgeOApp | `Paused(address)` | **critical** |
| 6 | MagnetaBridgeOApp | `Unpaused(address)` | info |

### 4.2 — Admin/ownership changes (4 rules)

These shouldn't fire in normal ops — if they do, confirm it was us.

| # | Contract(s) | Event | Severity |
|---|-------------|-------|----------|
| 7 | all 11 (one catch-all rule, filter `any`) | `OwnershipTransferStarted(address,address)` | **critical** |
| 8 | all 11 | `OwnershipTransferred(address,address)` | **critical** |
| 9 | all 11 | `PauseGuardianUpdated(address,address)` | high |
| 10 | MagnetaPool, MagnetaSwap, MagnetaLending, MagnetaFactory | `TreasuryUpdated(address,address)` | high |

Tenderly's "Event emitted" alert supports `Any of: [contract list]` as the
trigger target, so rules 7–10 each count as 1 rule even across 11 contracts.

### 4.3 — Large value movements (3 rules)

Early warning for draining / exploits.

| # | Alert type | Trigger | Threshold |
|---|-----------|---------|-----------|
| 11 | Transaction on MagnetaPool | ETH/USDC outflow | `> 50 ETH` or `> 100,000 USDC` in a single tx |
| 12 | Transaction on MagnetaLending | Withdraw event value | `> 50,000 USDC` |
| 13 | Transaction on MagnetaBridgeOApp | Value sent on `send()` | `> 100,000 USDC equiv` |

Use Tenderly's **Parameter filter** on the transfer amount / value field.
Tune the thresholds after 2 weeks of real traffic to avoid noise.

### 4.4 — Failed transactions (3 rules)

Reverts spiking = someone probing, bad config, or oracle lag.

| # | Contract | Trigger | Severity |
|---|----------|---------|----------|
| 14 | MagnetaSwap | `Failed transaction` (rate: >10 in 5min) | medium |
| 15 | MagnetaPool | `Failed transaction` (rate: >10 in 5min) | medium |
| 16 | MagnetaBridgeOApp | `Failed transaction` (rate: >3 in 10min) | high |

**Don't alert on every single revert** — Tenderly charges per alert fired.
Use the "Rate" mode (X events in Y minutes) so normal user-input reverts
don't page you.

## 5. Simulate & verify

Before trusting the setup in production:

1. Go to MagnetaPool on Tenderly → Simulator tab
2. Simulate a `pauseGuardian.pause()` call as the guardian address
3. Confirm you get email + Discord message within 60s
4. Delete the simulated tx from the dashboard

## 6. What to do when an alert fires

| Alert | First response |
|-------|---------------|
| `Paused` on any contract | Check Discord — did we pause it? If no, confirm bytecode unchanged + investigate last 5 txs. |
| `OwnershipTransferStarted` | Call deployer EOA — was this us? If no, cancel via `acceptOwnership()` **not being called** + `renounceOwnership()` immediately. |
| `PauseGuardianUpdated` | Check the new address matches expected guardian rotation. If not, pause everything. |
| Large outflow on Pool | Check the receiver address on Arbiscan — known integrator or unknown? |
| Failed tx spike | Open dashboard, inspect the reverted calldata — if one signature repeats, likely exploit probing. |
| Bridge `send()` large | Confirm the destination chain peer is configured correctly (via `configPeers.ts` output). |

## 7. Expanding to other chains later

When Base / Polygon / etc. come online:

1. Add the new deploy's `deployments/<chain>.json` contracts to the same project
2. Clone rules 1–10 by duplicating in Tenderly (add the new addresses to the "Any of" list)
3. New chains do NOT need new alert rules — each catch-all rule now covers more contracts

Stay under 20 rules regardless of chain count by using contract-list filters.

## Cost

- Free tier: **20 alert rules, unlimited contracts, 1 user** — $0/mo
- We use 16 rules → fits with 4 spare for future events
- Next tier: $50/mo (Pro) if we need Web3 Actions (automated response scripts)
