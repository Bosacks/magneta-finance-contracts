/**
 * Sprint C — Generate Safe batches that wire CCTP V2 (Linea + Sonic) into
 * the existing CCTP mesh.
 *
 * Produces 7 batches:
 *
 *   Linea + Sonic (2 V2 chains, in-house Safes):
 *     batch = setCctp(adapter, localDomain)
 *           + setEidCctpDomainBatch([all 8 V1+V2 EID→domain pairs])
 *
 *   Polygon + Arbitrum + Base + Optimism + Avalanche (5 V1 chains, Safe UI):
 *     batch = setEidCctpDomainBatch([Linea EID→11, Sonic EID→13])
 *
 * After signing all 7, any token swap with USDC on the path can route via
 * CCTP between any pair of {Ethereum-like-V1, Linea, Sonic}.
 *
 * Usage: pnpm tsx scripts/deploy/generate-cctp-v2-setup-batches.ts
 */
import fs from "node:fs";
import path from "node:path";
import { Interface } from "ethers";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");
const OUT_DIR = path.join(__dirname, "..", "safe");

// Authoritative EID → CCTP domain map for the FULL mesh after Sprint C.
// V1 chains were already wired; V2 entries (Linea 11, Sonic 13) are the
// new additions every V1 chain needs to learn about.
const EID_TO_CCTP: Array<{ eid: number; domain: number; chainName: string }> = [
  { eid: 30101, domain: 0,  chainName: "ethereum" },
  { eid: 30106, domain: 1,  chainName: "avalanche" },
  { eid: 30111, domain: 2,  chainName: "optimism" },
  { eid: 30110, domain: 3,  chainName: "arbitrum" },
  { eid: 30184, domain: 6,  chainName: "base" },
  { eid: 30109, domain: 7,  chainName: "polygon" },
  { eid: 30183, domain: 11, chainName: "linea" },    // V2 — new
  { eid: 30332, domain: 13, chainName: "sonic" },    // V2 — new
];

const NEW_V2_ENTRIES = EID_TO_CCTP.filter((e) => e.domain === 11 || e.domain === 13);

const V2_CHAINS = [
  { name: "linea", chainId: 59144 },
  { name: "sonic", chainId: 146 },
];

const V1_CHAINS_TO_UPDATE = [
  { name: "polygon",   chainId: 137 },
  { name: "arbitrum",  chainId: 42161 },
  { name: "base",      chainId: 8453 },
  { name: "optimism",  chainId: 10 },
  { name: "avalanche", chainId: 43114 },
];

const GATEWAY_IFACE = new Interface([
  "function setCctp(address messenger, uint32 _localDomain)",
  "function setEidCctpDomainBatch(uint32[] eids, uint32[] domains)",
]);

interface ContractsDeployment {
  network: string;
  chainId: string;
  gnosisSafe: string;
  contracts?: { MagnetaGateway?: string };
}

interface V2AdapterDeployment {
  network: string;
  adapter: string;
  cctpDomain: number;
}

