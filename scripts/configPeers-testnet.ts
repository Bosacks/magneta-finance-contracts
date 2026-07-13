/**
 * Register LZ peers between all deployed testnet MagnetaGateways.
 *
 * Run AFTER deploy-testnet.ts on every testnet chain.
 *
 * Usage:
 *   pnpm hardhat run scripts/configPeers-testnet.ts --network baseSepolia
 *   pnpm hardhat run scripts/configPeers-testnet.ts --network arbitrumSepolia
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const DEPLOY_DIR = path.join(__dirname, "..", "deployments");

const NETWORK_EID: Record<string, number> = {
  baseSepolia: 40245,
  arbitrumSepolia: 40231,
};

const ALL_NETWORKS = Object.keys(NETWORK_EID);

function loadDeployment(net: string) {
  const filePath = path.join(DEPLOY_DIR, `${net}.json`);
  if (!fs.existsSync(filePath)) return null;
  return JSON.parse(fs.readFileSync(filePath, "utf-8"));
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const currentNet = network.name;
  console.log(`\nConfiguring testnet peers on ${currentNet} (deployer: ${deployer.address})\n`);

  const currentDeploy = loadDeployment(currentNet);
  if (!currentDeploy) throw new Error(`No deployment for ${currentNet}`);

  const gatewayAddr = currentDeploy.contracts.MagnetaGateway;
  if (!gatewayAddr) throw new Error(`No MagnetaGateway in ${currentNet} deployment`);

  const gateway = await ethers.getContractAt("MagnetaGateway", gatewayAddr);

  const bridgeAddr = currentDeploy.contracts.MagnetaBridgeOApp;
  const bridge = bridgeAddr ? await ethers.getContractAt("MagnetaBridgeOApp", bridgeAddr) : null;

  for (const peerNet of ALL_NETWORKS) {
    if (peerNet === currentNet) continue;

    const peerDeploy = loadDeployment(peerNet);
    if (!peerDeploy) {
      console.log(`  ⚠ Skipping ${peerNet}: no deployment`);
      continue;
    }

    const peerGateway = peerDeploy.contracts.MagnetaGateway;
    const peerBridge = peerDeploy.contracts.MagnetaBridgeOApp;
    const dstEid = NETWORK_EID[peerNet];

    if (!peerGateway) continue;

    const peerBytes32 = ethers.zeroPadValue(peerGateway, 32);
    const tx = await gateway.setPeer(dstEid, peerBytes32);
    await tx.wait();
    console.log(`  ✓ Gateway peer: ${peerNet} (EID ${dstEid}) → ${peerGateway}`);

    if (bridge && peerBridge) {
      const bridgePeer = ethers.zeroPadValue(peerBridge, 32);
      const tx2 = await bridge.setPeer(dstEid, bridgePeer);
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
    const tx = await gateway.setEidMapping(dstEid, dstChainId);
    await tx.wait();
    console.log(`  ✓ EID ${dstEid} → chainId ${dstChainId} (${peerNet})`);
  }

  console.log("\nPeer configuration complete for", currentNet);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
