/**
 * Deploy MagnetaXChainLpReceiver — the permissionless destination-chain
 * receiver for the LI.FI cross-chain LP flow (memory:
 * project_crosschain_lp_bridge_strategy).
 *
 * What it does:
 *   1. Resolves the chain's V2 router (chainConfig.defaultRouter, or the
 *      in-house MagnetaV2Router02 / adapter), exactly like deployMagnetaProxy.
 *      Override with ROUTER env (single address).
 *   2. Reads wnative from router.WETH() on-chain (no hard-coded WETH address).
 *   3. Deploys MagnetaXChainLpReceiver(router, wnative).
 *   4. Transfers ownership to the same owner the existing MagnetaProxyV2 has
 *      (the chain's Safe, or deployer EOA where Safe UI is unsupported) —
 *      Ownable2Step, so that owner must acceptOwnership().
 *   5. Writes the address under contracts.MagnetaXChainLpReceiver.
 *
 * The receiver only ever holds native transiently inside one atomic, reentrancy-
 * guarded call, so there is nothing to whitelist/configure post-deploy — unlike
 * the proxy, it is usable the moment it is deployed. Ownership only governs the
 * owner-only rescue functions (stray donations).
 *
 * Post-deploy: set the address in the Tokens app env so the LI.FI quote targets
 * it as the destination contract call:
 *     NEXT_PUBLIC_XCHAIN_LP_RECEIVER_<CHAINID>=<deployed address>
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployXChainLpReceiver.ts --network polygon
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
  const c  = dep.contracts || {};
  const cc = dep.chainConfig || {};

  // ── Resolve the V2 router ────────────────────────────────────────────────
  // Same canonical swap router the DEX/LPModule routes through on this chain.
  const routerRaw = (process.env.ROUTER
    || cc.defaultRouter
    || c.MagnetaV2Router02
    || "").trim();
  if (!ethers.isAddress(routerRaw)) {
    throw new Error(`[${net}] No V2 router resolved — set ROUTER or chainConfig.defaultRouter in ${depPath}`);
  }
  const router = ethers.getAddress(routerRaw);

  const [deployer] = await ethers.getSigners();
  console.log(`[${net}] Deployer: ${deployer.address}`);
  console.log(`[${net}] Router:   ${router}`);

  // wnative MUST equal router.WETH() — read it on-chain rather than trust config.
  const routerC = await ethers.getContractAt(
    ["function WETH() view returns (address)"],
    router,
  );
  let wnative: string;
  try {
    wnative = await routerC.WETH();
  } catch (e) {
    throw new Error(`[${net}] router.WETH() reverted — is ${router} a V2 router? ${(e as Error).message}`);
  }
  if (!ethers.isAddress(wnative) || wnative === ethers.ZeroAddress) {
    throw new Error(`[${net}] router.WETH() returned a bad address: ${wnative}`);
  }
  console.log(`[${net}] WNative:  ${wnative}`);

  // ── Deploy ───────────────────────────────────────────────────────────────
  const Factory = await ethers.getContractFactory("MagnetaXChainLpReceiver");
  const receiver = await Factory.deploy(router, wnative);
  await receiver.waitForDeployment();
  const addr = await receiver.getAddress();
  console.log(`[${net}] MagnetaXChainLpReceiver deployed: ${addr}`);

  // Read-back with retry (some L2 sequencers lag between deploy and eth_call).
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      const r = await receiver.router();
      const w = await receiver.wnative();
      console.log(`[${net}] On-chain: router=${r}, wnative=${w}`);
      break;
    } catch (e) {
      if (attempt === 6) throw e;
      console.log(`[${net}] read-back not ready (attempt ${attempt}/6), waiting 5s…`);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }

  // ── Transfer ownership to the canonical per-chain owner ───────────────────
  // Match the existing MagnetaProxyV2 owner on-chain (main Safe, in-house Safe,
  // or deployer EOA where Safe UI isn't supported). Ownership only governs the
  // rescue functions, but we keep it consistent with the rest of the suite.
  let target = "";
  const safe: string | undefined = dep.safe;
  if (safe && ethers.isAddress(safe)) target = safe;
  const existingV2: string | undefined = c.MagnetaProxyV2 || c.MagnetaProxy;
  if (existingV2 && ethers.isAddress(existingV2)) {
    try {
      const prev = await ethers.getContractAt("MagnetaProxy", existingV2);
      const prevOwner: string = await prev.owner();
      if (ethers.isAddress(prevOwner) && prevOwner !== ethers.ZeroAddress) {
        target = prevOwner;
        console.log(`[${net}] Existing proxy owner: ${prevOwner}`);
      }
    } catch {
      console.warn(`[${net}] Could not read existing proxy owner; falling back to safe field`);
    }
  }

  if (target && ethers.isAddress(target) && target.toLowerCase() !== deployer.address.toLowerCase()) {
    console.log(`[${net}] Transferring ownership to ${target} (Ownable2Step → pendingOwner)…`);
    const tx = await receiver.transferOwnership(target);
    await tx.wait();
    console.log(`[${net}] transferOwnership sent (tx: ${tx.hash}); ${target} must acceptOwnership()`);
  } else {
    console.warn(`[${net}] Target owner == deployer (or unknown) — ownership stays with deployer`);
  }

  // ── Persist ────────────────────────────────────────────────────────────────
  if (!dep.contracts) dep.contracts = {};
  dep.contracts.MagnetaXChainLpReceiver = addr;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`[${net}] Wrote MagnetaXChainLpReceiver → ${depPath}`);

  console.log("");
  console.log("Next steps:");
  console.log(`  1. Set in Tokens app prod env:`);
  console.log(`     NEXT_PUBLIC_XCHAIN_LP_RECEIVER_${cc.chainId ?? "<chainId>"}=${addr}`);
  console.log(`  2. Wire the address into the LI.FI destinationCall target (lib/lifi/lifiRouter.ts)`);
  console.log(`  3. ${target ? `${target} accepts ownership (Safe batch)` : "ownership stays with deployer"}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
