/**
 * Filter the freshly regenerated peer-wiring batches so that the 19 chains
 * already part of the mesh (per `infra_peer_wiring_complete` 2026-04-28)
 * only execute the 3 Cronos-specific setPeer/setEidMapping calls instead
 * of the full 57-tx batch.
 *
 * Output: <chain>-peerWiring-cronosDelta-batch.json (3 txs each), and
 * the cronos-peerWiring-batch.json itself stays as the full 57-tx batch
 * since Cronos is wiring against all 19 peers for the first time.
 *
 * Run:
 *   pnpm hardhat run scripts/deploy/filterCronosDeltaBatches.ts
 */
import fs from "node:fs";
import path from "node:path";

const REPO_ROOT  = path.join(__dirname, "..", "..");
const SAFE_DIR   = path.join(REPO_ROOT, "scripts", "safe");
const CRONOS_EID = "30359";

interface Tx {
  to: string;
  contractMethod?: { name: string; inputs: Array<{ name: string; type: string }> };
  contractInputsValues?: Record<string, string>;
  [k: string]: unknown;
}
interface Batch {
  meta?: { name?: string; description?: string };
  transactions: Tx[];
  [k: string]: unknown;
}

const ALREADY_WIRED = [
  "abstract", "arbitrum", "avalanche", "base", "berachain", "bsc", "celo",
  "flare", "gnosis", "katana", "linea", "mantle", "monad", "optimism",
  "plasma", "polygon", "sei", "sonic", "unichain",
];

function targetsCronos(tx: Tx): boolean {
  const method = tx.contractMethod?.name;
  const eid = tx.contractInputsValues?.eid ?? tx.contractInputsValues?._eid;
  if (!method) return false;
  if (method !== "setPeer" && method !== "setEidMapping") return false;
  return eid === CRONOS_EID;
}

let written = 0;
for (const chain of ALREADY_WIRED) {
  const inPath = path.join(SAFE_DIR, `${chain}-peerWiring-batch.json`);
  if (!fs.existsSync(inPath)) {
    console.warn(`  · ${chain}: batch not found, skipping`);
    continue;
  }
  const batch = JSON.parse(fs.readFileSync(inPath, "utf8")) as Batch;
  const filtered = batch.transactions.filter(targetsCronos);
  if (filtered.length === 0) {
    console.warn(`  · ${chain}: no Cronos-targeted calls found, skipping`);
    continue;
  }
  const outBatch: Batch = {
    ...batch,
    meta: {
      name: `Magneta — peer wiring Cronos delta (${chain})`,
      description: `Add Cronos (eid 30359, chainId 25) as a peer on ${chain}'s MagnetaGateway + MagnetaBridgeOApp. Cronos was wired up post-mesh after the 2026-04-28 full peer wiring (which had Cronos at 5/11). Replaces the full 57-tx peerWiring batch with the 3 Cronos-only calls so already-wired peers aren't redundantly re-set.`,
    },
    transactions: filtered,
  };
  const outPath = path.join(SAFE_DIR, `${chain}-peerWiring-cronosDelta-batch.json`);
  fs.writeFileSync(outPath, JSON.stringify(outBatch, null, 2) + "\n");
  console.log(`  wrote ${path.relative(REPO_ROOT, outPath)}  (${filtered.length} txs)`);
  written++;
}
console.log(`\n${written}/${ALREADY_WIRED.length} delta batches written.`);
