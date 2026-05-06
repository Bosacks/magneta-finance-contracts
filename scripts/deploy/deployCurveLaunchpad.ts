/**
 * Deploy MagnetaCurveFactory on a single chain.
 *
 * Run once per chain:
 *   pnpm hardhat run scripts/deploy/deployCurveLaunchpad.ts --network polygon
 *   pnpm hardhat run scripts/deploy/deployCurveLaunchpad.ts --network base
 *   ...
 *
 * Reads `defaultRouter` and `feeVault` from chainConfig + deployments/{net}.json.
 * Writes the resulting factory address into deployments/{net}.json under
 * `contracts.MagnetaCurveFactory` so the frontend can pick it up.
 *
 * Skips chains that don't have a V2 router configured (Abstract, Berachain
 * for V1) — the curve launchpad needs `addLiquidityETH` for graduation.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG, FEE_VAULT } from "./chainConfig";

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No chain config for chainId ${chainId}`);
  if (!cfg.defaultRouter) {
    throw new Error(
      `Chain ${chainId} has no defaultRouter — V1 curve launchpad needs ` +
      `a UniV2-strict router for post-graduation LP migration. Skipping.`,
    );
  }

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`\nDeployer  : ${deployer.address}`);
  console.log(`Network   : ${network.name} (${chainId})`);
  console.log(`Balance   : ${ethers.formatEther(balance)} native`);
  console.log(`Router    : ${cfg.defaultRouter}`);
  console.log(`FeeVault  : ${FEE_VAULT}\n`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  const Factory = await ethers.getContractFactory("MagnetaCurveFactory");
  const factory = await Factory.deploy(cfg.defaultRouter, FEE_VAULT, deployer.address);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log(`MagnetaCurveFactory deployed: ${factoryAddr}`);

  // Persist into the chain's existing deployment file so the frontend
  // can read it alongside the rest of the Magneta stack.
  const depPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  const dep = fs.existsSync(depPath) ? JSON.parse(fs.readFileSync(depPath, "utf8")) : {
    network: network.name, chainId: chainId.toString(), contracts: {},
  };
  dep.contracts = { ...(dep.contracts ?? {}), MagnetaCurveFactory: factoryAddr };
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`  Saved to ${depPath}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
