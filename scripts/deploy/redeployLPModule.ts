/**
 * Redeploy LPModule on the current chain and re-point the 4 LP ops on
 * the existing MagnetaGateway to the new module. Used for the V1.1 V2-direct
 * cross-chain swap pivot — the LPModule binds the Gateway as
 * `address public immutable gateway`, so we can replace just the module
 * without touching the Gateway / other modules / CCTP / peer state.
 *
 * Reads MagnetaGateway, defaultRouter, usdc, MagnetaSwap from
 * deployments/<network>.json. Captures the previous LPModule as
 * `LPModule_old_N` (so prior generations stay traceable) before
 * overwriting `LPModule`.
 *
 * The 4 LP ops (CREATE_LP, REMOVE_LP, BURN_LP, CREATE_LP_AND_BUY) all
 * route to LPModule. setModule is idempotent and admin-gated.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/redeployLPModule.ts --network base
 *   pnpm hardhat run scripts/deploy/redeployLPModule.ts --network polygon
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG } from "./chainConfig";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

const LP_OPS: Array<{ op: number; label: string }> = [
  { op: 0, label: "CREATE_LP" },
  { op: 1, label: "REMOVE_LP" },
  { op: 2, label: "BURN_LP" },
  { op: 3, label: "CREATE_LP_AND_BUY" },
];

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg?.usdc || !cfg.defaultRouter) {
    throw new Error(`Chain ${chainId} missing usdc / defaultRouter in CHAIN_CONFIG`);
  }

  const deployPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  const deployment = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const contracts = deployment.contracts as Record<string, string>;

  const gatewayAddr = contracts.MagnetaGateway;
  const magnetaSwap = contracts.MagnetaSwap;
  const oldLpModule = contracts.LPModule;
  if (!gatewayAddr || !magnetaSwap) {
    throw new Error(`MagnetaGateway or MagnetaSwap not found in ${deployPath}`);
  }

  console.log(`\n── Redeploy LPModule on ${network.name} (chainId ${chainId}) ──`);
  console.log(`   deployer    : ${deployer.address}`);
  console.log(`   Gateway     : ${gatewayAddr}`);
  console.log(`   MagnetaSwap : ${magnetaSwap}`);
  console.log(`   defaultRouter: ${cfg.defaultRouter}`);
  console.log(`   usdc        : ${cfg.usdc}`);
  console.log(`   OLD LPModule: ${oldLpModule}`);

  // Sanity: deployer must be the Gateway owner.
  const gateway = await ethers.getContractAt("MagnetaGateway", gatewayAddr);
  const gatewayOwner = await gateway.owner();
  if (gatewayOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error(
      `Deployer is not Gateway owner (owner: ${gatewayOwner}). ` +
      `If owner is the Safe, generate a setModule Safe batch instead.`
    );
  }

  // ─── Deploy ──────────────────────────────────────────────────────────
  console.log(`\n── Deploy LPModule ──`);
  const LPMod = await ethers.getContractFactory("LPModule");
  const lpModule = await LPMod.deploy(gatewayAddr, cfg.defaultRouter, cfg.usdc, magnetaSwap);
  await lpModule.waitForDeployment();
  const newLpModule = await lpModule.getAddress();
  console.log(`   ✓ LPModule (V1.1 V2-direct): ${newLpModule}`);

  // ─── Re-point Gateway ────────────────────────────────────────────────
  console.log(`\n── setModule for the 4 LP ops ──`);
  for (const { op, label } of LP_OPS) {
    const current = await gateway.moduleFor(op);
    if (current.toLowerCase() === newLpModule.toLowerCase()) {
      console.log(`   ✓ ${label} (op ${op}) already at new LPModule (skip)`);
      continue;
    }
    const tx = await gateway.setModule(op, newLpModule);
    await tx.wait();
    console.log(`   ✓ setModule(${label} = ${op}) → ${newLpModule.slice(0, 10)}…  tx ${tx.hash}`);
  }

  // ─── Persist ─────────────────────────────────────────────────────────
  // Stash the old LPModule under an incrementing _old_N key so we can
  // trace the chain of redeploys (LPModule_old → LPModule_old_2 → …).
  let archiveKey = "LPModule_old";
  let n = 2;
  while (contracts[archiveKey]) {
    archiveKey = `LPModule_old_${n++}`;
  }
  contracts[archiveKey] = oldLpModule;
  contracts.LPModule = newLpModule;

  deployment.timestamp = new Date().toISOString();
  deployment.notes = (deployment.notes ?? []) as string[];
  deployment.notes.push(
    `${new Date().toISOString().slice(0, 10)} — LPModule redeployed for V1.1 V2-direct cross-chain swap path. Prior at ${archiveKey} = ${oldLpModule}.`
  );
  fs.writeFileSync(deployPath, JSON.stringify(deployment, null, 2) + "\n");
  console.log(`\n   ✓ Updated ${deployPath}`);

  console.log(`\n── DONE ──`);
  console.log(`   New LPModule: ${newLpModule}`);
  console.log(`   Update tokens repo lib/constants/gatewayChains.ts:`);
  console.log(`     chainId ${chainId} → lpModule: '${newLpModule}'`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
