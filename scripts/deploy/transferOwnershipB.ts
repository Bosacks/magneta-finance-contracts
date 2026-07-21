/**
 * Transfer ownership of deployed contracts from deployer EOA to Gnosis Safe.
 *
 * Phase 1 (current): Safe-direct for all contracts. No Timelock yet.
 *   → all Ownable(2Step) contracts transferred to the Safe.
 *   → for Ownable2Step contracts, the Safe must call acceptOwnership() after.
 *
 * Phase 2 (post-launch, when we deploy a Timelock): split Class A (Timelock)
 *   vs Class B/C (Safe direct) by moving contract names into the TIMELOCK list.
 *
 * Requires deployments/<network>.json to contain `gnosisSafe`.
 * Optional `timelock` field — if present, contracts listed in TIMELOCK go there.
 *
 * Dry-run first:
 *   DRY_RUN=1 pnpm hardhat run scripts/deploy/transferOwnership.ts --network arbitrum
 *
 * Execute:
 *   pnpm hardhat run scripts/deploy/transferOwnership.ts --network arbitrum
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

// Contracts that will move to the Timelock once it exists. Empty for now.
const TIMELOCK: string[] = [];

// All other ownable contracts go to the Safe directly.
const SAFE_DIRECT = [
  "MagnetaPool",
  "MagnetaSwap",
  "MagnetaLending",
  "MagnetaFactory",
  "MagnetaBundler",
  "MagnetaGateway",
  "MagnetaBridgeOApp",
  "LPModule",
  "SwapModule",
  "TokenOpsModule",
  "TaxClaimModule",
  "MagnetaCurveFactory",
];

const OWNABLE_ABI = [
  "function owner() view returns (address)",
  "function transferOwnership(address) external",
  "function pendingOwner() view returns (address)",
];

async function main() {
  const dryRun = !!process.env.DRY_RUN;
  const depFile = path.join(__dirname, "..", "..", "deployments-b", `${network.name}.json`);
  if (!fs.existsSync(depFile)) throw new Error(`No deployment file: ${depFile}`);

  const dep = JSON.parse(fs.readFileSync(depFile, "utf8"));
  const safe: string | undefined = dep.gnosisSafe;
  const timelock: string | undefined = dep.timelock;
  if (!safe) {
    throw new Error("deployments/<network>.json must contain `gnosisSafe`");
  }
  if (TIMELOCK.length > 0 && !timelock) {
    throw new Error("TIMELOCK list is non-empty but deployments/<network>.json has no `timelock`");
  }

  const [signer] = await ethers.getSigners();
  console.log(`Network : ${network.name}`);
  console.log(`Signer  : ${signer.address} (must currently own the contracts)`);
  console.log(`Safe    : ${safe}`);
  console.log(`Timelock: ${timelock ?? "(none — all transfers go to Safe)"}`);
  console.log(`Mode    : ${dryRun ? "DRY RUN" : "EXECUTE"}\n`);

  const transfer = async (name: string, target: string) => {
    const addr = dep.contracts[name];
    if (!addr) {
      console.log(`  ${name.padEnd(22)} — not deployed on this network, skip`);
      return;
    }
    const c = new ethers.Contract(addr, OWNABLE_ABI, signer);
    const currentOwner: string = await c.owner();
    let pending: string | null = null;
    try {
      pending = await c.pendingOwner();
    } catch {
      pending = null; // plain Ownable (not 2Step)
    }
    const is2Step = pending !== null;

    if (currentOwner.toLowerCase() === target.toLowerCase()) {
      console.log(`  ${name.padEnd(22)} ${addr} — already owned by target, skip`);
      return;
    }
    if (is2Step && pending!.toLowerCase() === target.toLowerCase()) {
      console.log(`  ${name.padEnd(22)} ${addr} — pending=target (waiting for Safe acceptOwnership), skip`);
      return;
    }
    if (currentOwner.toLowerCase() !== signer.address.toLowerCase()) {
      console.log(`  ${name.padEnd(22)} ${addr} — owner=${currentOwner}, signer cannot transfer, SKIP`);
      return;
    }
    if (dryRun) {
      const typeLabel = is2Step ? "Ownable2Step" : "Ownable";
      console.log(`  ${name.padEnd(22)} ${addr} → ${target}  (${typeLabel}, dry-run)`);
      return;
    }
    const typeLabel = is2Step ? "2Step" : "1Step";
    // Retry-on-nonce-low — Polygon public RPCs frequently return stale nonces.
    let lastErr: any;
    for (let attempt = 1; attempt <= 6; attempt++) {
      try {
        const tx = await c.transferOwnership(target);
        await tx.wait();
        console.log(`  ${name.padEnd(22)} ${addr} → ${target}  [${typeLabel}] tx=${tx.hash}`);
        return;
      } catch (e: any) {
        lastErr = e;
        const msg: string = e?.message ?? String(e);
        if (/nonce too low|replacement transaction underpriced|already known/i.test(msg)) {
          const backoff = 2000 * attempt;
          console.log(`  ${name.padEnd(22)} nonce race, retry ${attempt}/6 in ${backoff}ms`);
          await new Promise((r) => setTimeout(r, backoff));
          continue;
        }
        throw e;
      }
    }
    throw lastErr;
  };

  if (TIMELOCK.length > 0) {
    console.log(`Timelock (${TIMELOCK.length}):`);
    for (const name of TIMELOCK) await transfer(name, timelock!);
    console.log();
  }

  console.log(`Safe direct (${SAFE_DIRECT.length}):`);
  for (const name of SAFE_DIRECT) await transfer(name, safe);

  console.log("\nDone.");
  console.log("For any Ownable2Step contract, the Safe must now call acceptOwnership().");
  console.log("Use Safe Transaction Builder to batch all acceptOwnership calls in one signature.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
