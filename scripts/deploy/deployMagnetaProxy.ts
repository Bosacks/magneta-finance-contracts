/**
 * Deploy MagnetaProxy — the 0.3% fee-collecting swap proxy used by the DEX.
 *
 * What it does:
 *   1. Reads `feeVault` from deployments/<network>.json (must be set).
 *   2. Deploys MagnetaProxy(feeRecipient = feeVault).
 *   3. Transfers ownership to the chain's Safe (so fee/recipient can later
 *      be tuned via multi-sig if needed).
 *   4. Writes the new address under `contracts.MagnetaProxy` in the
 *      deployment JSON.
 *
 * Post-deploy: set the address in the DEX env:
 *     NEXT_PUBLIC_MAGNETA_PROXY_ADDRESS=<deployed address>
 * then restart the DEX service.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployMagnetaProxy.ts --network polygon
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

const REPO_ROOT  = path.join(__dirname, "..", "..");
const DEPLOY_DIR = path.join(REPO_ROOT, "deployments");

async function main() {
  const net = network.name;
  const depPath = path.join(DEPLOY_DIR, `${net}.json`);
  if (!fs.existsSync(depPath)) {
    throw new Error(`No deployments file at ${depPath}`);
  }
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  const feeVault: string = dep.feeVault;
  if (!feeVault || !ethers.isAddress(feeVault)) {
    throw new Error(`feeVault not set in ${depPath}`);
  }
  const safe: string | undefined = dep.safe;

  const [deployer] = await ethers.getSigners();
  console.log(`[${net}] Deployer: ${deployer.address}`);
  console.log(`[${net}] FeeVault: ${feeVault}`);

  const Factory = await ethers.getContractFactory("MagnetaProxy");
  const proxy = await Factory.deploy(feeVault);
  await proxy.waitForDeployment();
  const proxyAddr = await proxy.getAddress();
  console.log(`[${net}] MagnetaProxy deployed: ${proxyAddr}`);

  // Verify the fee config wrote correctly. Some RPCs (notably testnets and
  // a few L2 sequencers) lag between `waitForDeployment` and code being
  // queryable via eth_call, so retry the first read-back before giving up.
  let onChainRecipient: string = "";
  let onChainBps = 0n;
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      onChainRecipient = await proxy.feeRecipient();
      onChainBps       = await proxy.feeBps();
      break;
    } catch (e) {
      if (attempt === 6) throw e;
      console.log(`[${net}] read-back not ready (attempt ${attempt}/6), waiting 5s…`);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
  console.log(`[${net}] On-chain: feeRecipient=${onChainRecipient}, feeBps=${onChainBps}`);

  // ── Whitelist routers BEFORE transferring ownership ──────────────────────
  //
  // The hardened MagnetaProxy (Sentinelle fix ce701c6) rejects any swap whose
  // swapTarget / spender is not allow-listed. If we transferred ownership to
  // the Safe first, the proxy would be dead-on-arrival (every swap reverts)
  // until a multisig batch whitelisted the routers. Doing it here, while the
  // deployer is still owner, keeps the deploy atomic and the proxy usable the
  // moment ownership lands on the Safe.
  //
  // Candidates: the in-house V2 router (canonical swap path for Magneta's
  // self-referencing architecture) and, on a chain with an adapter, the
  // adapter. Override via env ROUTER_WHITELIST (comma-separated) if needed.
  const c = dep.contracts || {};
  const routerCandidates: string[] = (process.env.ROUTER_WHITELIST
    ? process.env.ROUTER_WHITELIST.split(",")
    : [
        c.MagnetaV2Router02,
        c.MoeRouterAdapter, c.TraderJoeAvaxAdapter,
        c.UbeswapCeloAdapter, c.DragonSwapSeiAdapter,
        c.MockV2Router, // testnet only
      ]
  ).map((s) => (s || "").trim()).filter((a) => ethers.isAddress(a));

  // De-dup
  const routers = [...new Set(routerCandidates)];
  if (routers.length === 0) {
    throw new Error(
      `[${net}] No router to whitelist — set ROUTER_WHITELIST or add MagnetaV2Router02 to ${depPath}`,
    );
  }
  for (const r of routers) {
    const t1 = await proxy.setAllowedSwapTarget(r, true);
    await t1.wait();
    const t2 = await proxy.setAllowedSpender(r, true);
    await t2.wait();
    console.log(`[${net}] Whitelisted router (target+spender): ${r}`);
  }

  // Hand ownership to the Safe (multi-sig) so future changes require quorum.
  if (safe && ethers.isAddress(safe)) {
    console.log(`[${net}] Transferring ownership to Safe ${safe}…`);
    const tx = await proxy.transferOwnership(safe);
    await tx.wait();
    console.log(`[${net}] Ownership transferred (tx: ${tx.hash})`);
  } else {
    console.warn(`[${net}] No 'safe' in deployment JSON — ownership stays with deployer`);
  }

  // Persist to deployments/<network>.json
  if (!dep.contracts) dep.contracts = {};
  dep.contracts.MagnetaProxy = proxyAddr;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`[${net}] Wrote MagnetaProxy → ${depPath}`);

  console.log("");
  console.log("Next steps:");
  console.log(`  1. Set in DEX prod env:`);
  console.log(`     NEXT_PUBLIC_MAGNETA_PROXY_ADDRESS=${proxyAddr}`);
  console.log(`  2. Restart the DEX service`);
  console.log(`  3. Test a swap — 0.3% of input should land in ${feeVault}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
