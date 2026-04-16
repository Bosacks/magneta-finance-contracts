/**
 * Sanity-check deployed addresses.
 *
 * For every contract in deployments/<network>.json:
 *   - confirm code exists at the address (eth_getCode != "0x")
 *   - if the contract exposes owner(), check it matches `admin`
 *
 * Usage:
 *   pnpm ts-node scripts/verify-deployed.ts arbitrumSepolia
 *   pnpm ts-node scripts/verify-deployed.ts baseSepolia
 */
import { ethers } from "ethers";
import fs from "node:fs";
import path from "node:path";

const RPC_URLS: Record<string, string> = {
  baseSepolia: process.env.BASE_TESTNET_RPC_URL || "https://sepolia.base.org",
  base: process.env.BASE_MAINNET_RPC_URL || "https://mainnet.base.org",
  arbitrumSepolia: process.env.ARBITRUM_SEPOLIA_RPC_URL || "https://sepolia-rollup.arbitrum.io/rpc",
  arbitrum: process.env.ARBITRUM_MAINNET_RPC_URL || "https://arb1.arbitrum.io/rpc",
  polygon: process.env.POLYGON_MAINNET_RPC_URL || "https://polygon-rpc.com",
  polygonAmoy: process.env.POLYGON_AMOY_RPC_URL || "https://rpc-amoy.polygon.technology",
  optimismSepolia: process.env.OPTIMISM_SEPOLIA_RPC_URL || "https://sepolia.optimism.io",
  celoSepolia: process.env.CELO_SEPOLIA_RPC_URL || "https://forno.celo-sepolia.celo-testnet.org",
};

const OWNER_ABI = ["function owner() view returns (address)"];

interface Deployment {
  network: string;
  chainId: string;
  deployer: string;
  admin: string;
  contracts: Record<string, string>;
}

async function main() {
  const network = process.argv[2];
  if (!network) {
    console.error("usage: verify-deployed.ts <network>");
    process.exit(1);
  }

  const filePath = path.join(__dirname, "..", "deployments", `${network}.json`);
  if (!fs.existsSync(filePath)) {
    console.error(`No deployment file: ${filePath}`);
    process.exit(1);
  }

  const deployment: Deployment = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const rpcUrl = RPC_URLS[network];
  if (!rpcUrl) {
    console.error(`No RPC URL for network "${network}". Add it to RPC_URLS in this script.`);
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const onChainId = (await provider.getNetwork()).chainId.toString();
  if (onChainId !== deployment.chainId) {
    console.error(`chainId mismatch: deployment=${deployment.chainId} rpc=${onChainId}`);
    process.exit(2);
  }

  console.log(`\nVerifying ${network} (chainId ${onChainId})...\n`);

  let fail = 0;
  for (const [name, addr] of Object.entries(deployment.contracts)) {
    const code = await provider.getCode(addr);
    if (code === "0x") {
      console.error(`  ✗ ${name} @ ${addr} — no code`);
      fail++;
      continue;
    }

    let ownerTag = "";
    try {
      const c = new ethers.Contract(addr, OWNER_ABI, provider);
      const owner: string = await c.owner();
      ownerTag =
        owner.toLowerCase() === deployment.admin.toLowerCase()
          ? " (admin ok)"
          : ` (owner=${owner} ≠ admin=${deployment.admin})`;
      if (owner.toLowerCase() !== deployment.admin.toLowerCase()) fail++;
    } catch {
      // No owner() — fine (mocks, lending, etc).
    }
    console.log(`  ✓ ${name} @ ${addr}${ownerTag}`);
  }

  if (fail > 0) {
    console.error(`\n${fail} issue(s) on ${network}`);
    process.exit(3);
  }
  console.log(`\nAll good on ${network}.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
