/**
 * Resume the wiring phase of redeployGatewayStack after a mid-run failure
 * (typically a public-RPC nonce desync). The deploy phase is the expensive
 * part and produces addresses that we MUST NOT throw away — this script
 * accepts those addresses via env vars and continues exactly where the
 * original script left off.
 *
 * setModule, setUsdc, and setPauseGuardian are idempotent: re-sending a
 * call whose value is already on-chain is a no-op cost-wise but won't
 * revert. Safe to re-run on top of a partial wiring.
 *
 * Usage (env vars from the deploy output):
 *   NEW_GATEWAY=0x...      \
 *   NEW_LP_MODULE=0x...    \
 *   NEW_SWAP_MODULE=0x...  \
 *   NEW_TAX_MODULE=0x...   \
 *   NEW_TOKENOPS_MODULE=0x... \
 *   pnpm hardhat run scripts/deploy/resumeGatewayWiring.ts --network polygon
 *
 * Also overwrites deployments/<network>.json with the new addresses so
 * downstream scripts (wireGatewayPair.ts, frontend env update) see the
 * patched stack.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { PAUSE_GUARDIAN, CHAIN_CONFIG } from "./chainConfig";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

function need(env: string): string {
  const v = process.env[env];
  if (!v) throw new Error(`Missing env var: ${env}`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(v)) throw new Error(`${env} is not a 0x-address: ${v}`);
  return v;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg?.usdc) throw new Error(`No usdc in CHAIN_CONFIG[${chainId}]`);

  const gatewayAddr   = need("NEW_GATEWAY");
  const lpModuleAddr  = need("NEW_LP_MODULE");
  const swapAddr      = need("NEW_SWAP_MODULE");
  const taxAddr       = need("NEW_TAX_MODULE");
  const tokenOpsAddr  = need("NEW_TOKENOPS_MODULE");

  console.log(`\n── Resume Gateway wiring on ${network.name} (chainId ${chainId}) ──`);
  console.log(`   deployer: ${deployer.address}`);
  console.log(`   Gateway : ${gatewayAddr}`);

  const gateway = await ethers.getContractAt("MagnetaGateway", gatewayAddr);

  // OpType enum (see IMagnetaGateway.sol):
  //   0=CREATE_LP, 1=REMOVE_LP, 2=BURN_LP, 3=CREATE_LP_AND_BUY,
  //   4=MINT, 5=UPDATE_METADATA, 6=FREEZE_ACCOUNT, 7=UNFREEZE_ACCOUNT,
  //   8=AUTO_FREEZE, 9=REVOKE_PERMISSION, 10=CLAIM_TAX_FEES,
  //   11=SWAP_LOCAL, 12=SWAP_OUT, 13=CREATE_TOKEN
  const assignments: Array<{ op: number; addr: string; label: string }> = [
    { op: 0,  addr: lpModuleAddr, label: "CREATE_LP" },
    { op: 1,  addr: lpModuleAddr, label: "REMOVE_LP" },
    { op: 2,  addr: lpModuleAddr, label: "BURN_LP" },
    { op: 3,  addr: lpModuleAddr, label: "CREATE_LP_AND_BUY" },
    { op: 4,  addr: tokenOpsAddr, label: "MINT" },
    { op: 5,  addr: tokenOpsAddr, label: "UPDATE_METADATA" },
    { op: 6,  addr: tokenOpsAddr, label: "FREEZE_ACCOUNT" },
    { op: 7,  addr: tokenOpsAddr, label: "UNFREEZE_ACCOUNT" },
    { op: 8,  addr: tokenOpsAddr, label: "AUTO_FREEZE" },
    { op: 9,  addr: tokenOpsAddr, label: "REVOKE_PERMISSION" },
    { op: 10, addr: taxAddr,      label: "CLAIM_TAX_FEES" },
    { op: 11, addr: swapAddr,     label: "SWAP_LOCAL" },
    { op: 12, addr: swapAddr,     label: "SWAP_OUT" },
  ];

  console.log("\n── setModule (skip those already correctly wired) ──");
  for (const { op, addr, label } of assignments) {
    const current = await gateway.moduleFor(op);
    if (current.toLowerCase() === addr.toLowerCase()) {
      console.log(`   ✓ ${label} (op ${op}) already → ${addr.slice(0, 10)}… (skip)`);
      continue;
    }
    const tx = await gateway.setModule(op, addr);
    await tx.wait();
    console.log(`   ✓ setModule(${label} = ${op}) → ${addr.slice(0, 10)}…  tx ${tx.hash}`);
  }

  console.log("\n── setUsdc / setPauseGuardian (skip if already set) ──");
  const currentUsdc = await gateway.usdc();
  if (currentUsdc.toLowerCase() !== cfg.usdc.toLowerCase()) {
    const tx = await gateway.setUsdc(cfg.usdc);
    await tx.wait();
    console.log(`   ✓ setUsdc(${cfg.usdc})  tx ${tx.hash}`);
  } else {
    console.log(`   ✓ usdc already = ${cfg.usdc} (skip)`);
  }
  const currentGuardian = await gateway.pauseGuardian();
  if (currentGuardian.toLowerCase() !== PAUSE_GUARDIAN.toLowerCase()) {
    const tx = await gateway.setPauseGuardian(PAUSE_GUARDIAN);
    await tx.wait();
    console.log(`   ✓ setPauseGuardian(${PAUSE_GUARDIAN})  tx ${tx.hash}`);
  } else {
    console.log(`   ✓ pauseGuardian already = ${PAUSE_GUARDIAN} (skip)`);
  }

  // Persist addresses (same shape as redeployGatewayStack.ts).
  const deployPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  if (fs.existsSync(deployPath)) {
    const deployment = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
    const contracts = deployment.contracts as Record<string, string>;
    contracts.MagnetaGateway_old = contracts.MagnetaGateway_old ?? contracts.MagnetaGateway;
    contracts.LPModule_old       = contracts.LPModule_old       ?? contracts.LPModule;
    contracts.SwapModule_old     = contracts.SwapModule_old     ?? contracts.SwapModule;
    contracts.TaxClaimModule_old = contracts.TaxClaimModule_old ?? contracts.TaxClaimModule;
    contracts.TokenOpsModule_old = contracts.TokenOpsModule_old ?? contracts.TokenOpsModule;
    contracts.MagnetaGateway = gatewayAddr;
    contracts.LPModule       = lpModuleAddr;
    contracts.SwapModule     = swapAddr;
    contracts.TaxClaimModule = taxAddr;
    contracts.TokenOpsModule = tokenOpsAddr;
    deployment.timestamp = new Date().toISOString();
    deployment.notes = (deployment.notes ?? []) as string[];
    deployment.notes.push(
      `${new Date().toISOString().slice(0, 10)} — Gateway-stack redeploy resumed (_payNative override). Previous addresses kept as *_old.`
    );
    fs.writeFileSync(deployPath, JSON.stringify(deployment, null, 2) + "\n");
    console.log(`\n   ✓ Updated ${deployPath}`);
  } else {
    console.warn(`\n   ⚠ ${deployPath} not found — addresses not persisted.`);
  }

  console.log(`\n── DONE ──`);
  console.log(`   Next: pnpm hardhat run scripts/deploy/wireGatewayPair.ts --network ${network.name}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
