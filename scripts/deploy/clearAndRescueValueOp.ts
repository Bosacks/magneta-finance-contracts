/**
 * Clear a stuck pendingValueOp and rescue the orphaned USDC.
 *
 * Two owner-only calls in sequence on the destination MagnetaGateway:
 *   1. adminClearPendingValueOp(guid)
 *        Decrements totalEarmarked + deletes the entry. Without this,
 *        rescueERC20 of USDC blocks at the
 *          require(balance >= totalEarmarked + amount)
 *        guard.
 *   2. rescueERC20(usdc, to, amount)
 *        Sends the bridged amount back to `to` (defaults to deployer).
 *
 * Usage:
 *   GUID=0x… [RESCUE_TO=0x…] \
 *     pnpm hardhat run scripts/deploy/clearAndRescueValueOp.ts --network base
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

function need(env: string): string {
  const v = process.env[env];
  if (!v) throw new Error(`Missing env var: ${env}`);
  return v;
}

async function main() {
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const guid = need("GUID");
  const rescueTo = process.env.RESCUE_TO ?? signer.address;

  console.log(`\n── clear + rescue on ${network.name} (chainId ${chainId}) ──`);
  console.log(`   signer: ${signer.address}`);
  console.log(`   guid:   ${guid}`);
  console.log(`   to:     ${rescueTo}`);

  const deployPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  const deployment = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const gatewayAddr = deployment.contracts.MagnetaGateway as string;
  const gateway = await ethers.getContractAt("MagnetaGateway", gatewayAddr);

  // Sanity: pending op exists, capture amount + token before clearing.
  const pending = await gateway.pendingValueOps(guid);
  if (pending.bridgedAmount === 0n) {
    throw new Error(`No pending op for guid ${guid}`);
  }
  console.log(`\n   pending.bridgedAmount = ${pending.bridgedAmount}`);
  console.log(`   pending.bridgedToken  = ${pending.bridgedToken}`);

  const amountToRescue = pending.bridgedAmount;
  const tokenToRescue = pending.bridgedToken;

  console.log(`\n── 1. adminClearPendingValueOp(${guid}) ──`);
  const tx1 = await gateway.adminClearPendingValueOp(guid);
  await tx1.wait();
  console.log(`   ✓ tx ${tx1.hash}`);

  console.log(`\n── 2. rescueERC20(${tokenToRescue}, ${rescueTo}, ${amountToRescue}) ──`);
  const tx2 = await gateway.rescueERC20(tokenToRescue, rescueTo, amountToRescue);
  await tx2.wait();
  console.log(`   ✓ tx ${tx2.hash}`);

  console.log(`\n── DONE ──`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
