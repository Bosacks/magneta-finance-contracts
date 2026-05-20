# Pre-launch wiring audit — 2026-05-20

First run of `scripts/verify-production-wiring.sh` against all 17 EVM
mainnet deployments produced **7 chains with FAIL findings** that must be
investigated and resolved before public launch.

## Summary

| Status | Chain | Notes |
|--------|-------|-------|
| ✅ pass | polygon | 21/21 checks |
| ✅ pass | arbitrum | 21/21 checks |
| ✅ pass | base | 21/21 checks |
| ✅ pass | optimism | 21/21 checks |
| 🔴 FAIL | **bsc** | All 6 pausable addresses return zero bytecode |
| ✅ pass | linea | 21/21 checks |
| ✅ pass | mantle | 21/21 checks |
| 🔴 FAIL | **avalanche** | All 6 pausable addresses return zero bytecode |
| 🔴 FAIL | **unichain** | All 6 pausable addresses return zero bytecode |
| 🔴 FAIL | **sonic** | All 6 pausable addresses return zero bytecode |
| ✅ pass | sei | 21/21 checks |
| 🔴 FAIL | **gnosis** | All 6 pausable addresses return zero bytecode |
| 🔴 FAIL | **celo** | All 6 pausable addresses return zero bytecode |
| ✅ pass | flare | 21/21 checks |
| ✅ pass | monad | 21/21 checks |
| 🔴 FAIL | **berachain** | All 6 pausable addresses return zero bytecode |
| ✅ pass | katana | 21/21 checks |
| ✅ pass | plasma | 21/21 checks |

## Diagnosis

The pattern across the 7 failing chains is **identical sets of "wrong"
addresses** that appear to be **copied from other chains** (Polygon
addresses shifted by one row, or the chain's defaultRouter used as
MagnetaPool). This is consistent with **deployment JSON corruption during
a template/copy step**, not failed contract deployments.

Compare for example bsc.json vs polygon.json:

```
bsc.json :  MagnetaPool    = 0xF4A2890fA6...  ← BSC's PancakeSwap router!
            MagnetaSwap    = 0xDc6BFf741D...  ← Polygon's MagnetaPool address
            MagnetaLending = 0xDa43c95Fb2...  ← Polygon's MagnetaSwap address
            ...                                ← rest shifted one row down
```

Almost certainly the contracts ARE deployed on BSC/Avalanche/etc. at
**different addresses than what's in the JSON files**. The proof: the
Tokens UI, listener, subgraph and DEX are all live in production — if the
contracts didn't actually exist, those services would have already broken
loudly.

## What this breaks

The deployment JSONs are read by:

1. **magneta-listener** — `loadFeeContractsFromDeployments()` and
   `loadMagAddrsFromDeployments()`. If addresses are wrong, the listener
   watches the wrong contracts → on-chain events from the real Magneta
   contracts on these 7 chains are NOT ALERTED. **This is a security
   blind spot.**

2. **Hardhat scripts** (`scripts/deploy/configureOnly.ts`,
   `scripts/safe/*`). Any operational action targeting a wrong-mapped
   chain will hit the wrong address.

3. **chain-service & chain-widgets packages**, if they read from these
   JSONs.

4. **Future audits** — auditors will be confused by inconsistent
   deployment records.

The Tokens UI, DEX, Scope frontends apparently DO NOT depend on these
broken JSONs (since they work in production). They likely have their own
chain config in `lib/chains/`, `chain-service`, or `chain-widgets`.

## Action plan

Before any public launch, for each failing chain:

1. **Find the real on-chain addresses.** Two ways:
   - Look at the Safe transaction history of the deployer EOA
     `0x620684F822da9adF36F41e3554791D889947e25E` on each chain's explorer
     and identify the contract creation transactions.
   - Read the addresses from the working frontend code (the UI uses them
     in production so they must be cached somewhere).
   - Or rerun the verification script with a hypothesis address (manually
     edit a copy of the JSON and re-probe).

2. **Update `deployments/<chain>.json`** with the real addresses.

3. **Re-run** `./scripts/verify-production-wiring.sh <chain>` until the
   chain passes.

4. **Commit** the corrected JSON.

5. **Restart magneta-listener** on the VPS so it picks up the corrected
   addresses and starts watching the right contracts.

## Status of the verification script

The script worked as designed — caught a real, serious issue. It is
intended to be run:

- Before any public announcement;
- After every contract redeploy;
- Quarterly as part of the maintenance drill (alongside
  `pause-guardian-drill.sh`).

Exit code 1 when at least one chain fails, so CI can gate releases on it.

## Related runbook section

This finding should be cross-linked in INCIDENT_RUNBOOK.md §3
"Adresses critiques par chaîne" — until the JSONs are fixed, the
mainnet table must NOT be filled from the JSONs as-is.
