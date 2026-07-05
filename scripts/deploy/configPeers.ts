/**
 * Register LZ peers between all deployed MagnetaGateways.
 *
 * Run this AFTER deployAll.ts has been executed on every chain.
 * Reads gateway addresses from deployments/<network>.json files.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/configPeers.ts --network base
 *   pnpm hardhat run scripts/deploy/configPeers.ts --network arbitrum
 *   pnpm hardhat run scripts/deploy/configPeers.ts --network polygon
 *
 * Each run registers all OTHER chains as peers on the current chain.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

// Network name → LZ EID mapping (all 20 redeploy-wave mainnet chains).
const NETWORK_EID: Record<string, number> = {
  arbitrum: 30110,
  avalanche: 30106,
  base: 30184,
  bsc: 30102,
  celo: 30125,
  flare: 30295,
  gnosis: 30145,
  linea: 30183,
  mantle: 30181,
  optimism: 30111,
  polygon: 30109,
  sei: 30280,
  berachain: 30362,
  katana: 30375,
  monad: 30390,
  plasma: 30383,
  sonic: 30332,
  unichain: 30320,
  abstract: 30324,
  cronos: 30359,
};

// All networks to register as peers
const ALL_NETWORKS = Object.keys(NETWORK_EID);

interface Deployment {
  network: string;
  chainId: string;
  contracts: Record<string, string>;
}

function loadDeployment(net: string): Deployment | null {
  const filePath = path.join(DEPLOY_DIR, `${net}.json`);
  if (!fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, "utf-8"));
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const currentNet = network.name;
  console.log(`\nConfiguring peers on ${currentNet} (deployer: ${deployer.address})\n`);

  // Local nonce sequencing — fast chains / EIP-7702 delegated accounts lag on
  // the public-RPC pending nonce and reject the next tx as "nonce too low".
  const mgr = new ethers.NonceManager(deployer);
  // Optional legacy gas-price floor (BSC rejects a 1-wei tip): WIRE_GAS_GWEI=1.
  const ov: Record<string, bigint> = process.env.WIRE_GAS_GWEI
    ? { gasPrice: ethers.parseUnits(process.env.WIRE_GAS_GWEI, "gwei") }
    : {};

  const currentDeploy = loadDeployment(currentNet);
  if (!currentDeploy) {
    throw new Error(`No deployment found for ${currentNet}. Run deployAll.ts first.`);
  }

  const gatewayAddr = currentDeploy.contracts.MagnetaGateway;
  if (!gatewayAddr) {
    throw new Error(`MagnetaGateway not found in ${currentNet} deployment.`);
  }

  const gateway = await ethers.getContractAt("MagnetaGateway", gatewayAddr, mgr);
  const bridgeAddr = currentDeploy.contracts.MagnetaBridgeOApp;
  const bridge = bridgeAddr ? await ethers.getContractAt("MagnetaBridgeOApp", bridgeAddr, mgr) : null;

  for (const peerNet of ALL_NETWORKS) {
    if (peerNet === currentNet) continue;

    const peerDeploy = loadDeployment(peerNet);
    if (!peerDeploy) {
      console.log(`  ⚠ Skipping ${peerNet}: no deployment file found`);
      continue;
    }

    const peerGateway = peerDeploy.contracts.MagnetaGateway;
    const peerBridge = peerDeploy.contracts.MagnetaBridgeOApp;
    const dstEid = NETWORK_EID[peerNet];

    if (!peerGateway) {
      console.log(`  ⚠ Skipping ${peerNet}: no MagnetaGateway in deployment`);
      continue;
    }

    // Register gateway peer
    const peerBytes32 = ethers.zeroPadValue(peerGateway, 32);
    const tx = await gateway.setPeer(dstEid, peerBytes32, ov);
    await tx.wait();
    console.log(`  ✓ Gateway peer: ${peerNet} (EID ${dstEid}) → ${peerGateway}`);

    // Register bridge peer
    if (bridge && peerBridge) {
      const bridgePeer = ethers.zeroPadValue(peerBridge, 32);
      const tx2 = await bridge.setPeer(dstEid, bridgePeer, ov);
      await tx2.wait();
      console.log(`  ✓ Bridge peer:  ${peerNet} (EID ${dstEid}) → ${peerBridge}`);
    }
  }

  // EID ↔ Chain ID mappings
  console.log("\nSetting EID ↔ chainId mappings...");
  for (const peerNet of ALL_NETWORKS) {
    if (peerNet === currentNet) continue;
    const peerDeploy = loadDeployment(peerNet);
    if (!peerDeploy) continue;
    const dstEid = NETWORK_EID[peerNet];
    const dstChainId = parseInt(peerDeploy.chainId);
    const tx = await gateway.setEidMapping(dstEid, dstChainId, ov);
    await tx.wait();
    console.log(`  ✓ EID ${dstEid} → chainId ${dstChainId} (${peerNet})`);
  }

  console.log("\nPeer configuration complete for", currentNet);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
