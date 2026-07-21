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

  const outDir = path.join(REPO, "deployments-b");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);

  // Resume-safe: load any prior checkpoint (RPC flakiness on a 20-chain run is
  // a given — a re-run skips already-deployed contracts instead of orphaning
  // new ones). Deploy addresses are checkpointed to disk after EACH deploy.
  const c: Record<string, string> = fs.existsSync(outPath)
    ? (JSON.parse(fs.readFileSync(outPath, "utf8")).contracts ?? {})
    : {};
  const save = () => fs.writeFileSync(outPath, JSON.stringify({
    network: network.name, chainId: String(chainId), deployer: deployer.address,
    feeVault: FEE_VAULT, pauseGuardian: PAUSE_GUARDIAN, gnosisSafe: live.gnosisSafe,
    keptFromLive: { MagnetaPool: keptPool, MagnetaSwap: keptSwap, MagnetaLending: kept.MagnetaLending, MagnetaBundler: kept.MagnetaBundler, MagnetaBridgeOApp: kept.MagnetaBridgeOApp },
    timestamp: new Date().toISOString(), chainConfig: cfg, contracts: c,
    postDeploy: { safe: [`keptSwap.setFeeExempt(<LPModule>, true)`], separateScripts: ["deployMagnetaProxy.ts", "deployCurveLaunchpad.ts", "configPeers.ts"] },
  }, null, 2) + "\n");

  if (!c.MagnetaGateway) {
    const Gateway = await ethers.getContractFactory("MagnetaGateway", mgr);
    const gw = await Gateway.deploy(ethers.getAddress(cfg.lzEndpoint), deployer.address, FEE_VAULT);
    await gw.waitForDeployment(); c.MagnetaGateway = await gw.getAddress(); save();
    console.log(`  MagnetaGateway ${c.MagnetaGateway}`);
  } else console.log(`  MagnetaGateway ${c.MagnetaGateway} (resumed)`);
  const gateway = await ethers.getContractAt("MagnetaGateway", c.MagnetaGateway, mgr);
  // Read-back retry: a just-deployed contract's code lags on some L2 sequencers
  // (Base) — eth_call returns 0x (BAD_DATA) for a few seconds after deploy.
  const readRetry = async <T>(fn: () => Promise<T>, label: string): Promise<T> => {
    for (let i = 1; i <= 8; i++) {
      try { return await fn(); }
      catch (e) { if (i === 8) throw e; console.log(`  ${label} read lagging (${i}/8), waiting 5s…`); await new Promise((r) => setTimeout(r, 5000)); }
    }
    throw new Error("unreachable");
  };
  if ((await readRetry(() => gateway.requiredDVNCount(), "requiredDVNCount")) < 2n) { await (await gateway.setRequiredDVNCount(2)).wait(); }
  console.log(`  ✓ requiredDVNCount = 2`);

  if (deployModules) {
    if (!c.LPModule) { const F = await ethers.getContractFactory("LPModule", mgr); const x = await F.deploy(c.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!, keptSwap); await x.waitForDeployment(); c.LPModule = await x.getAddress(); save(); }
    console.log(`  LPModule ${c.LPModule}`);
    if (!c.SwapModule) { const F = await ethers.getContractFactory("SwapModule", mgr); const x = await F.deploy(c.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!); await x.waitForDeployment(); c.SwapModule = await x.getAddress(); save(); }
    console.log(`  SwapModule ${c.SwapModule}`);
    if (!c.TaxClaimModule) { const F = await ethers.getContractFactory("TaxClaimModule", mgr); const x = await F.deploy(c.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!); await x.waitForDeployment(); c.TaxClaimModule = await x.getAddress(); save(); }
    console.log(`  TaxClaimModule ${c.TaxClaimModule}`);
  }
  if (deployTokenOps) {
    if (!c.TokenOpsModule) { const F = await ethers.getContractFactory("TokenOpsModule", mgr); const x = await F.deploy(c.MagnetaGateway, cfg.usdc!); await x.waitForDeployment(); c.TokenOpsModule = await x.getAddress(); save(); }
    console.log(`  TokenOpsModule ${c.TokenOpsModule}`);
  }
  if (!c.MagnetaFactory) { const F = await ethers.getContractFactory("MagnetaFactory", mgr); const x = await F.deploy(keptPool, deployer.address); await x.waitForDeployment(); c.MagnetaFactory = await x.getAddress(); save(); }
  console.log(`  MagnetaFactory ${c.MagnetaFactory}`);

  // ── wire the new Gateway (mirror deployAll setModule map) ──
  const moduleMap: [number, string | undefined][] = [
    [0, c.LPModule], [1, c.LPModule], [2, c.LPModule], [3, c.LPModule],
    [4, c.TokenOpsModule], [5, c.TokenOpsModule], [6, c.TokenOpsModule], [7, c.TokenOpsModule],
    [8, c.TokenOpsModule], [9, c.TokenOpsModule], [10, c.TaxClaimModule], [11, c.SwapModule],
    [12, c.SwapModule], [16, c.TokenOpsModule],
  ];
  let reg = 0;
  for (const [op, mod] of moduleMap) {
    if (!mod) continue;
    const cur = (await gateway.moduleFor(op)) as string;
    if (cur.toLowerCase() !== mod.toLowerCase()) { await (await gateway.setModule(op, mod)).wait(); reg++; }
  }
  console.log(`  ✓ modules registered on Gateway (${reg} set this run)`);
  if (cfg.usdc && (await gateway.usdc()).toLowerCase() !== cfg.usdc.toLowerCase()) { await (await gateway.setUsdc(cfg.usdc)).wait(); }
  console.log(`  ✓ USDC set`);
  if (!(await gateway.isPauser(PAUSE_GUARDIAN))) { await (await gateway.addPauser(PAUSE_GUARDIAN)).wait(); }
  console.log(`  ✓ pauser (guardian)`);
  if (RELAYER_PAUSER && !(await gateway.isPauser(RELAYER_PAUSER))) { await (await gateway.addPauser(RELAYER_PAUSER)).wait(); }

  save();
  // keptSwap.setFeeExempt(c.LPModule, true) is required but MagnetaSwap is
  // Safe-owned — do NOT call from the deployer. Emitted as a Safe batch separately.
  console.log(`\n  scoped set -> ${outPath}`);
  console.log(`  ⚠ Safe TODO: keptSwap ${keptSwap} setFeeExempt(${c.LPModule ?? "-"}, true)`);
  console.log(`  NEXT: proxy + curve + configPeers (mesh) + Safe setFeeExempt, then pauser/transfer/accept, then CUTOVER.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
