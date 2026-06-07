/**
 * Deploy LPModule on a chain whose MagnetaGateway is owned by the Safe.
 *
 * Standalone variant of redeployLPModule.ts: instead of calling
 * `gateway.setModule(...)` directly (which fails when deployer ≠ owner),
 * this script:
 *
 *   1. Deploys LPModule with constructor args read from CHAIN_CONFIG +
 *      deployments/<chain>.json
 *   2. Updates deployments/<chain>.json so the on-chain address is durable
 *   3. Generates a Safe batch (scripts/safe/<chain>-lp-wire-batch.json)
 *      containing the 4 setModule calls (CREATE_LP / REMOVE_LP / BURN_LP /
 *      CREATE_LP_AND_BUY → new LPModule). The Safe owner then signs +
 *      executes via execBatch.ts (or Safe UI for chains that support it).
 *
 * Useful for unlocking LP on a chain that was originally Core-only because
 * a UniV2 router didn't exist there at deploy time (e.g. Abstract 2026-06).
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployLPModuleSafe.ts --network abstract
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG } from "./chainConfig";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");
const BATCH_DIR = path.join(__dirname, "..", "safe");

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
  const contracts = deployment.contracts as Record<string, string | null>;

  const gatewayAddr = contracts.MagnetaGateway as string | null;
  const magnetaSwap = contracts.MagnetaSwap as string | null;
  if (!gatewayAddr || !magnetaSwap) {
    throw new Error(`MagnetaGateway or MagnetaSwap not in ${deployPath}`);
  }

  console.log(`\n── Deploy LPModule (Safe-wired) on ${network.name} ──`);
  console.log(`   deployer       : ${deployer.address}`);
  console.log(`   Gateway        : ${gatewayAddr}`);
  console.log(`   MagnetaSwap    : ${magnetaSwap}`);
  console.log(`   defaultRouter  : ${cfg.defaultRouter}`);
  console.log(`   usdc           : ${cfg.usdc}`);

  // Sanity-check the router has code on this chain — catches the most
  // common config error before burning gas on the LPModule deploy.
  const routerCode = await ethers.provider.getCode(cfg.defaultRouter);
  if (routerCode === "0x") {
    throw new Error(`defaultRouter ${cfg.defaultRouter} has no code on ${network.name}`);
  }

  // Sanity-check the router is V2-shaped (must have .factory() returning a non-zero address)
  const router = await ethers.getContractAt(
    ["function factory() view returns (address)", "function WETH() view returns (address)"],
    cfg.defaultRouter,
  );
  const factoryAddr = await router.factory();
  if (factoryAddr === ethers.ZeroAddress) {
    throw new Error(`router.factory() == 0 — is ${cfg.defaultRouter} actually a UniV2 router?`);
  }
  console.log(`   router.factory : ${factoryAddr}`);

  // ─── Deploy ────────────────────────────────────────────────────────────
  console.log(`\n── Deploying LPModule…`);
  const LPMod = await ethers.getContractFactory("LPModule");
  const lpModule = await LPMod.deploy(gatewayAddr, cfg.defaultRouter, cfg.usdc, magnetaSwap);
  await lpModule.waitForDeployment();
  const newLpModule = await lpModule.getAddress();
  console.log(`   ✓ LPModule deployed at ${newLpModule}`);

  // ─── Persist deployment record ─────────────────────────────────────────
  const prevLpModule = contracts.LPModule;
  if (prevLpModule) {
    let archiveKey = "LPModule_old";
    let n = 2;
    while (contracts[archiveKey]) archiveKey = `LPModule_old_${n++}`;
    contracts[archiveKey] = prevLpModule;
  }
  contracts.LPModule = newLpModule;
  deployment.timestamp = new Date().toISOString();
  deployment.notes = (deployment.notes ?? []) as string[];
  deployment.notes.push(
    `${new Date().toISOString().slice(0, 10)} — LPModule deployed (Safe-wired path). Router ${cfg.defaultRouter}. Wire via scripts/safe/${network.name}-lp-wire-batch.json.`,
  );
  fs.writeFileSync(deployPath, JSON.stringify(deployment, null, 2) + "\n");
  console.log(`   ✓ Updated ${deployPath}`);

  // ─── Generate Safe wire batch ─────────────────────────────────────────
  // gateway.setModule(uint8 op, address mod) — onlyOwner. Encode the 4
  // calls into a Safe Transaction Builder batch the in-house Safe can
  // execute via execBatch.ts.
  const gatewayIface = new ethers.Interface([
    "function setModule(uint8 op, address mod)",
  ]);
  const transactions = LP_OPS.map(({ op }) => ({
    to: gatewayAddr,
    value: "0",
    data: gatewayIface.encodeFunctionData("setModule", [op, newLpModule]),
    contractMethod: null,
    contractInputsValues: null,
  }));

  const batch = {
    version: "1.0",
    chainId: String(chainId),
    createdAt: 1780500000,
    meta: {
      name: `Magneta LP unlock — ${network.name}`,
      description:
        `Sprint LP-unlock for ${network.name}. Wires the freshly-deployed ` +
        `LPModule (${newLpModule}) as the Gateway's handler for the 4 LP ` +
        `ops (CREATE_LP=0, REMOVE_LP=1, BURN_LP=2, CREATE_LP_AND_BUY=3). ` +
        `LPModule was deployed against router ${cfg.defaultRouter}. Sign ` +
        `with the Safe that owns Gateway ${gatewayAddr}.`,
    },
    transactions,
  };

  if (!fs.existsSync(BATCH_DIR)) fs.mkdirSync(BATCH_DIR, { recursive: true });
  const batchPath = path.join(BATCH_DIR, `${network.name}-lp-wire-batch.json`);
  fs.writeFileSync(batchPath, JSON.stringify(batch, null, 2) + "\n");
  console.log(`   ✓ Safe batch written: ${batchPath}`);

  console.log(`\n── NEXT STEPS ──`);
  console.log(`1. Execute the Safe batch:`);
  console.log(`     BATCH=${path.relative(process.cwd(), batchPath)} \\`);
  console.log(`       pnpm hardhat run scripts/safe/inhouse/execBatch.ts --network ${network.name}`);
  console.log(`2. Update tokens repo lib/constants/gatewayChains.ts:`);
  console.log(`     chainId ${chainId} → lpModule: '${newLpModule}'`);
  console.log(`3. Frontend smoke test: open the LP page on this chain — should now load`);
  console.log(`   the LP creation form instead of falling back to "no LP module".`);
}

main().catch((err) => { console.error(err); process.exit(1); });
