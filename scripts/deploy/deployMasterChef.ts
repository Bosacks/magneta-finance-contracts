/**
 * Deploy MagnetaMasterChef on a single chain.
 *
 *   pnpm hardhat run scripts/deploy/deployMasterChef.ts --network polygon
 *
 * Reads:
 *   - REWARDS_TOKEN env var → ERC-20 address paid out as farm rewards
 *     (e.g. MAG on Polygon: 0x07c926937b3dfde9a779ad066be1300ac41c6fef)
 *   - REWARDS_PER_SECOND env var → wei per second (default 0 — owner funds
 *     later via setRewardsPerSecond + endTime)
 *   - END_TIME env var → uint64 unix timestamp (default = now + 365 days)
 *
 * Writes the resulting factory address into `deployments/{net}.json` under
 * `contracts.MagnetaMasterChef`.
 *
 * Owner = deployer EOA initially. Transfer to the in-house Safe via
 * `transferOwnership` once verified (see scripts/deploy/transferOwnership.ts).
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const balance = await ethers.provider.getBalance(deployer.address);

  const rewardsToken = process.env.REWARDS_TOKEN;
  if (!rewardsToken || !ethers.isAddress(rewardsToken)) {
    throw new Error("REWARDS_TOKEN env var required (e.g. MAG address). Got: " + rewardsToken);
  }
  const rewardsPerSecond = BigInt(process.env.REWARDS_PER_SECOND ?? "0");
  const defaultEnd = Math.floor(Date.now() / 1000) + 365 * 86400;
  const endTime = BigInt(process.env.END_TIME ?? defaultEnd);

  console.log(`\nDeployer        : ${deployer.address}`);
  console.log(`Network         : ${network.name} (${chainId})`);
  console.log(`Balance         : ${ethers.formatEther(balance)} native`);
  console.log(`Rewards token   : ${rewardsToken}`);
  console.log(`Rewards / sec   : ${rewardsPerSecond.toString()}`);
  console.log(`End time        : ${new Date(Number(endTime) * 1000).toISOString()}\n`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  const Factory = await ethers.getContractFactory("MagnetaMasterChef");
  const mc = await Factory.deploy(deployer.address, rewardsToken, rewardsPerSecond, endTime);
  await mc.waitForDeployment();
  const addr = await mc.getAddress();
  console.log(`MagnetaMasterChef deployed: ${addr}`);

  const depPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  const dep = fs.existsSync(depPath) ? JSON.parse(fs.readFileSync(depPath, "utf8")) : {
    network: network.name, chainId: chainId.toString(), contracts: {},
  };
  dep.contracts = { ...(dep.contracts ?? {}), MagnetaMasterChef: addr };
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`  Saved to ${depPath}\n`);

  console.log("══════════════════════════════════════════════════");
  console.log("NEXT STEPS:");
  console.log("══════════════════════════════════════════════════");
  console.log(`1. Fund the contract: send ${rewardsToken} to ${addr}`);
  console.log("2. Add LP pools via owner.addPool(allocPoint, lpToken, true)");
  console.log("3. Set rewards rate: owner.setRewardsPerSecond(N)");
  console.log("4. (V1.1) Transfer ownership to Safe via transferOwnership.ts\n");
}

main().catch((e) => { console.error(e); process.exit(1); });
