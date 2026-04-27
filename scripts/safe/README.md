# Safe Tx Builder Batches

Pre-built JSON files designed to be uploaded into the **Safe Tx Builder**
app (Apps → Tx Builder → Drag & Drop) for one-shot multi-call execution
through the Magneta multisig.

## Batch types

| Pattern | Purpose | Generator |
|---|---|---|
| `<chain>-acceptOwnership-batch.json` | Finalize Ownable2Step transfer (deployer EOA → Safe) on every Magneta contract for a given chain. Run **once per chain** right after deploy. | hand-written, one per chain |
| `<chain>-whitelistTokens-batch.json` | Whitelist a chain's canonical USDC + native wrap on `MagnetaSwap` (only chains where the default-router doesn't already cover them). | hand-written |
| `<chain>-peerWiring-batch.json` | Wire LayerZero V2 peers + EID↔chainId mappings on `MagnetaGateway` and `MagnetaBridgeOApp` for every other Magneta-deployed mainnet chain. **One batch per chain**, 54 txs each (18 remote peers × 3 calls). | `pnpm tsx scripts/deploy/generatePeerWiringBatches.ts` |

## Peer wiring — execution playbook

The 19 peer-wiring batches cross-link every mainnet chain that has both
`MagnetaGateway` and `MagnetaBridgeOApp` deployed. **Without these batches,
the bridge cannot route messages** — every cross-chain `bridgeTokens()` call
reverts on `_getPeerOrRevert` and every Gateway dispatch reverts on a
missing EID mapping.

Eligible chains (19, alphabetical): `abstract`, `arbitrum`, `avalanche`,
`base`, `berachain`, `bsc`, `celo`, `flare`, `gnosis`, `katana`, `linea`,
`mantle`, `monad`, `optimism`, `plasma`, `polygon`, `sei`, `sonic`,
`unichain`.

Skipped: `cronos` (LZ V2 not live → no Gateway/Bridge deployed),
`hyperliquid` (deferred), testnets.

### Three Safe addresses involved

| Safe | Chains |
|---|---|
| `0xC4c96aF54cdE078dc993d6948199b0AF8cD6717a` | avalanche, base, berachain, bsc, celo, gnosis, katana, linea, mantle, monad, optimism, plasma, sonic, unichain |
| `0x4AeA3A398Db41b45e146c08131aD27c75b02EC2F` (legacy) | arbitrum, polygon |
| `0x40ea2908Ea490d58E62D1Fd3364464D8A857b297` (in-house, Cronos/Flare/Sei pattern) | abstract, flare, sei |

### Order of execution

Order doesn't matter — each chain's batch only writes state local to that
chain (its own `Gateway.setPeer` / `BridgeOApp.setPeer`). However, **a peer
wire is only effective once both sides are configured**. So bridge messages
between chains A and B start working only after both `A-peerWiring` AND
`B-peerWiring` are executed.

Suggested order (highest-volume routes first, so we get bridge testing
coverage as early as possible):

1. base, arbitrum, polygon — highest expected volume, stable canonical USDC
2. optimism, bsc, avalanche — large ecosystems
3. linea, mantle, gnosis, celo — Tier-2
4. unichain, sonic, monad, katana, plasma — newer L2/L1s
5. abstract, flare, sei — minor volume + in-house Safe
6. berachain — last (no LP/Swap module locally; bridge-only chain)

### Per-batch upload procedure

For each `<chain>-peerWiring-batch.json`:

1. Open Safe Tx Builder for the corresponding chain
   (e.g. `https://app.safe.global/apps/tx-builder?safe=eth:0xC4c9...717a`)
2. Switch the Safe network to the chain in question
3. **Apps → Tx Builder → Drag & Drop** the JSON file
4. Verify: 54 transactions, 18 remote peers × 3 calls (setPeer × 2 + setEidMapping)
5. **Create batch** → review the summary
6. Sign with operator #1 → notify operator #2 → execute

Estimated effort: ~30-60 min total for all 19 chains (mostly waiting for
the second signer + confirmations).

### After execution — sanity checks

For each chain, verify peer state on-chain:

```bash
# replace <chain> with hardhat-config network name
pnpm hardhat run scripts/verify-deployed.ts --network <chain>
# or per-peer:
cast call $GATEWAY "peers(uint32)(bytes32)" 30184 --rpc-url $RPC_URL # base eid
```

Expected: returns the bytes32-padded address of the peer Gateway. Anything
else (zero, wrong address) means the batch wasn't fully executed for that
chain.

### Re-generating the batches

If a new chain is deployed (or addresses change), just rerun the generator:

```bash
pnpm tsx scripts/deploy/generatePeerWiringBatches.ts
```

It reads `deployments/*.json` and rewrites every `<chain>-peerWiring-batch.json`
with the latest peer set. Already-executed `setPeer` calls are idempotent,
so re-uploading an updated batch on a previously-wired chain only writes
the new entries.

## Liquidity provisioning (separate — NOT in these batches)

Peer wiring is a prerequisite for the bridge to route messages, but the
bridge **also needs liquidity** on each destination chain (`bridge_ata` /
liquidity pool) before users can withdraw on the other side. That's a
separate operational step — see `project_bridge_status.md` memory and the
$10k/chain provisioning plan.
