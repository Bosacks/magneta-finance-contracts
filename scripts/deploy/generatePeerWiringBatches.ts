/**
 * Generate Safe Tx Builder batches that wire LayerZero peers across all
 * mainnet chains where MagnetaGateway + MagnetaBridgeOApp are deployed.
 *
 * For each mainnet chain N, the batch contains, for every OTHER mainnet
 * chain M:
 *
 *   1. MagnetaGateway[N].setPeer(eid_M, peerBytes32(MagnetaGateway[M]))
 *   2. MagnetaBridgeOApp[N].setPeer(eid_M, peerBytes32(MagnetaBridgeOApp[M]))
 *   3. MagnetaGateway[N].setEidMapping(eid_M, chainId_M)
 *
 * → 18 remote peers × 3 calls = 54 transactions per chain (manageable in
 *   the Safe Tx Builder UI; Safe enforces a soft cap of ~100 calls/batch).
 *
 * Output files: scripts/safe/<chain>-peerWiring-batch.json
 *
 * Run from repo root:
 *   pnpm tsx scripts/deploy/generatePeerWiringBatches.ts
 *
 * The script reads deployments/*.json (mainnet only — skips hardhat,
 * arbitrumSepolia, baseSepolia, plasma-v2) and never touches the chain;
 * generation is fully offline. Each chain owner signs + executes its own
 * batch on its Safe. Order doesn't matter — each chain's setPeer is
 * idempotent and independent.
 */
import fs from "node:fs";
import path from "node:path";

const REPO_ROOT      = path.join(__dirname, "..", "..");
const DEPLOY_DIR     = path.join(REPO_ROOT, "deployments");
const OUTPUT_DIR     = path.join(REPO_ROOT, "scripts", "safe");

// Mainnet deployments only — testnets and historical files are skipped.
const SKIP_FILES = new Set([
  "hardhat.json",
  "arbitrumSepolia.json",
  "baseSepolia.json",
  "plasma-v2.json", // older Plasma deploy superseded by plasma.json
]);

interface Deployment {
  network: string;
  chainId: string;
  gnosisSafe?: string;
  chainConfig: {
    lzEid: number | null;
    [k: string]: unknown;
  };
  contracts: {
    MagnetaGateway?: string;
    MagnetaBridgeOApp?: string;
    [k: string]: string | undefined;
  };
}

interface ChainInfo {
  network:    string;
  chainId:    number;
  lzEid:      number;
  gateway:    string;
  bridgeOApp: string;
  safe:       string;
}

function loadAllChains(): ChainInfo[] {
  const files = fs.readdirSync(DEPLOY_DIR).filter((f) =>
    f.endsWith(".json") && !SKIP_FILES.has(f),
  );
  const chains: ChainInfo[] = [];
  for (const file of files) {
    const raw  = fs.readFileSync(path.join(DEPLOY_DIR, file), "utf-8");
    const dep  = JSON.parse(raw) as Deployment;
    const gw   = dep.contracts.MagnetaGateway;
    const br   = dep.contracts.MagnetaBridgeOApp;
    const eid  = dep.chainConfig?.lzEid;
    const safe = dep.gnosisSafe;
    if (!gw || !br || !eid || !safe) {
      console.log(`  skip ${dep.network}: missing Gateway/Bridge/EID/Safe`);
      continue;
    }
    chains.push({
      network:    dep.network,
      chainId:    parseInt(dep.chainId, 10),
      lzEid:      eid,
      gateway:    gw,
      bridgeOApp: br,
      safe,
    });
  }
  return chains;
}

/** Pad an EVM address (20 bytes) to a LayerZero-style 32-byte hex. */
function peerBytes32(addr: string): string {
  const clean = addr.toLowerCase().replace(/^0x/, "");
  if (clean.length !== 40) throw new Error(`bad address: ${addr}`);
  return "0x" + "0".repeat(24) + clean;
}

interface SafeTx {
  to:    string;
  value: string;
  data:  null;
  contractMethod: {
    inputs: { internalType: string; name: string; type: string }[];
    name:    string;
    payable: boolean;
  };
  contractInputsValues: Record<string, string>;
}

function setPeerTx(target: string, dstEid: number, peer: string): SafeTx {
  return {
    to:    target,
    value: "0",
    data:  null,
    contractMethod: {
      inputs: [
        { internalType: "uint32", name: "_eid",  type: "uint32" },
        { internalType: "bytes32", name: "_peer", type: "bytes32" },
      ],
      name:    "setPeer",
      payable: false,
    },
    contractInputsValues: {
      _eid:  String(dstEid),
      _peer: peer,
    },
  };
}

function setEidMappingTx(gateway: string, dstEid: number, dstChainId: number): SafeTx {
  return {
    to:    gateway,
    value: "0",
    data:  null,
    contractMethod: {
      inputs: [
        { internalType: "uint32", name: "_eid",     type: "uint32"  },
        { internalType: "uint256", name: "_chainId", type: "uint256" },
      ],
      name:    "setEidMapping",
      payable: false,
    },
    contractInputsValues: {
      _eid:     String(dstEid),
      _chainId: String(dstChainId),
    },
  };
}

function buildBatchForChain(self: ChainInfo, peers: ChainInfo[]) {
  const txs: SafeTx[] = [];
  for (const peer of peers) {
    if (peer.network === self.network) continue;
    // 1. Gateway peer
    txs.push(setPeerTx(self.gateway, peer.lzEid, peerBytes32(peer.gateway)));
    // 2. BridgeOApp peer
    txs.push(setPeerTx(self.bridgeOApp, peer.lzEid, peerBytes32(peer.bridgeOApp)));
    // 3. EID ↔ chainId mapping (Gateway only)
    txs.push(setEidMappingTx(self.gateway, peer.lzEid, peer.chainId));
  }
  const remoteCount = peers.length - 1;
  return {
    version:   "1.0",
    chainId:   String(self.chainId),
    createdAt: Date.now(),
    meta: {
      name: `Magneta — peer wiring (${self.network})`,
      description:
        `Wire LayerZero V2 peers on MagnetaGateway and MagnetaBridgeOApp for ${remoteCount} ` +
        `remote chains, plus EID↔chainId mappings on the Gateway. After this batch, ` +
        `${self.network} can send/receive cross-chain messages from every other Magneta-deployed ` +
        `mainnet chain. Total: ${txs.length} txs (${remoteCount} × 3).`,
      txBuilderVersion: "1.17.0",
      createdFromSafeAddress: self.safe,
      createdFromOwnerAddress: "",
    },
    transactions: txs,
  };
}

function main() {
  const chains = loadAllChains();
  console.log(`Found ${chains.length} mainnet chains with Bridge+Gateway:\n`);
  for (const c of chains) console.log(`  ${c.network.padEnd(12)} eid=${c.lzEid} chainId=${c.chainId} safe=${c.safe}`);
  console.log();

  for (const self of chains) {
    const batch    = buildBatchForChain(self, chains);
    const outFile  = path.join(OUTPUT_DIR, `${self.network}-peerWiring-batch.json`);
    fs.writeFileSync(outFile, JSON.stringify(batch, null, 2) + "\n");
    console.log(`  wrote ${path.relative(REPO_ROOT, outFile)}  (${batch.transactions.length} txs)`);
  }
}

main();
