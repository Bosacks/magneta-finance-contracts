/**
 * One-shot MasterChef setup — deploy + fund + register pools + start emissions.
 *
 * Use this when you want a fully-running farm on a chain in a single command.
 * The bare `deployMasterChef.ts` only deploys the contract and leaves the rest
 * to the operator; this script chains the post-deploy steps too so the farm
 * is immediately usable from the DEX frontend.
 *
 * Required env vars:
 *   REWARDS_TOKEN          ERC-20 address paid out as rewards
 *   LP_TOKENS              comma-separated LP token addresses to register
 *   FUND_AMOUNT            amount of REWARDS_TOKEN to send to MasterChef (decimal native units, e.g. "10000")
 *   REWARDS_PER_SECOND     wei per second of REWARDS_TOKEN (e.g. "1000000000000000" for 0.001/sec on 18-dec)
 *
 * Optional env vars:
 *   ALLOC_POINTS           comma-separated alloc points per LP_TOKEN (default 100 each)
 *   END_TIME               unix timestamp for emissions stop (default now + 365 days)
 *   SKIP_FUND              if "true", skip the funding transfer (use if MasterChef will be funded later)
 *   MASTERCHEF_ADDRESS     if set to an existing MasterChef address, skips step 1 (deploy) and
 *                          resumes from step 2 (fund) — useful when a previous run errored mid-way.
 *
 * Usage:
 *   REWARDS_TOKEN=0x... LP_TOKENS=0x...,0x... FUND_AMOUNT=10000 REWARDS_PER_SECOND=1000000000000000 \
 *     pnpm hardhat run scripts/deploy/deployMasterChefAndSetup.ts --network polygon
 *
 * Writes the deployed address into `deployments/{net}.json` under
 * `contracts.MagnetaMasterChef`, then prints the line to paste into
 * `apps/web/lib/constants/masterChef.json` in the DEX repo.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

function reqEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} env var required`);
  return v;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const balance = await ethers.provider.getBalance(deployer.address);

  // --- Parse + validate config ----------------------------------------
  const rewardsToken = reqEnv("REWARDS_TOKEN");
  if (!ethers.isAddress(rewardsToken)) {
    throw new Error("REWARDS_TOKEN is not a valid 0x address");
  }

  const lpTokens = reqEnv("LP_TOKENS").split(",").map((s) => s.trim()).filter(Boolean);
  if (lpTokens.length === 0 || lpTokens.some((a) => !ethers.isAddress(a))) {
    throw new Error("LP_TOKENS must be a comma-separated list of 0x addresses");
  }

  const allocPointsRaw = process.env.ALLOC_POINTS;
  const allocPoints = allocPointsRaw
    ? allocPointsRaw.split(",").map((s) => BigInt(s.trim()))
    : lpTokens.map(() => 100n);
  if (allocPoints.length !== lpTokens.length) {
    throw new Error("ALLOC_POINTS length must match LP_TOKENS length (or omit to default to 100 each)");
  }

  const rewardsPerSecond = BigInt(reqEnv("REWARDS_PER_SECOND"));
  const fundAmount = process.env.SKIP_FUND === "true"
    ? 0n
    : ethers.parseUnits(reqEnv("FUND_AMOUNT"), 18);

  const defaultEnd = Math.floor(Date.now() / 1000) + 365 * 86400;
  const endTime = BigInt(process.env.END_TIME ?? defaultEnd);

  // --- Pre-flight summary ---------------------------------------------
  console.log("\n══════════════════════════════════════════════════");
  console.log("MasterChef one-shot setup");
  console.log("══════════════════════════════════════════════════");
  console.log(`Deployer        : ${deployer.address}`);
  console.log(`Network         : ${network.name} (${chainId})`);
  console.log(`Balance         : ${ethers.formatEther(balance)} native`);
  console.log(`Rewards token   : ${rewardsToken}`);
  console.log(`LP tokens       : ${lpTokens.length}`);
  lpTokens.forEach((t, i) => console.log(`  - ${t}  (alloc ${allocPoints[i]})`));
  console.log(`Rewards / sec   : ${rewardsPerSecond.toString()}`);
  console.log(`Fund amount     : ${ethers.formatUnits(fundAmount, 18)} (skip=${process.env.SKIP_FUND === "true"})`);
  console.log(`End time        : ${new Date(Number(endTime) * 1000).toISOString()}\n`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  // --- Step 1: Deploy MasterChef --------------------------------------
  // Resume support: pass MASTERCHEF_ADDRESS to skip deploy and reuse an
  // existing instance (useful when a later step failed and the deploy already
  // succeeded — re-deploying costs gas for no reason).
  const existingMc = process.env.MASTERCHEF_ADDRESS;
  let mc: any;
  let addr: string;
  if (existingMc && ethers.isAddress(existingMc)) {
    console.log(`─ [1/4] Reusing existing MasterChef at ${existingMc} (MASTERCHEF_ADDRESS set)`);
    mc = await ethers.getContractAt("MagnetaMasterChef", existingMc);
    addr = existingMc;
  } else {
    console.log("─ [1/4] Deploying MagnetaMasterChef…");
    const Factory = await ethers.getContractFactory("MagnetaMasterChef");
    mc = await Factory.deploy(deployer.address, rewardsToken, 0n /* set rate later */, endTime);
    await mc.waitForDeployment();
    addr = await mc.getAddress();
    console.log(`  ✓ MasterChef at ${addr}`);
  }

  // --- Step 2: Fund the contract (skippable) --------------------------
  if (fundAmount > 0n) {
    console.log(`─ [2/4] Funding MasterChef with ${ethers.formatUnits(fundAmount, 18)} reward tokens…`);
    // Fully-qualified to disambiguate from the IERC20 copies bundled with Uniswap V2
    // and chain-specific adapters — Hardhat refuses a bare "IERC20" otherwise.
    const rewards = await ethers.getContractAt(
      "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
      rewardsToken,
    );
    const tx = await rewards.transfer(addr, fundAmount);
    await tx.wait();
    console.log(`  ✓ Transfer tx ${tx.hash}`);
  } else {
    console.log("─ [2/4] Skipped (SKIP_FUND=true) — operator will fund later");
  }

  // --- Step 3: Register pools -----------------------------------------
  console.log(`─ [3/4] Registering ${lpTokens.length} LP pool(s)…`);
  for (let i = 0; i < lpTokens.length; i++) {
    const tx = await mc.addPool(allocPoints[i], lpTokens[i], i === lpTokens.length - 1);
    await tx.wait();
    console.log(`  ✓ pool ${i} (${lpTokens[i].slice(0, 10)}…, alloc ${allocPoints[i]}) tx ${tx.hash}`);
  }

  // --- Step 4: Start emissions ----------------------------------------
  console.log(`─ [4/4] Starting emissions at ${rewardsPerSecond.toString()} wei/sec…`);
  const rateTx = await mc.setRewardsPerSecond(rewardsPerSecond);
  await rateTx.wait();
  console.log(`  ✓ setRewardsPerSecond tx ${rateTx.hash}`);

  // --- Persist deployment ---------------------------------------------
  const depPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  const dep = fs.existsSync(depPath) ? JSON.parse(fs.readFileSync(depPath, "utf8")) : {
    network: network.name, chainId: chainId.toString(), contracts: {},
  };
  dep.contracts = { ...(dep.contracts ?? {}), MagnetaMasterChef: addr };
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`\n  Deployment saved → ${depPath}`);

  // --- Frontend wiring instructions -----------------------------------
  console.log("\n══════════════════════════════════════════════════");
  console.log("FRONTEND WIRING");
  console.log("══════════════════════════════════════════════════");
  console.log(`Paste into magneta-finance-dex/apps/web/lib/constants/masterChef.json:`);
  console.log("");
  console.log(`  "${chainId}": "${addr}"`);
  console.log("");
  console.log("Then restart the DEX dev server. Pools with Farms will pick it up.");
  console.log("══════════════════════════════════════════════════\n");
}

main().catch((e) => { console.error(e); process.exit(1); });
