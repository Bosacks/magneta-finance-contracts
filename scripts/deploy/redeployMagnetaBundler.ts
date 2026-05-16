/**
 * Single-chain redeploy script for MagnetaBundler.
 *
 * Reads `router` and `feeRecipient` from the currently-deployed bundler on
 * the target network (passed via OLD_BUNDLER env), so we redeploy with the
 * exact same upstream wiring. Prints the new address — caller updates the
 * frontend `MAGNETA_BUNDLER_ADDRESS` map manually after each chain.
 *
 * Usage:
 *   OLD_BUNDLER=0xD6B5aa64cd22556C1Fe2f476BbE1538190d69B24 \
 *     pnpm hardhat run scripts/deploy/redeployMagnetaBundler.ts --network polygon
 *
 * Rationale: the in-place `bundleBuy` refund math was buggy (refund tried to
 * send back the fee that was already forwarded to FeeVault, reverting every
 * call with "ETH refund failed"). The fix is a one-line change to the refund
 * formula; binary is otherwise identical.
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

  const oldBundler = reqEnv("OLD_BUNDLER");
  if (!ethers.isAddress(oldBundler)) {
    throw new Error("OLD_BUNDLER must be a valid 0x address");
  }

  console.log("\n══════════════════════════════════════════════════");
  console.log("MagnetaBundler redeploy (patched bundleBuy refund)");
  console.log("══════════════════════════════════════════════════");
  console.log(`Deployer        : ${deployer.address}`);
  console.log(`Network         : ${network.name} (${chainId})`);
  console.log(`Native balance  : ${ethers.formatEther(balance)}`);
  console.log(`Old bundler     : ${oldBundler}`);

  // Read router + feeRecipient from the deployed instance so we keep the wiring identical.
  const oldContract = await ethers.getContractAt("MagnetaBundler", oldBundler);
  const router        = await oldContract.router();
  const feeRecipient  = await oldContract.feeRecipient();
  console.log(`Router          : ${router}`);
  console.log(`Fee recipient   : ${feeRecipient}\n`);

  if (balance === 0n) throw new Error("Deployer has 0 balance — fund it first");

  console.log("─ Deploying patched MagnetaBundler…");
  const Factory = await ethers.getContractFactory("MagnetaBundler");
  const newBundler = await Factory.deploy(router, feeRecipient);
  await newBundler.waitForDeployment();
  const newAddr = await newBundler.getAddress();
  console.log(`  ✓ New bundler at ${newAddr}\n`);

  // Save to deployments file so we have a permanent record.
  const depPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  const dep = fs.existsSync(depPath)
    ? JSON.parse(fs.readFileSync(depPath, "utf8"))
    : { network: network.name, chainId: chainId.toString(), contracts: {} };
  dep.contracts = { ...(dep.contracts ?? {}), MagnetaBundler: newAddr };
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`  Deployment saved → ${depPath}\n`);

  console.log("══════════════════════════════════════════════════");
  console.log("FRONTEND UPDATE");
  console.log("══════════════════════════════════════════════════");
  console.log("Update magneta-finance-tokens/lib/constants/contracts.ts:");
  console.log("");
  console.log(`  ${chainId}:    '${newAddr}', // ${network.name} (patched 2026-05-16)`);
  console.log("");
  console.log("Old bundler stays deployed — UI just points at the new one.");
  console.log("══════════════════════════════════════════════════\n");
}

main().catch((e) => { console.error(e); process.exit(1); });
