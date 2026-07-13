/**
 * Phase 2 — parameterized Safe Transaction Builder batch GENERATOR.
 *
 * WHAT THIS DOES
 * --------------
 * Phase 2 of the contract redeploy redeploys the LayerZero V2 CREATE_TOKEN
 * dispatchers (CreateTokenDispatcher / CreateTokenDispatcherV3) on each chain
 * and RE-WIRES THE PEER MESH between them. Every dispatcher must learn the
 * bytes32 address of every OTHER chain's dispatcher via:
 *
 *     setPeer(uint32 _eid, bytes32 _peer)        // OAppCore.sol, public onlyOwner
 *
 * Source of truth for the wiring pattern: scripts/generatePeerWiringBatches.ts
 * (the Sprint 9.6 generator that produced the original 342/342 V2 wires) and
 * scripts/safe/generate-phase1-batches.ts (the parameterized Phase-1 generator
 * this one is modeled on — same address-table-driven flow, same Safe schema).
 *
 * MESHES (handled SEPARATELY, never mixed)
 * ----------------------------------------
 *   V2 mesh : the full set of chains that have a deployments-dispatcher/<net>.json
 *             (19 chains as of the runbook → 19*18 = 342 peer wires).
 *   V3 mesh : ONLY the chains that have a deployments-dispatcher-v3/<net>.json
 *             (arbitrum / base / polygon → 3*2 = 6 peer wires). CreateTokenDispatcherV3
 *             exists only on those 3 chains, so its mesh is just those 3 among
 *             themselves. V3 dispatchers peer to OTHER V3 dispatchers, never to V2.
 *
 * WHY A GENERATOR
 * ---------------
 * The new dispatcher addresses do not exist until Phase-2 deploy time. The owner
 * fills scripts/safe/phase2-addresses.json (copied from the committed
 * .template.json) with newDispatcher / newDispatcherV3 per chain post-deploy,
 * then runs this script. eid + safe are pre-filled from in-repo sources
 * (lib/constants/gatewayChains.ts for EIDs, phase1-addresses.template.json for
 * the per-chain Safe), but verify them before signing.
 *
 * OWNERSHIP / WHO SIGNS (evidence from the .sol sources)
 * ------------------------------------------------------
 *   - setPeer(uint32,bytes32) selector 0x3400288b — inherited from
 *     @layerzerolabs/oapp-evm/contracts/oapp/OAppCore.sol L43:
 *         function setPeer(uint32 _eid, bytes32 _peer) public virtual onlyOwner
 *   - CreateTokenDispatcher   is OApp, ... Ownable(_delegate)   (CreateTokenDispatcher.sol L54/L119)
 *   - CreateTokenDispatcherV3 is OApp, ... Ownable(_delegate)   (CreateTokenDispatcherV3.sol L56/L124)
 *     Both are transferred to the per-chain Safe at deploy time, so EVERY setPeer
 *     is a Safe-batch tx. This script never sends a transaction.
 *
 * PEER ENCODING
 * -------------
 *   peer = the remote dispatcher's 20-byte address left-padded to bytes32:
 *          0x + 24 zero-bytes + 20-byte address  (ethers.zeroPadValue(addr, 32)).
 *   Identical to the Sprint 9.6 generator (generatePeerWiringBatches.ts L119).
 *
 * USAGE
 * -----
 *   cd contracts/solidity
 *   cp scripts/safe/phase2-addresses.template.json scripts/safe/phase2-addresses.json
 *   # ... deploy the new dispatchers, then fill newDispatcher (and newDispatcherV3
 *   #     for the 3 V3 chains) per chain in phase2-addresses.json ...
 *   npx ts-node scripts/safe/generate-phase2-peer-batches.ts
 *   # or: npx hardhat run scripts/safe/generate-phase2-peer-batches.ts
 *
 * OUTPUT (one file per chain that is filled in)
 * ---------------------------------------------
 *   scripts/safe/<network>-phase2-peers-batch.json        (V2 mesh, n-1 setPeer txs)
 *   scripts/safe/<network>-phase2-peers-v3-batch.json      (V3 mesh, only the 3 V3 chains)
 *   Import each into the Safe Transaction Builder app and sign with the listed Safe.
 *
 * No on-chain calls are made.
 */
import { ethers } from "ethers";
import * as fs from "node:fs";
import * as path from "node:path";

const SAFE_DIR = __dirname;
const CONFIG_PATH = path.join(SAFE_DIR, "phase2-addresses.json");
const TEMPLATE_PATH = path.join(SAFE_DIR, "phase2-addresses.template.json");

const ZERO = "0x0000000000000000000000000000000000000000";

// Real ABI — selector 0x3400288b, verified against OAppCore.sol (onlyOwner).
const dispatcherIface = new ethers.Interface([
  "function setPeer(uint32 _eid, bytes32 _peer)",
]);

