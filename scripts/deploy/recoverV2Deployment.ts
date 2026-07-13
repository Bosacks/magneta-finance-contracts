/**
 * Recover from a partial V2 package deploy on Polygon.
 *
 * Context: deployV2Package.ts succeeded for the 3 deployments but the
 * transferOwnership loop hit a "nonce too low" RPC error after the first call.
 * State on chain (verified via cast):
 *   - PromotionPayment 0x2FaC13e2707475E6Ea034b92Ffc855333668c4Ea
 *       owner = deployer, pendingOwner = Safe  ✓ ready to accept
 *   - MagnetaProxy V2   0x0ff3D7a1ff7b4E53CA693D7A774E71f129520315
 *       owner = deployer, pendingOwner = 0x0   ✗ needs transferOwnership
 *   - MagnetaBundler V2 0xD6B5aa64cd22556C1Fe2f476BbE1538190d69B24
 *       owner = deployer                       ✗ needs transferOwnership (single-step)
 *
 * This script:
 *   1. Calls transferOwnership(Safe) on MagnetaProxy V2 (Ownable2Step → pending)
 *   2. Calls transferOwnership(Safe) on MagnetaBundler V2 (Ownable → immediate)
 *   3. Writes addresses to deployments/polygon.json
 *   4. Generates Safe batch JSON for the two Ownable2Step contracts only
 *      (PromotionPayment + MagnetaProxy → both need acceptOwnership)
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

const REPO_ROOT  = path.join(__dirname, "..", "..");
const DEPLOY_DIR = path.join(REPO_ROOT, "deployments");
const SAFE_DIR   = path.join(REPO_ROOT, "scripts", "safe");

const ADDRS = {
  PromotionPayment:  "0x2FaC13e2707475E6Ea034b92Ffc855333668c4Ea",
  MagnetaProxyV2:    "0x0ff3D7a1ff7b4E53CA693D7A774E71f129520315",
  MagnetaBundlerV2:  "0xD6B5aa64cd22556C1Fe2f476BbE1538190d69B24",
};

async function main() {
  const net = network.name;
  if (net !== "polygon") {
    throw new Error(`This recovery script is hard-coded for Polygon V2 partial deploy. Got ${net}.`);
  }

  const depPath = path.join(DEPLOY_DIR, `${net}.json`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  const safe: string = dep.safe ?? dep.gnosisSafe;
  if (!safe || !ethers.isAddress(safe)) throw new Error(`safe missing in ${depPath}`);
  const chainId = String(dep.chainId);

  const [deployer] = await ethers.getSigners();
  console.log(`Recovery on ${net} — Deployer ${deployer.address}, Safe ${safe}\n`);

  // ─── 1. MagnetaProxy V2 (Ownable2Step) ─────────────────────────────
  console.log("[1/2] MagnetaProxy V2 transferOwnership(safe)…");
  const proxy = await ethers.getContractAt("MagnetaProxy", ADDRS.MagnetaProxyV2);
  const currentProxyOwner: string = await proxy.owner();
  if (currentProxyOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.log(`      Skipped: owner is already ${currentProxyOwner}`);
  } else {
    const tx1 = await proxy.transferOwnership(safe);
    await tx1.wait();
    console.log(`      Pending acceptance (tx: ${tx1.hash})`);
  }

  // ─── 2. MagnetaBundler V2 (single-step Ownable) ────────────────────
  console.log("[2/2] MagnetaBundler V2 transferOwnership(safe)…");
  const bundler = await ethers.getContractAt("MagnetaBundler", ADDRS.MagnetaBundlerV2);
  const currentBundlerOwner: string = await bundler.owner();
  if (currentBundlerOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.log(`      Skipped: owner is already ${currentBundlerOwner}`);
  } else {
    const tx2 = await bundler.transferOwnership(safe);
    await tx2.wait();
    console.log(`      Ownership transferred immediately (tx: ${tx2.hash})`);
  }

  // ─── 3. Persist addresses ──────────────────────────────────────────
  if (!dep.contracts) dep.contracts = {};
  dep.contracts.PromotionPayment  = ADDRS.PromotionPayment;
  dep.contracts.MagnetaProxyV2    = ADDRS.MagnetaProxyV2;
  dep.contracts.MagnetaBundlerV2  = ADDRS.MagnetaBundlerV2;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`\nWrote V2 addresses to ${depPath}`);

  // ─── 4. Safe batch (PromotionPayment + MagnetaProxy only) ──────────
  if (!fs.existsSync(SAFE_DIR)) fs.mkdirSync(SAFE_DIR, { recursive: true });
  const batchPath = path.join(SAFE_DIR, `${net}-acceptV2Package-batch.json`);
  const batch = {
    version: "1.0",
    chainId,
    createdAt: Date.now(),
    meta: {
      name: `Magneta — Accept V2 Package ownership (${net})`,
      description: `Finalize the Ownable2Step transfer for PromotionPayment (${ADDRS.PromotionPayment}) and MagnetaProxy V2 (${ADDRS.MagnetaProxyV2}). MagnetaBundler V2 (${ADDRS.MagnetaBundlerV2}) uses single-step Ownable and is already owned by this Safe.`,
      txBuilderVersion: "1.18.0",
      createdFromSafeAddress: safe,
      createdFromOwnerAddress: "",
      checksum: "0x0000000000000000000000000000000000000000000000000000000000000000",
    },
    transactions: [
      {
        to: ADDRS.PromotionPayment,
        value: "0",
        data: null,
        contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
        contractInputsValues: {},
      },
      {
        to: ADDRS.MagnetaProxyV2,
        value: "0",
        data: null,
        contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
        contractInputsValues: {},
      },
    ],
  };
  fs.writeFileSync(batchPath, JSON.stringify(batch, null, 2) + "\n");
  console.log(`Wrote Safe batch → ${batchPath}`);

  console.log("\n=== Recovery complete ===");
  console.log("Load the Safe batch in Transaction Builder, sign, execute.");
  console.log("After that:");
  console.log(`  - PromotionPayment owner = ${safe}`);
  console.log(`  - MagnetaProxy V2 owner  = ${safe}`);
  console.log(`  - MagnetaBundler V2 owner = ${safe} (already, single-step)`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
