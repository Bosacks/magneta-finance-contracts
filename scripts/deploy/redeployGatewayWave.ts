/**
 * SCOPED redeploy for Workstream B (native on-chain skim + hardened Factory/Curve/Proxy).
 *
 * Redeploys ONLY the contracts that changed since the 07-03 wave + their forced
 * cascade, KEEPING the stateful/unchanged ones:
 *   REDEPLOY: MagnetaGateway (skim, OApp), LPModule, SwapModule, TaxClaimModule,
 *             TokenOpsModule (all 4 bind `immutable gateway` → forced), MagnetaFactory.
 *   KEEP    : MagnetaPool, MagnetaSwap, MagnetaLending, MagnetaBundler, MagnetaBridgeOApp
 *             (read from the existing deployments/<net>.json; new modules reference them).
 *   SEPARATE: MagnetaProxy (deployMagnetaProxy.ts), MagnetaCurveFactory (deployCurveLaunchpad.ts),
 *             LZ peer mesh (configPeers.ts) — run AFTER this, on every chain.
 *
 * Writes to deployments-b/<net>.json (NOT deployments/) so the live set is untouched
 * until an explicit cutover. Constructor args + setModule map mirror deployAll.ts exactly.
 *
 * Fees ship OFF: opServiceFeeNative defaults 0 — enable later per op via the Safe.
 *
 * DRY_RUN=1 → print the plan, send no tx, write nothing.
 *
 * Usage:
 *   DRY_RUN=1 pnpm hardhat run scripts/deploy/redeployGatewayWave.ts --network base
 *   pnpm hardhat run scripts/deploy/redeployGatewayWave.ts --network base
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG, FEE_VAULT, PAUSE_GUARDIAN, RELAYER_PAUSER } from "./chainConfig";

const DRY_RUN = process.env.DRY_RUN === "1";
const REPO = path.join(__dirname, "..", "..");

async function main() {
  const [deployer] = await ethers.getSigners();
  const mgr = new ethers.NonceManager(deployer);
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No chain config for chainId ${chainId}`);

  // Kept contracts come from the CURRENT live deployment JSON.
  const livePath = path.join(REPO, "deployments", `${network.name}.json`);
  if (!fs.existsSync(livePath)) throw new Error(`No deployments/${network.name}.json`);
  const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
  const kept = live.contracts as Record<string, string>;
  const keptPool = kept.MagnetaPool;
  const keptSwap = kept.MagnetaSwap;
  if (!keptPool || !keptSwap) throw new Error(`Missing kept MagnetaPool/MagnetaSwap in ${livePath}`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`\nSCOPED REDEPLOY (Workstream B)${DRY_RUN ? " — DRY_RUN" : ""}`);
  console.log(`Network   : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer  : ${deployer.address} | balance ${ethers.formatEther(balance)}`);
  console.log(`FeeVault  : ${FEE_VAULT}`);
  console.log(`Keep Pool : ${keptPool}`);
  console.log(`Keep Swap : ${keptSwap}`);

  const deployModules = cfg.defaultRouter !== null && cfg.usdc !== null;
  const deployTokenOps = cfg.usdc !== null;
  if (!cfg.lzEndpoint || !cfg.lzEid) throw new Error(`${network.name}: no LZ endpoint — Gateway is an OApp, cannot redeploy without it`);

  if (DRY_RUN) {
    console.log(`\nWOULD deploy: MagnetaGateway(${cfg.lzEndpoint}, ${deployer.address}, ${FEE_VAULT}) + setRequiredDVNCount(2)`);
    if (deployModules) console.log(`WOULD deploy: LPModule / SwapModule / TaxClaimModule (gateway, ${cfg.defaultRouter}, ${cfg.usdc}, [keptSwap for LP])`);
    if (deployTokenOps) console.log(`WOULD deploy: TokenOpsModule(gateway, ${cfg.usdc})`);
    console.log(`WOULD deploy: MagnetaFactory(${keptPool}, ${deployer.address})`);
    console.log(`WOULD wire  : setModule[0..12,16], setUsdc(${cfg.usdc}), addPauser(${PAUSE_GUARDIAN}${RELAYER_PAUSER ? "+relayer" : ""})`);
    console.log(`POST (Safe) : keptSwap.setFeeExempt(newLPModule,true) — Swap is Safe-owned, emit a Safe batch`);
    console.log(`SEPARATE    : deployMagnetaProxy.ts, deployCurveLaunchpad.ts, configPeers.ts (mesh)`);
    console.log(`OUTPUT      : deployments-b/${network.name}.json (live set untouched)`);
    return;
  }

  const c: Record<string, string> = {};

  const Gateway = await ethers.getContractFactory("MagnetaGateway", mgr);
  const gateway = await Gateway.deploy(ethers.getAddress(cfg.lzEndpoint), deployer.address, FEE_VAULT);
  await gateway.waitForDeployment();
  c.MagnetaGateway = await gateway.getAddress();
  console.log(`  MagnetaGateway ${c.MagnetaGateway}`);
  await (await gateway.setRequiredDVNCount(2)).wait();
  console.log(`  ✓ requiredDVNCount = 2`);

  if (deployModules) {
    const LPMod = await ethers.getContractFactory("LPModule", mgr);
    const lp = await LPMod.deploy(c.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!, keptSwap);
    await lp.waitForDeployment(); c.LPModule = await lp.getAddress(); console.log(`  LPModule ${c.LPModule}`);

    const SwapMod = await ethers.getContractFactory("SwapModule", mgr);
    const sm = await SwapMod.deploy(c.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!);
    await sm.waitForDeployment(); c.SwapModule = await sm.getAddress(); console.log(`  SwapModule ${c.SwapModule}`);

    const TaxMod = await ethers.getContractFactory("TaxClaimModule", mgr);
    const tx = await TaxMod.deploy(c.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!);
    await tx.waitForDeployment(); c.TaxClaimModule = await tx.getAddress(); console.log(`  TaxClaimModule ${c.TaxClaimModule}`);
  }
  if (deployTokenOps) {
    const TokMod = await ethers.getContractFactory("TokenOpsModule", mgr);
    const to = await TokMod.deploy(c.MagnetaGateway, cfg.usdc!);
    await to.waitForDeployment(); c.TokenOpsModule = await to.getAddress(); console.log(`  TokenOpsModule ${c.TokenOpsModule}`);
  }

  const Factory = await ethers.getContractFactory("MagnetaFactory", mgr);
  const factory = await Factory.deploy(keptPool, deployer.address);
  await factory.waitForDeployment(); c.MagnetaFactory = await factory.getAddress(); console.log(`  MagnetaFactory ${c.MagnetaFactory}`);

  // ── wire the new Gateway (mirror deployAll setModule map) ──
  const moduleMap: [number, string | undefined][] = [
    [0, c.LPModule], [1, c.LPModule], [2, c.LPModule], [3, c.LPModule],
    [4, c.TokenOpsModule], [5, c.TokenOpsModule], [6, c.TokenOpsModule], [7, c.TokenOpsModule],
    [8, c.TokenOpsModule], [9, c.TokenOpsModule], [10, c.TaxClaimModule], [11, c.SwapModule],
    [12, c.SwapModule], [16, c.TokenOpsModule],
  ];
  let reg = 0;
  for (const [op, mod] of moduleMap) { if (!mod) continue; await (await gateway.setModule(op, mod)).wait(); reg++; }
  console.log(`  ✓ ${reg} modules registered on Gateway`);
  if (cfg.usdc) { await (await gateway.setUsdc(cfg.usdc)).wait(); console.log(`  ✓ USDC set`); }
  await (await gateway.addPauser(PAUSE_GUARDIAN)).wait(); console.log(`  ✓ pauser (guardian)`);
  if (RELAYER_PAUSER) { await (await gateway.addPauser(RELAYER_PAUSER)).wait(); console.log(`  ✓ pauser (relayer)`); }

  // NOTE: keptSwap.setFeeExempt(c.LPModule, true) is required but MagnetaSwap is
  // Safe-owned — do NOT call from the deployer. Emit it as a Safe batch instead.
  console.log(`  ⚠ TODO (Safe): keptSwap ${keptSwap} setFeeExempt(${c.LPModule}, true)`);

  const outDir = path.join(REPO, "deployments-b");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify({
    network: network.name, chainId: String(chainId), deployer: deployer.address,
    feeVault: FEE_VAULT, pauseGuardian: PAUSE_GUARDIAN, gnosisSafe: live.gnosisSafe,
    keptFromLive: { MagnetaPool: keptPool, MagnetaSwap: keptSwap, MagnetaLending: kept.MagnetaLending, MagnetaBundler: kept.MagnetaBundler, MagnetaBridgeOApp: kept.MagnetaBridgeOApp },
    timestamp: new Date().toISOString(), chainConfig: cfg, contracts: c,
    postDeploy: { safe: [`keptSwap.setFeeExempt(${c.LPModule}, true)`], separateScripts: ["deployMagnetaProxy.ts", "deployCurveLaunchpad.ts", "configPeers.ts"] },
  }, null, 2) + "\n");
  console.log(`\n  scoped set -> ${outPath}`);
  console.log(`  NEXT: proxy + curve + configPeers (mesh) + Safe setFeeExempt, then pauser/transfer/accept, then CUTOVER.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