interface ChainEntry {
  network: string;
  newDispatcher: string; // new V2 CreateTokenDispatcher (blank/zero => skip in V2 mesh)
  newDispatcherV3?: string; // new V3 dispatcher (only the 3 V3 chains)
  eid: number;
  safe: string;
}

interface SafeTx {
  to: string;
  value: string;
  data: string;
  contractMethod: null;
  contractInputsValues: null;
}

function isSet(addr: string | undefined): boolean {
  return !!addr && ethers.isAddress(addr) && addr.toLowerCase() !== ZERO;
}

function loadConfig(): { source: string; chains: Record<string, ChainEntry> } {
  const usedPath = fs.existsSync(CONFIG_PATH) ? CONFIG_PATH : TEMPLATE_PATH;
  if (!fs.existsSync(usedPath)) {
    throw new Error(
      `No address table found. Expected ${CONFIG_PATH} or ${TEMPLATE_PATH}.`,
    );
  }
  const raw = JSON.parse(fs.readFileSync(usedPath, "utf-8"));
  return { source: usedPath, chains: raw.chains as Record<string, ChainEntry> };
}

/**
 * Build one Safe batch for `local`, with one setPeer tx per OTHER member of
 * the mesh. `addressOf` picks which address field (V2 or V3) is the dispatcher
 * for a given mesh.
 */
function buildMeshBatch(
  meshLabel: "V2" | "V3",
  localChainId: string,
  local: ChainEntry,
  members: [string, ChainEntry][], // [chainId, entry] for every filled mesh member (incl. local)
  addressOf: (e: ChainEntry) => string,
): { batch: unknown; wires: number } {
  const transactions: SafeTx[] = [];
  const localAddr = addressOf(local);

  for (const [remoteChainId, remote] of members) {
    if (remoteChainId === localChainId) continue; // skip self-peering
    const remoteEid = remote.eid;
    const peer = ethers.zeroPadValue(addressOf(remote).toLowerCase(), 32);
    transactions.push({
      to: localAddr,
      value: "0",
      data: dispatcherIface.encodeFunctionData("setPeer", [remoteEid, peer]),
      contractMethod: null,
      contractInputsValues: null,
    });
  }

  const batch = {
    version: "1.0",
    chainId: String(localChainId),
    createdAt: 1780500000,
    meta: {
      name: `Magneta Phase 2 — Dispatcher${meshLabel === "V3" ? " V3" : ""} peer wiring (${local.network})`,
      description:
        `Phase 2 re-wires the ${meshLabel} CREATE_TOKEN dispatcher on ${local.network} ` +
        `(eid ${local.eid}, ${localAddr}) to its ${transactions.length} sibling ` +
        `${meshLabel} dispatcher(s) via setPeer(eid, bytes32(peer)). ` +
        `Sign with Safe ${local.safe}.`,
    },
    transactions,
  };

  return { batch, wires: transactions.length };
}

