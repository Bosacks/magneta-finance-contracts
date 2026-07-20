/**
 * Deploy MagnetaServiceFee — the standalone NATIVE fee collector for OFF-CHAIN
 * Magneta ops (wallet-gen, vanity, snapshots, balance checks). Independent of
 * the Gateway/module topology — no cascade, no cutover.
 *
 * What it does (per chain):
 *   1. Reads `feeVault` + `gnosisSafe` from deployments/<network>.json.
 *   2. Deploys MagnetaServiceFee(feeVault).
 *   3. Reads back feeVault()/maxOpFee()/owner() to verify (retry for lagging RPCs).
 *   4. transferOwnership(gnosisSafe)  — Ownable2Step: sets pendingOwner; the Safe
 *      must acceptOwnership() later (generate the accept batch separately).
 *   5. Writes the address under `contracts.MagnetaServiceFee` in the deploy JSON.
 *
 * Fees ship OFF: opFee[opId] defaults to 0 (disabled) — enabling each op fee is
 * a deliberate later Safe tx (setOpFee), never done here.
 *
 * DRY_RUN=1 → simulate (no tx sent, no JSON write).
 *
 * Usage:
 *   DRY_RUN=1 pnpm hardhat run scripts/deploy/deployServiceFee.ts --network base
 *   pnpm hardhat run scripts/deploy/deployServiceFee.ts --network base
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

const REPO_ROOT = path.join(__dirname, "..", "..");
const DEPLOY_DIR = path.join(REPO_ROOT, "deployments");
const DRY_RUN = process.env.DRY_RUN === "1";

async function main() {
  const net = network.name;
  const depPath = path.join(DEPLOY_DIR, `${net}.json`);
  if (!fs.existsSync(depPath)) throw new Error(`No deployments file at ${depPath}`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));

  const feeVault: string = dep.feeVault;
  if (!feeVault || !ethers.isAddress(feeVault)) throw new Error(`feeVault not set in ${depPath}`);

  // Safe is stored under `gnosisSafe` (string) on the mainnet deployments.
  const safeRaw = dep.gnosisSafe;
  const safe: string | undefined = typeof safeRaw === "string" ? safeRaw : safeRaw?.address;
  if (!safe || !ethers.isAddress(safe)) throw new Error(`gnosisSafe not set/invalid in ${depPath}`);

  if (dep.contracts?.MagnetaServiceFee) {
    console.log(`[${net}] MagnetaServiceFee already deployed: ${dep.contracts.MagnetaServiceFee} — skipping (delete the key to redeploy)`);
    return;
  }

  const [deployer] = await ethers.getSigners();
  const bal = await ethers.provider.getBalance(deployer.address);
  console.log(`[${net}] Deployer: ${deployer.address} | balance ${ethers.formatEther(bal)}`);
  console.log(`[${net}] FeeVault: ${feeVault} | Safe: ${safe}`);

  if (bal === 0n) throw new Error(`[${net}] deployer has ZERO gas — top up before deploying`);

  const Factory = await ethers.getContractFactory("MagnetaServiceFee");

  if (DRY_RUN) {
    const data = (await Factory.getDeployTransaction(feeVault)).data;
    const est = await ethers.provider.estimateGas({ from: deployer.address, data }).catch(() => 0n);
    console.log(`[${net}] DRY_RUN — would deploy MagnetaServiceFee(${feeVault}); est. gas ${est}`);
    console.log(`[${net}] DRY_RUN — would transferOwnership -> ${safe}; NO tx sent, NO JSON write.`);
    return;
  }

  const c = await Factory.deploy(feeVault);
  await c.waitForDeployment();
  const addr = await c.getAddress();
  console.log(`[${net}] MagnetaServiceFee deployed: ${addr}`);

  // Read-back with retry (some L2 sequencers lag between deploy and eth_call).
  let onVault = "", onMax = 0n, onOwner = "";
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      onVault = await c.feeVault();
      onMax = await c.maxOpFee();
      onOwner = await c.owner();
      break;
    } catch (e) {
      if (attempt === 6) throw e;
      console.log(`[${net}] read-back not ready (${attempt}/6), waiting 5s…`);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
  console.log(`[${net}] On-chain: feeVault=${onVault} maxOpFee=${onMax} owner=${onOwner}`);
  if (onVault.toLowerCase() !== feeVault.toLowerCase()) throw new Error(`[${net}] feeVault mismatch on-chain`);
  if (onOwner.toLowerCase() !== deployer.address.toLowerCase()) throw new Error(`[${net}] unexpected owner after deploy`);

  // Ownable2Step: this sets pendingOwner; the Safe accepts later.
  const tx = await c.transferOwnership(safe);
  await tx.wait();
  // Read-back with retry — several L2 sequencers (Base observed) lag between
  // tx.wait() and the new state being queryable via eth_call, so a single read
  // can return the stale zero pendingOwner. Poll until it reflects the Safe.
  let pending = "";
  for (let attempt = 1; attempt <= 6; attempt++) {
    pending = await c.pendingOwner();
    if (pending.toLowerCase() === safe.toLowerCase()) break;
    if (attempt === 6) throw new Error(`[${net}] pendingOwner=${pending} != Safe ${safe} after retries`);
    console.log(`[${net}] pendingOwner read lagging (${attempt}/6: ${pending}), waiting 5s…`);
    await new Promise((r) => setTimeout(r, 5000));
  }
  console.log(`[${net}] transferOwnership -> pendingOwner=${pending} (Safe must acceptOwnership)`);

  dep.contracts = dep.contracts || {};
  dep.contracts.MagnetaServiceFee = addr;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`[${net}] wrote contracts.MagnetaServiceFee=${addr} to ${net}.json`);
  console.log(`[${net}] DONE. Fees are OFF (opFee=0). Enable per-op later via Safe setOpFee.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
