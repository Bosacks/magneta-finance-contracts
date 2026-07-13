/**
 * Wire the guardian as pauser on the contracts the original deploy scripts
 * missed. deployAll.ts / configureOnly.ts only ever called addPauser(guardian)
 * on MagnetaGateway + MagnetaSwap, so on every chain the guardian can currently
 * pause ONLY those two. The five contracts below are Pausable but were never
 * wired — this script closes that gap.
 *
 * MUST run BEFORE ownership is transferred to the Safe: addPauser is onlyOwner,
 * and while owner == deployer EOA this is a single cheap EOA call per contract.
 * Once ownership moves to the Safe it becomes a multisig batch per chain.
 *
 * Idempotent: reads isPauser(guardian) and skips anything already set, so it is
 * safe to re-run. Reversible: the owner can removePauser later if ever needed.
 *
 * Usage (per chain):
 *   DRY_RUN=1 pnpm hardhat run scripts/deploy/wirePauserGap.ts --network polygon   # simulate only
 *   pnpm hardhat run scripts/deploy/wirePauserGap.ts --network polygon             # execute
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { PAUSE_GUARDIAN, RELAYER_PAUSER } from "./chainConfig";

// The Pausable contracts the guardian was never added to at deploy time.
// (Gateway + Swap are already wired — intentionally excluded here.)
const TARGET_CONTRACTS = [
  "MagnetaPool",
  "MagnetaLending",
  "MagnetaFactory",
  "MagnetaBundler",
  "MagnetaBridgeOApp",
] as const;

const PAUSER_ABI = [
  "function addPauser(address) external",
  "function isPauser(address) view returns (bool)",
  "function owner() view returns (address)",
];

const DRY_RUN = !!process.env.DRY_RUN;

async function main() {
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const depFile = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  if (!fs.existsSync(depFile)) throw new Error(`No deployment file: ${depFile}`);
  const dep = JSON.parse(fs.readFileSync(depFile, "utf8"));
  const c = dep.contracts ?? {};

  // Extra pausers to grant beyond the guardian (Defender relayer, if provisioned).
  const pausers = [PAUSE_GUARDIAN, ...(RELAYER_PAUSER ? [RELAYER_PAUSER] : [])];

  console.log(`Network  : ${network.name} (chainId ${chainId})`);
  console.log(`Signer   : ${signer.address}`);
  console.log(`Guardian : ${PAUSE_GUARDIAN}`);
  if (RELAYER_PAUSER) console.log(`Relayer  : ${RELAYER_PAUSER}`);
  console.log(`Mode     : ${DRY_RUN ? "DRY_RUN (no tx sent)" : "EXECUTE"}\n`);

  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  const call = async (label: string, fn: () => Promise<any>, skipIf: () => Promise<boolean>) => {
    if (await skipIf()) {
      console.log(`  ✓ ${label} — already set, skip`);
      return;
    }
    if (DRY_RUN) {
      // NEVER invoke fn here — fn sends a real tx. Just report intent; the
      // per-contract callStatic check below validates it would not revert.
      console.log(`  → ${label} — WOULD SEND`);
      return;
    }
    let lastErr: any;
    for (let attempt = 1; attempt <= 6; attempt++) {
      try {
        const tx = await fn();
        await tx.wait();
        console.log(`  ✓ ${label} — tx=${tx.hash}`);
        return;
      } catch (e: any) {
        lastErr = e;
        const msg: string = e?.message ?? String(e);
        if (/nonce too low|replacement transaction underpriced|already known/i.test(msg)) {
          const backoff = 2000 * attempt;
          console.log(`  … ${label} — nonce race, retry ${attempt}/6 in ${backoff}ms`);
          await sleep(backoff);
          continue;
        }
        throw e;
      }
    }
    throw lastErr;
  };

  const summary: Array<{ contract: string; addr: string; guardian: boolean }> = [];

  for (const name of TARGET_CONTRACTS) {
    const addr: string | undefined = c[name];
    if (!addr) {
      console.log(`── ${name}: not deployed on ${network.name}, skip`);
      continue;
    }
    const ct = new ethers.Contract(addr, PAUSER_ABI, signer);

    // Preflight: the signer MUST be the current owner, else addPauser reverts.
    let owner: string;
    try {
      owner = await ct.owner();
    } catch (e) {
      console.log(`── ${name} (${addr}): owner() reverted — unexpected ABI, skip`);
      continue;
    }
    console.log(`── ${name} (${addr}) — owner=${owner}`);
    if (owner.toLowerCase() !== signer.address.toLowerCase()) {
      console.log(`  ⚠ signer is NOT owner — addPauser would revert. ` +
        `Owner is ${owner}. (If already the Safe, use a Safe batch instead.) Skipping.`);
      const g = await ct.isPauser(PAUSE_GUARDIAN);
      summary.push({ contract: name, addr, guardian: g });
      continue;
    }

    for (const p of pausers) {
      const isGuardian = p.toLowerCase() === PAUSE_GUARDIAN.toLowerCase();
      await call(
        `${name}.addPauser(${p})`,
        () => ct.addPauser(p),
        async () => ct.isPauser(p),
      );
      if (isGuardian && DRY_RUN) {
        // In DRY_RUN, validate via callStatic that the real tx would not revert.
        try {
          await ct.addPauser.staticCall(p);
          console.log(`    (callStatic ok — would succeed)`);
        } catch (e: any) {
          console.log(`    ✗ callStatic REVERT: ${e?.shortMessage ?? e?.message}`);
        }
      }
    }

    const g = await ct.isPauser(PAUSE_GUARDIAN);
    summary.push({ contract: name, addr, guardian: g });
  }

  console.log(`\n── Final guardian-pauser state on ${network.name} ──`);
  for (const s of summary) {
    console.log(`  ${s.guardian ? "✓" : "✗"} ${s.contract.padEnd(18)} ${s.addr}  isPauser(guardian)=${s.guardian}`);
  }
  const missing = summary.filter((s) => !s.guardian).map((s) => s.contract);
  if (!DRY_RUN && missing.length) {
    console.log(`\n⚠ Still missing after run: ${missing.join(", ")}`);
    process.exitCode = 1;
  } else if (!DRY_RUN) {
    console.log(`\nDone — guardian is pauser on all present target contracts.`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