function main() {
  const { source, chains } = loadConfig();
  console.log(`\n── Phase 2 dispatcher peer-wiring generator ──`);
  console.log(`Address table: ${path.relative(process.cwd(), source)}`);
  const usingTemplate = path.basename(source) === "phase2-addresses.template.json";
  if (usingTemplate) {
    console.log(
      `  (using the TEMPLATE — every newDispatcher/newDispatcherV3 is zero, so all`,
    );
    console.log(`   chains will be reported SKIPPED. Copy it to phase2-addresses.json`);
    console.log(`   and fill the real dispatcher addresses post-deploy.)`);
  }

  // ── V2 mesh: every chain with a filled newDispatcher ──────────────────────
  const v2Members: [string, ChainEntry][] = [];
  const v2Skipped: { network: string; chainId: string; reason: string }[] = [];
  for (const [chainId, e] of Object.entries(chains)) {
    const net = e.network ?? `chain-${chainId}`;
    if (!isSet(e.newDispatcher)) {
      v2Skipped.push({ network: net, chainId, reason: "newDispatcher blank/zero" });
      continue;
    }
    if (!isSet(e.safe)) {
      v2Skipped.push({ network: net, chainId, reason: "safe blank/zero" });
      continue;
    }
    if (!e.eid) {
      v2Skipped.push({ network: net, chainId, reason: "eid missing" });
      continue;
    }
    v2Members.push([chainId, e]);
  }

  // ── V3 mesh: every chain with a filled newDispatcherV3 ────────────────────
  const v3Members: [string, ChainEntry][] = [];
  const v3Skipped: { network: string; chainId: string; reason: string }[] = [];
  for (const [chainId, e] of Object.entries(chains)) {
    const net = e.network ?? `chain-${chainId}`;
    if (!isSet(e.newDispatcherV3)) continue; // not a V3 chain (or not filled) — silently out of V3 mesh
    if (!isSet(e.safe)) {
      v3Skipped.push({ network: net, chainId, reason: "safe blank/zero" });
      continue;
    }
    if (!e.eid) {
      v3Skipped.push({ network: net, chainId, reason: "eid missing" });
      continue;
    }
    v3Members.push([chainId, e]);
  }

  const generated: string[] = [];
  let v2Wires = 0;
  let v3Wires = 0;

  // ── Emit V2 batches ───────────────────────────────────────────────────────
  if (v2Members.length >= 2) {
    for (const [chainId, e] of v2Members) {
      const { batch, wires } = buildMeshBatch(
        "V2", chainId, e, v2Members, (x) => x.newDispatcher,
      );
      const outPath = path.join(SAFE_DIR, `${e.network}-phase2-peers-batch.json`);
      fs.writeFileSync(outPath, JSON.stringify(batch, null, 2) + "\n");
      v2Wires += wires;
      generated.push(
        `${e.network.padEnd(12)} chainId ${chainId.padEnd(7)} V2  ${wires
          .toString()
          .padStart(2)} wires -> ${path.relative(process.cwd(), outPath)}`,
      );
    }
  }

  // ── Emit V3 batches (separate mesh) ───────────────────────────────────────
  if (v3Members.length >= 2) {
    for (const [chainId, e] of v3Members) {
      const { batch, wires } = buildMeshBatch(
        "V3", chainId, e, v3Members, (x) => x.newDispatcherV3 as string,
      );
      const outPath = path.join(SAFE_DIR, `${e.network}-phase2-peers-v3-batch.json`);
      fs.writeFileSync(outPath, JSON.stringify(batch, null, 2) + "\n");
      v3Wires += wires;
      generated.push(
        `${e.network.padEnd(12)} chainId ${chainId.padEnd(7)} V3  ${wires
          .toString()
          .padStart(2)} wires -> ${path.relative(process.cwd(), outPath)}`,
      );
    }
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  const n2 = v2Members.length;
  const n3 = v3Members.length;
  console.log(`\n── GENERATED (${generated.length} batch file(s)) ──`);
  if (generated.length === 0) console.log("  (none)");
  for (const g of generated) console.log("  " + g);

  console.log(`\n── V2 MESH ──`);
  console.log(`  chains wired : ${n2}`);
  console.log(`  wires emitted: ${v2Wires}   (expected n*(n-1) = ${n2 * (n2 - 1)})`);
  if (n2 === 1) console.log(`  NOTE: only 1 V2 chain filled — nothing to wire (need >= 2).`);

  console.log(`\n── V3 MESH (arbitrum / base / polygon only) ──`);
  console.log(`  chains wired : ${n3}`);
  console.log(`  wires emitted: ${v3Wires}   (expected n*(n-1) = ${n3 * (n3 - 1)})`);
  if (n3 === 1) console.log(`  NOTE: only 1 V3 chain filled — nothing to wire (need >= 2).`);

  const skipLines = [...v2Skipped];
  console.log(`\n── SKIPPED — V2 mesh (${v2Skipped.length}) ──`);
  if (skipLines.length === 0) console.log("  (none)");
  for (const s of v2Skipped) {
    console.log(`  ${s.network.padEnd(12)} chainId ${s.chainId.padEnd(7)} — ${s.reason}`);
  }
  if (v3Skipped.length) {
    console.log(`\n── SKIPPED — V3 mesh (${v3Skipped.length}) ──`);
    for (const s of v3Skipped) {
      console.log(`  ${s.network.padEnd(12)} chainId ${s.chainId.padEnd(7)} — ${s.reason}`);
    }
  }

  console.log(`\n── HOW TO RUN POST-DEPLOY ──`);
  console.log(`  1. cp scripts/safe/phase2-addresses.template.json scripts/safe/phase2-addresses.json`);
  console.log(`  2. Deploy the new dispatcher(s) per chain; fill 'newDispatcher' for every`);
  console.log(`     chain and 'newDispatcherV3' for arbitrum/base/polygon in phase2-addresses.json.`);
  console.log(`     (Partial fill is fine — unfilled chains are skipped, so you can wire in waves.)`);
  console.log(`  3. npx ts-node scripts/safe/generate-phase2-peer-batches.ts`);
  console.log(`  4. Import each <network>-phase2-peers[-v3]-batch.json into the Safe Transaction`);
  console.log(`     Builder app on that chain and sign with the listed Safe (main`);
  console.log(`     0xC4c9..717a or in-house 0x40ea..b297 / Arbitrum+Polygon 0x4AeA..EC2F).`);
  console.log(`\nDone. ${generated.length} batch file(s) written.`);
}

main();
