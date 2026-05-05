/**
 * Cronos backfill — deploy the 6 contracts missing on Cronos EVM.
 *
 * History: when Cronos was first deployed (2026-04-26), LayerZero V2 was
 * believed to be unavailable so we shipped Core-only (5/11) + an off-chain
 * relayer for cross-chain CREATE_TOKEN. LZ V2 IS in fact live on Cronos
 * (endpoint 0x3A73…9AA9, EID 30359 — same endpoint as Hyperliquid). This
 * script tops Cronos up to the full 11/11 stack.
 *
 * What it deploys (idempotent — skips anything already in deployments/cronos.json):
 *   1. MagnetaGateway
 *   2. MagnetaBridgeOApp
 *   3. LPModule, SwapModule, TaxClaimModule
 *   4. TokenOpsModule
 *
 * Then configures the Gateway (setModule for ops 0..12, setUsdc,
 * setPauseGuardian) and marks LPModule fee-exempt on MagnetaSwap.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployCronosBackfill.ts --network cronos
 *
 * After this script runs successfully, follow up with:
 *   - generatePeerWiringBatches.ts (Cronos peers ↔ all 19 chains)
 *   - safe execute on Cronos (via in-house Safe 0x40ea…b297)
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG, FEE_VAULT, PAUSE_GUARDIAN } from "./chainConfig";

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  if (chainId !== 25) {
    throw new Error(`This script is Cronos-only — current chainId is ${chainId}. Use --network cronos`);
  }

  const cfg = CHAIN_CONFIG[25];
  if (!cfg.lzEndpoint || !cfg.lzEid) {
    throw new Error("Cronos chainConfig is missing lzEndpoint/lzEid — fix chainConfig.ts first");
  }

  const deploymentsPath = path.join(__dirname, "..", "..", "deployments", "cronos.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentsPath, "utf8"));
  const existing: Record<string, string> = deployment.contracts ?? {};

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`\nDeployer  : ${deployer.address}`);
  console.log(`Network   : cronos (25)`);
  console.log(`Balance   : ${ethers.formatEther(balance)} CRO`);
  console.log(`LZ V2     : ${cfg.lzEndpoint} (EID ${cfg.lzEid})`);
  console.log(`Existing  : ${Object.keys(existing).join(", ")}\n`);

  if (balance === 0n) throw new Error("Deployer has 0 CRO — fund it first");
  if (!existing.MagnetaPool || !existing.MagnetaSwap) {
    throw new Error("MagnetaPool / MagnetaSwap missing from deployments/cronos.json — abort");
  }

  let step = 0;
  const log = (label: string, addr: string) => console.log(`  [${++step}] ${label}: ${addr}`);

  // ─── Cross-chain (LayerZero V2) ──────────────────────────────────────
  if (!existing.MagnetaGateway) {
    console.log("── Deploying MagnetaGateway ──");
    const Gateway = await ethers.getContractFactory("MagnetaGateway");
    const gw = await Gateway.deploy(cfg.lzEndpoint, deployer.address, FEE_VAULT);
    await gw.waitForDeployment();
    existing.MagnetaGateway = await gw.getAddress();
    log("MagnetaGateway", existing.MagnetaGateway);
  } else {
    console.log(`  · MagnetaGateway exists: ${existing.MagnetaGateway}`);
  }

  if (!existing.MagnetaBridgeOApp) {
    console.log("── Deploying MagnetaBridgeOApp ──");
    const BridgeOApp = await ethers.getContractFactory("MagnetaBridgeOApp");
    const br = await BridgeOApp.deploy(cfg.lzEndpoint, deployer.address, FEE_VAULT, cfg.lzEid);
    await br.waitForDeployment();
    existing.MagnetaBridgeOApp = await br.getAddress();
    log("MagnetaBridgeOApp", existing.MagnetaBridgeOApp);
  } else {
    console.log(`  · MagnetaBridgeOApp exists: ${existing.MagnetaBridgeOApp}`);
  }

  // ─── Gateway modules ─────────────────────────────────────────────────
  if (!existing.LPModule) {
    console.log("── Deploying LPModule ──");
    const LPMod = await ethers.getContractFactory("LPModule");
    const m = await LPMod.deploy(existing.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!, existing.MagnetaSwap);
    await m.waitForDeployment();
    existing.LPModule = await m.getAddress();
    log("LPModule", existing.LPModule);
  } else {
    console.log(`  · LPModule exists: ${existing.LPModule}`);
  }

  if (!existing.SwapModule) {
    console.log("── Deploying SwapModule ──");
    const SwapMod = await ethers.getContractFactory("SwapModule");
    const m = await SwapMod.deploy(existing.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!);
    await m.waitForDeployment();
    existing.SwapModule = await m.getAddress();
    log("SwapModule", existing.SwapModule);
  } else {
    console.log(`  · SwapModule exists: ${existing.SwapModule}`);
  }

  if (!existing.TaxClaimModule) {
    console.log("── Deploying TaxClaimModule ──");
    const TaxClaimMod = await ethers.getContractFactory("TaxClaimModule");
    const m = await TaxClaimMod.deploy(existing.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!);
    await m.waitForDeployment();
    existing.TaxClaimModule = await m.getAddress();
    log("TaxClaimModule", existing.TaxClaimModule);
  } else {
    console.log(`  · TaxClaimModule exists: ${existing.TaxClaimModule}`);
  }

  if (!existing.TokenOpsModule) {
    console.log("── Deploying TokenOpsModule ──");
    const TokenOpsMod = await ethers.getContractFactory("TokenOpsModule");
    const m = await TokenOpsMod.deploy(existing.MagnetaGateway, cfg.usdc!);
    await m.waitForDeployment();
    existing.TokenOpsModule = await m.getAddress();
    log("TokenOpsModule", existing.TokenOpsModule);
  } else {
    console.log(`  · TokenOpsModule exists: ${existing.TokenOpsModule}`);
  }

  // ─── Checkpoint addresses BEFORE config (resume-safe) ────────────────
  const updated = {
    ...deployment,
    chainConfig: cfg,
    timestamp: new Date().toISOString(),
    contracts: existing,
  };
  fs.writeFileSync(deploymentsPath, JSON.stringify(updated, null, 2) + "\n");
  console.log(`\n  (addresses checkpointed to ${deploymentsPath})`);

  // ─── Configure Gateway ───────────────────────────────────────────────
  console.log("\n── Configuring Gateway ──");
  const gateway = await ethers.getContractAt("MagnetaGateway", existing.MagnetaGateway);

  const moduleMap: [number, string][] = [
    [0,  existing.LPModule],
    [1,  existing.LPModule],
    [2,  existing.LPModule],
    [3,  existing.LPModule],
    [4,  existing.TokenOpsModule],
    [5,  existing.TokenOpsModule],
    [6,  existing.TokenOpsModule],
    [7,  existing.TokenOpsModule],
    [8,  existing.TokenOpsModule],
    [9,  existing.TokenOpsModule],
    [10, existing.TaxClaimModule],
    [11, existing.SwapModule],
    [12, existing.SwapModule],
  ];

  for (const [op, mod] of moduleMap) {
    const current = (await gateway.moduleFor(op)) as string;
    if (current.toLowerCase() === mod.toLowerCase()) continue;
    const tx = await gateway.setModule(op, mod);
    await tx.wait();
  }
  console.log(`  ✓ 13/13 modules registered on Gateway`);

  if (cfg.usdc) {
    const currentUsdc = (await gateway.usdc()) as string;
    if (currentUsdc.toLowerCase() !== cfg.usdc.toLowerCase()) {
      const tx = await gateway.setUsdc(cfg.usdc);
      await tx.wait();
    }
    console.log(`  ✓ Gateway USDC: ${cfg.usdc}`);
  }

  const currentGuardian = (await gateway.pauseGuardian()) as string;
  if (currentGuardian.toLowerCase() !== PAUSE_GUARDIAN.toLowerCase()) {
    const tx = await gateway.setPauseGuardian(PAUSE_GUARDIAN);
    await tx.wait();
  }
  console.log(`  ✓ Gateway pauseGuardian: ${PAUSE_GUARDIAN}`);

  // ─── Mark LPModule fee-exempt on existing MagnetaSwap ────────────────
  const swap = await ethers.getContractAt("MagnetaSwap", existing.MagnetaSwap);
  const isExempt = (await swap.feeExempt(existing.LPModule)) as boolean;
  if (!isExempt) {
    const tx = await swap.setFeeExempt(existing.LPModule, true);
    await tx.wait();
  }
  console.log(`  ✓ MagnetaSwap: LPModule fee-exempt`);

  // ─── Done ────────────────────────────────────────────────────────────
  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`\nGas spent: ${ethers.formatEther(spent)} CRO`);

  console.log("\n══════════════════════════════════════════════════");
  console.log("NEXT STEPS:");
  console.log("══════════════════════════════════════════════════");
  console.log("1. Run generatePeerWiringBatches.ts to add Cronos to peer mesh");
  console.log("2. Execute the resulting Safe batches on each chain");
  console.log("3. Update Tokens repo: lib/constants/contracts.ts + GATEWAY_CHAINS");
  console.log("4. Update DEX repo:    lib/v2Constants.ts (Cronos already there)");
  console.log("5. Verify on Cronoscan via verify_cronos.js");
  console.log("══════════════════════════════════════════════════\n");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
