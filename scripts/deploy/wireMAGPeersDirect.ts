/**
 * Wire LayerZero peers between every (chain × chain) pair for the MAG OFT —
 * direct EOA calls, no Safe batches.
 *
 * Run from the chain whose peers you want to set. Reads ALL chains' MAG
 * addresses from `deployments/*.json` and `chainConfig.ts` for EIDs.
 *
 *   pnpm hardhat run scripts/deploy/wireMAGPeersDirect.ts --network polygon
 *   pnpm hardhat run scripts/deploy/wireMAGPeersDirect.ts --network base
 *   ...
 *
 * Idempotent — checks the current peer for each remote and skips if already
 * wired. Outputs which peers were set / skipped.
 */
import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");
const SKIP_FILES = new Set([
  "hardhat.json", "arbitrumSepolia.json", "baseSepolia.json", "plasma-v2.json",
]);

const OFT_ABI = [
  "function owner() view returns (address)",
  "function peers(uint32 eid) view returns (bytes32)",
  "function setPeer(uint32 _eid, bytes32 _peer) external",
] as const;

function peerBytes32(addr: string): string {
  return "0x" + addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");
}

interface ChainEntry {
  network: string;
  chainId: number;
  eid: number;
  mag: string;
}

/// LayerZero V2 endpoint IDs per chain (mirrors apps/web/lib/constants/bridgeAddresses
/// in the DEX repo). Hard-coded because the contracts-repo deployments JSON
/// files don't include the eid field.
const EID_BY_CHAIN_ID: Record<number, number> = {
  137:    30109, // Polygon
  8453:   30184, // Base
  42161:  30110, // Arbitrum
  10:     30111, // Optimism
  56:     30102, // BSC
  43114:  30106, // Avalanche
  5000:   30181, // Mantle
  42220:  30125, // Celo
  9745:   30383, // Plasma
  130:    30320, // Unichain
  747474: 30375, // Katana
  14:     30295, // Flare
  1329:   30280, // Sei
  143:    30390, // Monad
  59144:  30183, // Linea
  100:    30145, // Gnosis
  146:    30332, // Sonic
  80094:  30362, // Berachain
  2741:   30324, // Abstract
};

function loadAllChains(): ChainEntry[] {
  const out: ChainEntry[] = [];
  const files = fs.readdirSync(DEPLOY_DIR).filter(
    (f) => f.endsWith(".json") && !SKIP_FILES.has(f) && !f.includes("-magneta-amm") && !f.includes("-mag.json")
  );
  for (const f of files) {
    const dep = JSON.parse(fs.readFileSync(path.join(DEPLOY_DIR, f), "utf8"));
    const mag: string | undefined = dep?.contracts?.MAG;
    const chainId = Number(dep?.chainId);
    const eid = EID_BY_CHAIN_ID[chainId];
    if (!mag || !eid || !chainId) continue;
    out.push({ network: dep.network ?? f.replace(".json", ""), chainId, eid, mag });
  }
  return out;
}

async function main() {
  const [signer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);

  const chains = loadAllChains();
  const self = chains.find((c) => c.chainId === chainId);
  if (!self) {
    throw new Error(`Current chain ${chainId} (${network.name}) doesn't have MAG deployed yet`);
  }

  console.log(`\nSigner       : ${signer.address}`);
  console.log(`Network      : ${self.network} (${chainId})`);
  console.log(`MAG (here)   : ${self.mag}`);
  console.log(`Targets      : ${chains.length - 1} remote chains\n`);

  const oft = new ethers.Contract(self.mag, OFT_ABI, signer);

  const owner: string = await oft.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer is NOT MAG owner. Owner: ${owner}. Use Safe batch instead.`);
  }

  let set = 0, skipped = 0, failed = 0;
  for (const remote of chains) {
    if (remote.chainId === chainId) continue;
    const targetPeer = peerBytes32(remote.mag);
    try {
      const current: string = await oft.peers(remote.eid);
      if (current.toLowerCase() === targetPeer.toLowerCase()) {
        console.log(`  ⏭  ${remote.network} (eid ${remote.eid}): already set`);
        skipped++;
        continue;
      }
      const tx = await oft.setPeer(remote.eid, targetPeer);
      console.log(`  → ${remote.network} (eid ${remote.eid}): tx ${tx.hash}`);
      await tx.wait();
      console.log(`     ✓ set`);
      set++;
    } catch (e: unknown) {
      const msg = e instanceof Error
        ? (e as Error & { shortMessage?: string }).shortMessage ?? e.message
        : String(e);
      console.warn(`  ✗ ${remote.network}: ${msg}`);
      failed++;
    }
  }

  console.log(`\nDone. set=${set} skipped=${skipped} failed=${failed}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
