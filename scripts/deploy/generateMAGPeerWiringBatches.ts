/**
 * Generate Safe Tx Builder batches that wire LayerZero peers between every
 * (chain × chain) pair for the MAG OFT.
 *
 * For each chain N, the batch contains, for every OTHER chain M:
 *   MAG[N].setPeer(eid_M, peerBytes32(MAG[M]))
 *
 * → 17 remote peers per chain × 18 chains = 306 setPeer calls total, split
 *   across 18 Safe batches. The deployer EOA (or in-house Safe) is the
 *   owner of MagnetaERC20OFT contracts and can call setPeer.
 *
 * Output: scripts/safe/<chain>-MAG-peerWiring-batch.json
 *
 *   pnpm tsx scripts/deploy/generateMAGPeerWiringBatches.ts
 *
 * Reads deployments/<chain>.json → contracts.MAG. Skips chains where MAG
 * isn't yet deployed.
 */
import fs from "node:fs";
import path from "node:path";

const REPO_ROOT  = path.join(__dirname, "..", "..");
const DEPLOY_DIR = path.join(REPO_ROOT, "deployments");
const OUTPUT_DIR = path.join(REPO_ROOT, "scripts", "safe");

const SKIP_FILES = new Set([
  "hardhat.json",
  "arbitrumSepolia.json",
  "baseSepolia.json",
  "plasma-v2.json",
]);

interface ChainDeployment {
  network: string;
  chainId: number | string;
  /** LayerZero V2 endpoint id, e.g. 30109 for Polygon. */
  eid?:    number;
  contracts: {
    MAG?: string;
  };
}

function peerBytes32(addr: string): string {
  // 32-byte zero-padded address = standard LayerZero peer encoding
  const clean = addr.toLowerCase().replace(/^0x/, "");
  return "0x" + clean.padStart(64, "0");
}

function setPeerCalldata(eid: number, peer: string): string {
  // Function selector for setPeer(uint32,bytes32) = 0x3400288b
  // (computed via keccak256("setPeer(uint32,bytes32)").slice(0,4))
  const sel = "0x3400288b";
  const eidPadded  = eid.toString(16).padStart(64, "0");
  const peerPadded = peer.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  return sel + eidPadded + peerPadded;
}

function main() {
  const files = fs.readdirSync(DEPLOY_DIR).filter(
    (f) => f.endsWith(".json") && !SKIP_FILES.has(f) && !f.includes("-magneta-amm")
  );

  const chains: ChainDeployment[] = [];
  for (const f of files) {
    const dep = JSON.parse(fs.readFileSync(path.join(DEPLOY_DIR, f), "utf8")) as ChainDeployment;
    if (!dep.contracts?.MAG) continue;
    if (typeof dep.eid !== "number") continue;
    chains.push(dep);
  }

  console.log(`Found ${chains.length} chains with MAG deployed: ${chains.map((c) => c.network).join(", ")}\n`);

  if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });

  for (const src of chains) {
    const transactions = chains
      .filter((dst) => dst.eid !== src.eid)
      .map((dst) => ({
        to: src.contracts.MAG!,
        value: "0",
        data: setPeerCalldata(dst.eid!, peerBytes32(dst.contracts.MAG!)),
        contractMethod: {
          inputs: [
            { name: "_eid",    type: "uint32",  internalType: "uint32"  },
            { name: "_peer",   type: "bytes32", internalType: "bytes32" },
          ],
          name: "setPeer",
          payable: false,
        },
        contractInputsValues: {
          _eid:  String(dst.eid),
          _peer: peerBytes32(dst.contracts.MAG!),
        },
      }));

    const batch = {
      version: "1.0",
      chainId: String(src.chainId),
      createdAt: Date.now(),
      meta: {
        name: `MAG peer wiring — ${src.network}`,
        description: `setPeer for MAG OFT against ${transactions.length} remote chains`,
        txBuilderVersion: "1.16.5",
      },
      transactions,
    };

    const outPath = path.join(OUTPUT_DIR, `${src.network}-MAG-peerWiring-batch.json`);
    fs.writeFileSync(outPath, JSON.stringify(batch, null, 2));
    console.log(`  ✓ ${src.network}: ${transactions.length} setPeer calls → ${path.basename(outPath)}`);
  }

  console.log(`\nDone. Execute each batch via Safe Tx Builder (or directly if owner is EOA).`);
}

main();