function readContractsDeployment(name: string): ContractsDeployment {
  const p = path.join(DEPLOY_DIR, `${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`Missing deployment: ${p}`);
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function readV2AdapterDeployment(name: string): V2AdapterDeployment {
  const p = path.join(DEPLOY_DIR, `${name}-cctp-v2-adapter.json`);
  if (!fs.existsSync(p)) {
    throw new Error(
      `Missing adapter deployment: ${p} — run deployCctpV2Adapter.ts --network ${name} first.`,
    );
  }
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function writeBatch(filename: string, batch: object) {
  if (!fs.existsSync(OUT_DIR)) fs.mkdirSync(OUT_DIR, { recursive: true });
  const p = path.join(OUT_DIR, filename);
  fs.writeFileSync(p, JSON.stringify(batch, null, 2));
  console.log(`  → ${p}`);
}

function main() {
  // ─── V2 chains: full setup (setCctp + setEidCctpDomainBatch) ────────────
  console.log(`\n── V2 chains (Linea + Sonic): full setup batches ──`);
  for (const { name, chainId } of V2_CHAINS) {
    const dep = readContractsDeployment(name);
    const gateway = dep.contracts?.MagnetaGateway;
    if (!gateway) throw new Error(`No MagnetaGateway in ${name}.json`);
    const safe = dep.gnosisSafe;
    const adapter = readV2AdapterDeployment(name);

    const setCctpData = GATEWAY_IFACE.encodeFunctionData("setCctp", [
      adapter.adapter, adapter.cctpDomain,
    ]);
    const setEidData = GATEWAY_IFACE.encodeFunctionData("setEidCctpDomainBatch", [
      EID_TO_CCTP.map((e) => e.eid),
      EID_TO_CCTP.map((e) => e.domain),
    ]);

    const batch = {
      version: "1.0",
      chainId: String(chainId),
      createdAt: 1780500000,
      meta: {
        name: `Magneta CCTP V2 setup — ${name}`,
        description:
          `Sprint C setup for ${name}. Wires the CctpV2Adapter ` +
          `(${adapter.adapter}) as the Gateway's cctpMessenger (local ` +
          `domain ${adapter.cctpDomain}) and seeds the EID→CCTP domain ` +
          `map with all 8 V1+V2 chains so this chain can route to any ` +
          `CCTP destination. Sign with in-house Safe ${safe}.`,
      },
      transactions: [
        { to: gateway, value: "0", data: setCctpData, contractMethod: null, contractInputsValues: null },
        { to: gateway, value: "0", data: setEidData,  contractMethod: null, contractInputsValues: null },
      ],
    };
    writeBatch(`cctp-v2-setup-${name}-batch.json`, batch);
  }

  // ─── V1 chains: add only the 2 new V2 entries ───────────────────────────
  console.log(`\n── V1 chains: add Linea + Sonic to EID→CCTP map ──`);
  for (const { name, chainId } of V1_CHAINS_TO_UPDATE) {
    const dep = readContractsDeployment(name);
    const gateway = dep.contracts?.MagnetaGateway;
    if (!gateway) throw new Error(`No MagnetaGateway in ${name}.json`);
    const safe = dep.gnosisSafe;

    const setEidData = GATEWAY_IFACE.encodeFunctionData("setEidCctpDomainBatch", [
      NEW_V2_ENTRIES.map((e) => e.eid),
      NEW_V2_ENTRIES.map((e) => e.domain),
    ]);

    const batch = {
      version: "1.0",
      chainId: String(chainId),
      createdAt: 1780500000,
      meta: {
        name: `Magneta CCTP V2 extend — ${name}`,
        description:
          `Sprint C extension for ${name}. Adds Linea (EID 30183 → CCTP ` +
          `domain 11) and Sonic (EID 30332 → CCTP domain 13) to the ` +
          `Gateway's EID→CCTP map so users on ${name} can route USDC ` +
          `via CCTP to the new V2 chains. Sign with Safe ${safe}.`,
      },
      transactions: [
        { to: gateway, value: "0", data: setEidData, contractMethod: null, contractInputsValues: null },
      ],
    };
    writeBatch(`cctp-v2-extend-${name}-batch.json`, batch);
  }

  console.log(`\n── DONE ──`);
  console.log(`Generated 7 batches: 2 setup (Linea/Sonic) + 5 extend (V1 chains).`);
  console.log(`\nExecute order (Safe UI for V1, execBatch.ts for in-house Safes):`);
  console.log(`  1. Linea setup     → cctp-v2-setup-linea-batch.json  (in-house Safe)`);
  console.log(`  2. Sonic setup     → cctp-v2-setup-sonic-batch.json  (in-house Safe)`);
  console.log(`  3. Polygon extend  → cctp-v2-extend-polygon-batch.json  (Safe UI 0x4AeA…)`);
  console.log(`  4. Arbitrum extend → cctp-v2-extend-arbitrum-batch.json (Safe UI 0x4AeA…)`);
  console.log(`  5. Base/Op/Avax    → 3× Safe UI batches (0xC4c9…)`);
}

main();
