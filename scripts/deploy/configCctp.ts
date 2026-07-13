/**
 * Configure CCTP (Circle Cross-Chain Transfer Protocol) on each gateway.
 *
 * Sets the TokenMessenger address and maps LZ EIDs → CCTP domains.
 * Run AFTER deployAll.ts on the current chain.
 *
 * IMPORTANT: Verify CCTP TokenMessenger addresses from Circle's official docs:
 * https://developers.circle.com/stablecoins/evm-smart-contracts
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/configCctp.ts --network base
 *   pnpm hardhat run scripts/deploy/configCctp.ts --network arbitrum
 *   pnpm hardhat run scripts/deploy/configCctp.ts --network polygon
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

// CCTP V1 TokenMessenger mainnet addresses (from Circle docs)
// ⚠ VERIFY BEFORE MAINNET — these must match Circle's deployed contracts
const CCTP_MESSENGER: Record<number, string> = {
  1:     "0xBd3fa81B58Ba92a82136038B25adec7066af3155", // Ethereum
  42161: "0x19330d10D9Cc8751218eaf51E8885D058642E08A", // Arbitrum
  8453:  "0x1682Ae6375C4E4A97e4B583BC394c861A46D8962", // Base
  137:   "0x9daF8c91AEFAE50b9c0E69629D3F6Ca40cA3B3FE", // Polygon
  10:    "0x2B4069517957735bE00ceE0fadAE88a26365528f", // Optimism
  43114: "0x6B25532e1060CE10cc3B0A99e5683b91BFDe6982", // Avalanche
};

// CCTP domain per chain
const CCTP_DOMAIN: Record<number, number> = {
  1:     0,  // Ethereum
  43114: 1,  // Avalanche
  10:    2,  // Optimism
  42161: 3,  // Arbitrum
  8453:  6,  // Base
  137:   7,  // Polygon
};

// LZ EID → CCTP domain for all known CCTP chains
const EID_TO_CCTP: Record<number, number> = {
  30101: 0,  // Ethereum
  30106: 1,  // Avalanche
  30111: 2,  // Optimism
  30110: 3,  // Arbitrum
  30184: 6,  // Base
  30109: 7,  // Polygon
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\nConfiguring CCTP on ${network.name} (chainId ${chainId})\n`);

  const deployPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  if (!fs.existsSync(deployPath)) {
    throw new Error(`No deployment found. Run deployAll.ts first.`);
  }
  const deployment = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const gatewayAddr = deployment.contracts.MagnetaGateway;
  if (!gatewayAddr) throw new Error("MagnetaGateway not found in deployment");

  const messenger = CCTP_MESSENGER[chainId];
  const localDomain = CCTP_DOMAIN[chainId];
  if (!messenger || localDomain === undefined) {
    throw new Error(`No CCTP config for chainId ${chainId}. Is this chain CCTP-supported?`);
  }

  const gateway = await ethers.getContractAt("MagnetaGateway", gatewayAddr);

  // Set CCTP messenger + local domain
  const tx1 = await gateway.setCctp(messenger, localDomain);
  await tx1.wait();
  console.log(`  ✓ CCTP messenger: ${messenger}`);
  console.log(`  ✓ Local CCTP domain: ${localDomain}`);

  // Map all destination EIDs → CCTP domains
  const eids: number[] = [];
  const domains: number[] = [];
  for (const [eid, domain] of Object.entries(EID_TO_CCTP)) {
    eids.push(Number(eid));
    domains.push(domain);
  }

  const tx2 = await gateway.setEidCctpDomainBatch(eids, domains);
  await tx2.wait();
  console.log(`  ✓ ${eids.length} EID→CCTP domain mappings set`);

  for (let i = 0; i < eids.length; i++) {
    console.log(`    EID ${eids[i]} → CCTP domain ${domains[i]}`);
  }

  console.log("\nCCTP configuration complete for", network.name);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
