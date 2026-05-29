/**
 * Deploy LPSourceWrapper on the current chain.
 *
 * Reads the v3 MagnetaGateway + V2 router + USDC from
 * deployments/<network>.json + CHAIN_CONFIG. Persists the wrapper address
 * back into the deployment file under `contracts.LPSourceWrapper`.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployLPSourceWrapper.ts --network base
 *   pnpm hardhat run scripts/deploy/deployLPSourceWrapper.ts --network polygon
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG } from "./chainConfig";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg?.usdc || !cfg.defaultRouter) {
    throw new Error(`Chain ${chainId} missing usdc / defaultRouter`);
  }

  const deployPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  const deployment = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const contracts = deployment.contracts as Record<string, string>;
  const gatewayAddr = contracts.MagnetaGateway;
  if (!gatewayAddr) throw new Error(`MagnetaGateway not found in ${deployPath}`);

  console.log(`\n── Deploy LPSourceWrapper on ${network.name} (chainId ${chainId}) ──`);
  console.log(`   deployer: ${deployer.address}`);
  console.log(`   Gateway : ${gatewayAddr}`);
  console.log(`   USDC    : ${cfg.usdc}`);
  console.log(`   Router  : ${cfg.defaultRouter}`);

  const Wrapper = await ethers.getContractFactory("LPSourceWrapper");
  const wrapper = await Wrapper.deploy(gatewayAddr, cfg.usdc, cfg.defaultRouter);
  await wrapper.waitForDeployment();
  const addr = await wrapper.getAddress();
  console.log(`   ✓ LPSourceWrapper: ${addr}`);

  // Sanity reads.
  const wnative = await wrapper.wnative();
  console.log(`   wnative (from router.WETH()): ${wnative}`);

  // Persist
  contracts.LPSourceWrapper = addr;
  deployment.timestamp = new Date().toISOString();
  deployment.notes = (deployment.notes ?? []) as string[];
  deployment.notes.push(
    `${new Date().toISOString().slice(0, 10)} — LPSourceWrapper deployed (V1.1 native→USDC source-side entry point).`,
  );
  fs.writeFileSync(deployPath, JSON.stringify(deployment, null, 2) + "\n");
  console.log(`   ✓ Updated ${deployPath}`);

  console.log(`\n── DONE ──`);
  console.log(`   Update tokens repo lib/constants/gatewayChains.ts:`);
  console.log(`     chainId ${chainId} → lpSourceWrapper: '${addr}'`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
