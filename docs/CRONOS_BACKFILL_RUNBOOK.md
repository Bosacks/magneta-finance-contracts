# Cronos backfill runbook

Brings Cronos EVM from 5/11 → 11/11 contracts. Took ~3 weeks to discover
that LayerZero V2 IS actually live on Cronos at endpoint
`0x3A73033C0b1407574C76BdBAc67f126f6b4a9AA9` (EID **30359**, same address
as Hyperliquid but distinct EID). The Sprint 5 off-chain relayer becomes
redundant once this runs successfully.

## Prerequisites

- Deployer wallet `0x620684F822da9adF36F41e3554791D889947e25E` funded with
  **~3-5 CRO** on Cronos (covers 6 contract deployments + 13 setModule txs +
  2 setUsdc/setPauseGuardian txs + 1 setFeeExempt). At ~$0.08/CRO that's
  ~$0.40 total — way under the original Cronos deploy budget.
- `CRONOS_MAINNET_RPC_URL` in `.env` set to a working RPC (default
  `https://evm.cronos.org`).
- The `chainConfig.ts` Cronos entry is already correct (lzEndpoint +
  lzEid=30359 — confirmed by the scripts/deploy/chainConfig.ts edit).

## Step 1 — Backfill deploy

```bash
cd /home/dominique/Projets/magneta-finance-contracts
pnpm hardhat run scripts/deploy/deployCronosBackfill.ts --network cronos
```

The script is idempotent — re-running after a crash skips already-deployed
contracts and only finishes what's missing. It also checkpoints the
`deployments/cronos.json` file before any config tx, so a config-phase
crash doesn't lose the new addresses.

Expected output: 6 new contracts (`MagnetaGateway`, `MagnetaBridgeOApp`,
`LPModule`, `SwapModule`, `TaxClaimModule`, `TokenOpsModule`) + 13 module
registrations on the Gateway.

## Step 2 — Peer wiring

Cronos's Gateway needs to know about the other 19 chains' Gateways
(reciprocal). Use the existing batch generator:

```bash
pnpm hardhat run scripts/deploy/generatePeerWiringBatches.ts --network cronos
```

This writes `scripts/safe/cronos-peerWiring-batch.json` and a reciprocal
entry into `scripts/safe/<chain>-peerWiring-batch.json` for each of the
other 19 chains.

The deployer EOA owns the new contracts on Cronos (until ownership is
transferred to the in-house Safe `0x40ea2908Ea490d58E62D1Fd3364464D8A857b297`),
so you can run `setPeer` directly via hardhat instead of a Safe batch:

```bash
pnpm hardhat run scripts/deploy/configPeers.ts --network cronos
```

For the OTHER chains' side (registering Cronos as a peer), you need Safe
batches because those chains are already owned by the Safe. Execute each
generated `<chain>-peerWiring-batch.json` via your Safe UI (or the
`scripts/safe/inhouse/` scripts for chains without Safe Wallet UI).

## Step 3 — CCTP

Cronos has `cctpDomain: null` — Circle's CCTP isn't deployed there. Skip
this step. (USDC on Cronos is the bridged Crypto.com-issued variant, not
native Circle USDC.)

## Step 4 — Transfer ownership to Safe

```bash
pnpm hardhat run scripts/deploy/transferOwnership.ts --network cronos
```

Transfers ownership of the 6 new contracts to in-house Safe
`0x40ea2908Ea490d58E62D1Fd3364464D8A857b297`. The 5 existing contracts
already are Safe-owned per the original deploy.

## Step 5 — Update frontend configs

After deploy completes, copy the addresses from `deployments/cronos.json`
into the two frontend repos:

### Tokens repo (`magneta-finance-tokens`)

`lib/constants/contracts.ts` — add the LP/Swap/TaxClaim/TokenOps/Gateway/
BridgeOApp addresses to their respective per-chain maps. The existing
entries (Pool/Swap/Lending/Factory/Bundler/Router) already cover Cronos.

### DEX repo (`magneta-finance-dex`)

`apps/web/lib/constants/gatewayChains.ts` line 94 — fill in the Cronos
entry with the new addresses and switch `status: 'pending_deployment'` →
`'live'`. The eid is already correct (30359 — fixed in the same commit
that added this runbook).

## Step 6 — Sunset the Cronos relayer (optional)

The Sprint 5 EIP-712 relayer service (`magneta-orchestrator`'s
`cronos-relayer` module) was built to work around the missing LZ V2.
Once the LZ V2 path is live and verified, you can:

- **Option A**: keep the relayer as a backup (no harm, just unused).
- **Option B**: decommission it — stop the systemd service on the VPS,
  remove the API route in the Tokens repo (`app/api/cronos-relayer/`),
  empty the relayer wallet `0x2B898219Ce1dbEb3ECd3956223b9Ff0C0B126aC2`.

Wait until at least one cross-chain Cronos test (e.g., CREATE_TOKEN from
Polygon → Cronos) has confirmed the new path works end-to-end before
decommissioning.

## Verification

After Step 1:

```bash
cd /home/dominique/Projets/magneta-finance-contracts
node scripts/verify_cronos.js
```

After Step 2 — sanity check that Cronos's Gateway knows the 19 other peers:

```bash
node scripts/verify_lz.js --chain cronos
```

Expected: 19/19 peers registered, both directions.

## Total cost estimate

| Item                     | CRO   | USD (~$0.08/CRO) |
|--------------------------|-------|------------------|
| 6 contracts + config     | ~3    | $0.24            |
| Peer wiring (Cronos side)| ~2    | $0.16            |
| Ownership transfer       | ~0.5  | $0.04            |
| **Total**                | ~5.5  | **~$0.45**       |

Other chains' Safe batches that register Cronos as a peer cost ~$0.005-$5
each depending on the chain (see existing peer wiring batches for prior
gas figures).
