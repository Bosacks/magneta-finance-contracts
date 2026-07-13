/**
 * Sprint 9.6 — Generate Safe batches that wire every CreateTokenDispatcher
 * to its 18 sibling dispatchers.
 *
 * Reads `deployments-dispatcher/<chain>.json` for each chain (already produced
 * by `deploy-create-token-dispatcher.ts`) and emits one Safe Tx Builder JSON
 * per chain at:
 *   `magneta-finance-contracts/scripts/safe/<chain>-dispatcherFullPeers-batch.json`
 *
 * Each batch contains 18 `setPeer(uint32 eid, bytes32 peer)` transactions —
 * one per remote chain. Peer addresses are zero-padded to bytes32 in the
 * standard LZ V2 way.
 *
 * The dispatchers are owned by their per-chain Safe (transferred during
 * `deploy-create-token-dispatcher.ts`), so `setPeer` must come from the
 * Safe — this script never sends a transaction.
 *
 * Usage:
 *   pnpm hardhat run scripts/generatePeerWiringBatches.ts
 *   # (no --network flag needed — purely off-chain)
 */
import * as fs from "fs";
import * as path from "path";
import { ethers } from "hardhat";

const CONTRACTS_REPO = "/home/dominique/Projets/magneta-finance-contracts";
const SAFE_OUT_DIR   = path.join(CONTRACTS_REPO, "scripts", "safe");

/** EIDs from `lib/constants/gatewayChains.ts` (Cluster A + B + Abstract). */
const CHAIN_EIDS: Record<string, number> = {
  arbitrum:  30110,
  avalanche: 30106,
  base:      30184,
  bsc:       30102,
  celo:      30125,
  flare:     30295,
  gnosis:    30145,
  linea:     30183,
  mantle:    30181,
  optimism:  30111,
  polygon:   30109,
  sei:       30280,
  berachain: 30362,
  katana:    30375,
  monad:     30390,
  plasma:    30383,
  sonic:     30332,
  unichain:  30320,
  abstract:  30324,
};

/** EVM chainId per chain, used to populate the Safe Tx Builder header. */
const CHAIN_IDS: Record<string, string> = {
  arbitrum:  "42161",
  avalanche: "43114",
  base:      "8453",
  bsc:       "56",
  celo:      "42220",
  flare:     "14",
  gnosis:    "100",
  linea:     "59144",
  mantle:    "5000",
  optimism:  "10",
  polygon:   "137",
  sei:       "1329",
  berachain: "80094",
  katana:    "747474",
  monad:     "143",
  plasma:    "9745",
  sonic:     "146",
  unichain:  "130",
  abstract:  "2741",
};

interface DispatcherDeployment {
  network: string;
  createTokenDispatcher: string;
  safe: string;
}

function loadDispatchers(): Record<string, DispatcherDeployment> {
  const dir = path.join(__dirname, "..", "deployments-dispatcher");
  const out: Record<string, DispatcherDeployment> = {};
  for (const name of Object.keys(CHAIN_EIDS)) {
    const file = path.join(dir, `${name}.json`);
    if (!fs.existsSync(file)) {
      console.warn(`⚠ Missing ${file} — chain '${name}' will be skipped`);
      continue;
    }
    const j = JSON.parse(fs.readFileSync(file, "utf-8"));
    if (!j.createTokenDispatcher) {
      console.warn(`⚠ ${name}.json has no createTokenDispatcher field`);
      continue;
    }
    if (!j.safe) {
      console.warn(`⚠ ${name}.json has no safe field`);
      continue;
    }
    out[name] = {
      network: name,
      createTokenDispatcher: j.createTokenDispatcher,
      safe: j.safe,
    };
  }
  return out;
}

function buildBatch(local: DispatcherDeployment, all: Record<string, DispatcherDeployment>) {
  const localEid = CHAIN_EIDS[local.network];
  const localChainId = CHAIN_IDS[local.network];
  const iface = new ethers.Interface([
    "function setPeer(uint32 _eid, bytes32 _peer) external",
  ]);

  const transactions = [];
  for (const [remoteName, remote] of Object.entries(all)) {
    if (remoteName === local.network) continue;     // self
    const remoteEid = CHAIN_EIDS[remoteName];
    const peer = ethers.zeroPadValue(remote.createTokenDispatcher.toLowerCase(), 32);
    const data = iface.encodeFunctionData("setPeer", [remoteEid, peer]);
    transactions.push({
      to: local.createTokenDispatcher,
      value: "0",
      data,
      contractMethod: null,
      contractInputsValues: null,
    });
  }

  return {
    version: "1.0",
    chainId: localChainId,
    createdAt: Date.now(),
    meta: {
      name: `Magneta Sprint 9.6 — Dispatcher peer wiring (${local.network})`,
      description:
        `Wires CreateTokenDispatcher on ${local.network} (eid ${localEid}) to ` +
        `${transactions.length} sibling dispatchers via setPeer(eid, peer).`,
      txBuilderVersion: "1.17.0",
      createdFromSafeAddress: local.safe,
      createdFromOwnerAddress: "",
    },
    transactions,
  };
}

async function main() {
  fs.mkdirSync(SAFE_OUT_DIR, { recursive: true });
  const all = loadDispatchers();
  const names = Object.keys(all).sort();
  if (names.length < 2) {
    throw new Error("Need at least 2 dispatcher deployments to wire peers.");
  }
  console.log(`Loaded ${names.length} dispatchers — generating batches\n`);

  let totalWires = 0;
  for (const name of names) {
    const batch = buildBatch(all[name], all);
    const out = path.join(SAFE_OUT_DIR, `${name}-dispatcherFullPeers-batch.json`);
    fs.writeFileSync(out, JSON.stringify(batch, null, 2) + "\n");
    totalWires += batch.transactions.length;
    console.log(`  ${name.padEnd(11)} ${batch.transactions.length.toString().padStart(2)} wires → ${out}`);
  }
  console.log(`\nTotal: ${totalWires} setPeer transactions across ${names.length} batches`);
  console.log(`Each batch must be signed by its respective per-chain Safe.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
