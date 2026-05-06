/**
 * Deploy MagnetaStakingFactory on a single chain.
 *
 *   pnpm hardhat run scripts/deploy/deployStakingFactory.ts --network polygon
 *
 * Reads `feeVault` from chainConfig, deploys the factory with the deployer
 * EOA as initial owner. Writes the resulting factory address into
 * `deployments/{net}.json` under `contracts.MagnetaStakingFactory`.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { FEE_VAULT } from "./chainConfig";

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const balance = await ethers.provider.getBalance(deployer.address);

  console.log(`\nDeployer  : ${deployer.address}`);
  console.log(`Network   : ${network.name} (${chainId})`);
  console.log(`Balance   : ${ethers.formatEther(balance)} native`);
  console.log(`FeeVault  : ${FEE_VAULT}\n`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  const Factory = await ethers.getContractFactory("MagnetaStakingFactory");
  const f = await Factory.deploy(FEE_VAULT, deployer.address);
  await f.waitForDeployment();
  const addr = await f.getAddress();
  console.log(`MagnetaStakingFactory deployed: ${addr}`);

  const depPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  const dep = fs.existsSync(depPath) ? JSON.parse(fs.readFileSync(depPath, "utf8")) : {
    network: network.name, chainId: chainId.toString(), contracts: {},
  };
  dep.contracts = { ...(dep.contracts ?? {}), MagnetaStakingFactory: addr };
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`  Saved to ${depPath}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
