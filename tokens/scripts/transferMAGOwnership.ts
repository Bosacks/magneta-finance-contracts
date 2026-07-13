/**
 * Transfer MAG OFT ownership from the deployer EOA to the in-house Safe.
 *
 * Single-step Ownable on MagnetaERC20OFT — one tx per chain. No acceptOwnership
 * needed. Idempotent: skips if owner already matches the target Safe.
 *
 * Usage (per chain):
 *   pnpm hardhat run scripts/transferMAGOwnership.ts --network base
 *   pnpm hardhat run scripts/transferMAGOwnership.ts --network arbitrum
 *   ...
 *
 * Env override:
 *   TARGET_OWNER=0x...   (defaults to in-house Safe 0x40ea...b297)
 */
import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const CONTRACTS_REPO = path.join(__dirname, "..", "..", "..", "..", "magneta-finance-contracts");

// In-house Safe — same address on every chain (pre-deployed via SafeProxyFactory).
const DEFAULT_TARGET = "0x40ea2908Ea490d58E62D1Fd3364464D8A857b297";

const OFT_ABI = [
  "function owner() view returns (address)",
  "function transferOwnership(address) external",
] as const;

async function main() {
  const [signer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);

  const target = (process.env.TARGET_OWNER ?? DEFAULT_TARGET).toLowerCase();

  const depPath = path.join(CONTRACTS_REPO, "deployments", `${network.name}.json`);
  if (!fs.existsSync(depPath)) throw new Error(`No deployment file for ${network.name}`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  const mag: string | undefined = dep?.contracts?.MAG;
  if (!mag) throw new Error(`MAG not deployed on ${network.name}`);

  const oft = new ethers.Contract(mag, OFT_ABI, signer);
  const current: string = (await oft.owner()).toLowerCase();

  console.log(`\nNetwork    : ${network.name} (${chainId})`);
  console.log(`MAG        : ${mag}`);
  console.log(`Signer     : ${signer.address}`);
  console.log(`Current    : ${current}`);
  console.log(`Target     : ${target}\n`);

  if (current === target) {
    console.log("⏭  Already owned by target Safe — skipping.");
    return;
  }
  if (current !== signer.address.toLowerCase()) {
    throw new Error(`Signer is NOT current owner. Cannot transfer (current owner = ${current}).`);
  }

  const tx = await oft.transferOwnership(target);
  console.log(`Submitted: ${tx.hash}`);
  await tx.wait();
  console.log(`✓ Owner is now ${target}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
