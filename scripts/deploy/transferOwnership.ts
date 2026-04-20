/**
 * Transfer ownership of deployed contracts from deployer EOA to Gnosis Safe / Timelock.
 *
 * Classification (see docs/DEPLOYMENT_HARDENING.md):
 *   Class A (Timelock 48h) : contracts with fund-moving or business-logic setters.
 *   Class B/C (Safe direct): pause/unpause + low-risk setters.
 *
 * Dry-run first:
 *   DRY_RUN=1 pnpm hardhat run scripts/deploy/transferOwnership.ts --network base
 *
 * Execute:
 *   pnpm hardhat run scripts/deploy/transferOwnership.ts --network base
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const CLASS_A_TIMELOCK = [
  "MagnetaBundler",
  "MagnetaGateway",
  "MagnetaLending",
  "MagnetaSwap",
  "MagnetaPool",
  "MagnetaProxy",
  "MagnetaFactory",
  "MagnetaFarm",
  "MagnetaDLMM",
  "MagnetaBridgeOApp",
];

const CLASS_BC_SAFE = [
  "MagnetaMultiPool",
  // Any additional non-core contracts that still have owner-only functions
];

const OWNABLE_ABI = [
  "function owner() view returns (address)",
  "function transferOwnership(address) external",
  "function pendingOwner() view returns (address)",
];

async function main() {
  const dryRun = !!process.env.DRY_RUN;
  const depFile = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  if (!fs.existsSync(depFile)) throw new Error(`No deployment file: ${depFile}`);

  const dep = JSON.parse(fs.readFileSync(depFile, "utf8"));
  const timelock: string | undefined = dep.timelock;
  const safe: string | undefined = dep.gnosisSafe;
  if (!timelock || !safe) {
    throw new Error("deployments/<network>.json must contain `timelock` and `gnosisSafe`");
  }

  const [signer] = await ethers.getSigners();
  console.log(`Network : ${network.name}`);
  console.log(`Signer  : ${signer.address} (must currently own the contracts)`);
  console.log(`Safe    : ${safe}`);
  console.log(`Timelock: ${timelock}`);
  console.log(`Mode    : ${dryRun ? "DRY RUN" : "EXECUTE"}\n`);

  const transfer = async (name: string, target: string) => {
    const addr = dep.contracts[name];
    if (!addr) {
      console.log(`  ${name.padEnd(22)} — not deployed on this network, skip`);
      return;
    }
    const c = new ethers.Contract(addr, OWNABLE_ABI, signer);
    const currentOwner: string = await c.owner();
    if (currentOwner.toLowerCase() === target.toLowerCase()) {
      console.log(`  ${name.padEnd(22)} ${addr} — already owned by target, skip`);
      return;
    }
    if (currentOwner.toLowerCase() !== signer.address.toLowerCase()) {
      console.log(`  ${name.padEnd(22)} ${addr} — owner=${currentOwner}, signer cannot transfer, SKIP`);
      return;
    }
    if (dryRun) {
      console.log(`  ${name.padEnd(22)} ${addr} → ${target}  (dry-run, no tx)`);
      return;
    }
    const tx = await c.transferOwnership(target);
    console.log(`  ${name.padEnd(22)} ${addr} → ${target}  tx=${tx.hash}`);
    await tx.wait();
  };

  console.log(`Class A — Timelock (${CLASS_A_TIMELOCK.length}):`);
  for (const name of CLASS_A_TIMELOCK) await transfer(name, timelock);

  console.log(`\nClass B/C — Safe direct (${CLASS_BC_SAFE.length}):`);
  for (const name of CLASS_BC_SAFE) await transfer(name, safe);

  console.log("\nDone.");
  console.log("Next: if any contract uses Ownable2Step, Safe/Timelock must call acceptOwnership().");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
