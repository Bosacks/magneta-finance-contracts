/**
 * Redeploy MagnetaGateway + its 4 modules (LP/Swap/TokenOps/TaxClaim)
 * on the current chain, owner = deployer (caller is expected to transfer
 * to the Safe afterwards). Every module has `address public immutable
 * gateway`, so a Gateway redeploy forces a module redeploy too.
 *
 * Why a fresh script instead of running deployAll.ts:
 *   - deployAll redeploys the entire stack (Pool/Swap/Lending/Factory/
 *     Bundler/MAG/StakingFactory/CurveFactory…). The Gateway patch
 *     (override _payNative as >=) does NOT touch those, so reusing them
 *     saves ~80% of gas and avoids resetting LP-pair addresses, staking
 *     positions, MAG balances, etc.
 *   - Existing deployments[<network>].json is preserved and overwritten
 *     only with the new Gateway-stack addresses. The "old" Gateway +
 *     modules remain on-chain as orphans (owner = Safe).
 *
 * Usage (per chain):
 *   pnpm hardhat run scripts/deploy/redeployGatewayStack.ts --network polygon
 *   pnpm hardhat run scripts/deploy/redeployGatewayStack.ts --network base
 *
 * Post-deploy: run
 *   pnpm hardhat run scripts/deploy/configCctp.ts --network <net>
 * to wire CCTP. Peers between the two new Gateways need a separate
 * setPeer call (Safe batch or direct).
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG, FEE_VAULT, PAUSE_GUARDIAN } from "./chainConfig";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No CHAIN_CONFIG for chainId ${chainId}`);
  if (!cfg.lzEndpoint || !cfg.usdc || !cfg.defaultRouter) {
    throw new Error(`Chain ${chainId} missing lzEndpoint / usdc / defaultRouter`);
  }

  console.log(`\n── Redeploy Gateway stack on ${network.name} (chainId ${chainId}) ──`);
  console.log(`   deployer  : ${deployer.address}`);
  console.log(`   feeVault  : ${FEE_VAULT}`);
  console.log(`   guardian  : ${PAUSE_GUARDIAN}`);

  const deployPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  if (!fs.existsSync(deployPath)) {
    throw new Error(`Expected existing deployment at ${deployPath}`);
  }
  const deployment = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const contracts = deployment.contracts as Record<string, string>;
  if (!contracts.MagnetaSwap) {
    throw new Error("MagnetaSwap not found in deployment — needed by LPModule");
  }

  // Snapshot the OLD addresses before overwriting (for the post-mortem).
  const old = {
    MagnetaGateway:   contracts.MagnetaGateway,
    LPModule:         contracts.LPModule,
    SwapModule:       contracts.SwapModule,
    TokenOpsModule:   contracts.TokenOpsModule,
    TaxClaimModule:   contracts.TaxClaimModule,
  };
  console.log(`\n   OLD Gateway: ${old.MagnetaGateway}`);

  // ─── 1. Deploy new MagnetaGateway ─────────────────────────────────────
  console.log("\n── 1. Deploy MagnetaGateway ──");
  const Gateway = await ethers.getContractFactory("MagnetaGateway");
  const gateway = await Gateway.deploy(cfg.lzEndpoint, deployer.address, FEE_VAULT);
  await gateway.waitForDeployment();
  const gatewayAddr = await gateway.getAddress();
  console.log(`   ✓ MagnetaGateway: ${gatewayAddr}`);

  // ─── 2. Deploy modules pointing to new Gateway ────────────────────────
  console.log("\n── 2. Deploy modules ──");

  const LPMod = await ethers.getContractFactory("LPModule");
  const lpModule = await LPMod.deploy(
    gatewayAddr, cfg.defaultRouter, cfg.usdc, contracts.MagnetaSwap
  );
  await lpModule.waitForDeployment();
  const lpModuleAddr = await lpModule.getAddress();
  console.log(`   ✓ LPModule:       ${lpModuleAddr}`);

  const SwapMod = await ethers.getContractFactory("SwapModule");
  const swapModule = await SwapMod.deploy(gatewayAddr, cfg.defaultRouter, cfg.usdc);
  await swapModule.waitForDeployment();
  const swapModuleAddr = await swapModule.getAddress();
  console.log(`   ✓ SwapModule:     ${swapModuleAddr}`);

  const TaxClaimMod = await ethers.getContractFactory("TaxClaimModule");
  const taxClaimModule = await TaxClaimMod.deploy(gatewayAddr, cfg.defaultRouter, cfg.usdc);
  await taxClaimModule.waitForDeployment();
  const taxClaimModuleAddr = await taxClaimModule.getAddress();
  console.log(`   ✓ TaxClaimModule: ${taxClaimModuleAddr}`);

  const TokenOpsMod = await ethers.getContractFactory("TokenOpsModule");
  const tokenOpsModule = await TokenOpsMod.deploy(gatewayAddr, cfg.usdc);
  await tokenOpsModule.waitForDeployment();
  const tokenOpsModuleAddr = await tokenOpsModule.getAddress();
  console.log(`   ✓ TokenOpsModule: ${tokenOpsModuleAddr}`);

  // ─── 3. Wire Gateway (modules, USDC, guardian) ────────────────────────
  console.log("\n── 3. Wire Gateway ──");
  // OpType enum: 0=CREATE_LP, 1=REMOVE_LP, 2=BURN_LP, 3=CREATE_LP_AND_BUY,
  //              4=MINT, 5=UPDATE_METADATA, 6=FREEZE_ACCOUNT, 7=UNFREEZE,
  //              8=AUTO_FREEZE, 9=REVOKE_PERMISSION, 10=CLAIM_TAX_FEES,
  //              11=SWAP_LOCAL, 12=SWAP_OUT, 13=CREATE_TOKEN
  const moduleAssignments: Array<{ op: number; addr: string; label: string }> = [
    { op: 0,  addr: lpModuleAddr,       label: "CREATE_LP" },
    { op: 1,  addr: lpModuleAddr,       label: "REMOVE_LP" },
    { op: 2,  addr: lpModuleAddr,       label: "BURN_LP" },
    { op: 3,  addr: lpModuleAddr,       label: "CREATE_LP_AND_BUY" },
    { op: 4,  addr: tokenOpsModuleAddr, label: "MINT" },
    { op: 5,  addr: tokenOpsModuleAddr, label: "UPDATE_METADATA" },
    { op: 6,  addr: tokenOpsModuleAddr, label: "FREEZE_ACCOUNT" },
    { op: 7,  addr: tokenOpsModuleAddr, label: "UNFREEZE_ACCOUNT" },
    { op: 8,  addr: tokenOpsModuleAddr, label: "AUTO_FREEZE" },
    { op: 9,  addr: tokenOpsModuleAddr, label: "REVOKE_PERMISSION" },
    { op: 10, addr: taxClaimModuleAddr, label: "CLAIM_TAX_FEES" },
    { op: 11, addr: swapModuleAddr,     label: "SWAP_LOCAL" },
    { op: 12, addr: swapModuleAddr,     label: "SWAP_OUT" },
  ];
  for (const { op, addr, label } of moduleAssignments) {
    const tx = await gateway.setModule(op, addr);
    await tx.wait();
    console.log(`   ✓ setModule(${label} = ${op}) → ${addr.slice(0, 10)}…`);
  }

  const txUsdc = await gateway.setUsdc(cfg.usdc);
  await txUsdc.wait();
  console.log(`   ✓ setUsdc(${cfg.usdc})`);

  const txGuardian = await gateway.addPauser(PAUSE_GUARDIAN);
  await txGuardian.wait();
  console.log(`   ✓ addPauser(${PAUSE_GUARDIAN})`);

  // ─── 4. Persist new addresses (keep OLD as `*_old` for reference) ─────
  console.log("\n── 4. Save addresses ──");
  contracts[`MagnetaGateway_old`]   = old.MagnetaGateway;
  contracts[`LPModule_old`]         = old.LPModule;
  contracts[`SwapModule_old`]       = old.SwapModule;
  contracts[`TokenOpsModule_old`]   = old.TokenOpsModule;
  contracts[`TaxClaimModule_old`]   = old.TaxClaimModule;
  contracts.MagnetaGateway   = gatewayAddr;
  contracts.LPModule         = lpModuleAddr;
  contracts.SwapModule       = swapModuleAddr;
  contracts.TaxClaimModule   = taxClaimModuleAddr;
  contracts.TokenOpsModule   = tokenOpsModuleAddr;

  deployment.contracts = contracts;
  deployment.timestamp = new Date().toISOString();
  deployment.notes = (deployment.notes ?? []) as string[];
  deployment.notes.push(
    `${new Date().toISOString().slice(0, 10)} — Gateway-stack redeployed for _payNative override (MG-6 patch). Previous addresses kept as *_old.`
  );
  fs.writeFileSync(deployPath, JSON.stringify(deployment, null, 2) + "\n");
  console.log(`   ✓ Updated ${deployPath}`);

  // ─── Summary ──────────────────────────────────────────────────────────
  console.log("\n── DONE ──");
  console.log(`   New MagnetaGateway:  ${gatewayAddr}`);
  console.log(`   New LPModule:        ${lpModuleAddr}`);
  console.log(`   New SwapModule:      ${swapModuleAddr}`);
  console.log(`   New TokenOpsModule:  ${tokenOpsModuleAddr}`);
  console.log(`   New TaxClaimModule:  ${taxClaimModuleAddr}`);
  console.log(`\n   Next: pnpm hardhat run scripts/deploy/configCctp.ts --network ${network.name}`);
  console.log(`         Then setPeer(<other chain eid>, <other chain Gateway>) on both Gateways.`);
  console.log(`         Then update lib/constants/gatewayChains.ts in tokens repo.\n`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
