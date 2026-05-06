/**
 * Deploy Magneta's own UniswapV2-fork AMM on any EVM chain.
 *
 *   pnpm hardhat run scripts/deploy/deployMagnetaAMM.ts --network polygon
 *   pnpm hardhat run scripts/deploy/deployMagnetaAMM.ts --network base
 *   ...
 *
 * Stack:
 *   1. WETH9              (wrapped native — WPOL on Polygon, WETH on Base, etc.)
 *   2. UniswapV2Factory   (official @uniswap/v2-core, unchanged)
 *   3. MagnetaV2Router02  (vendored fork using the patched init code hash
 *                          0xf407…95d2 that matches our locally-compiled Pair)
 *
 * Once the stack lands on a chain, point the relevant downstream config to
 * the new router:
 *   - chainConfig.ts `defaultRouter` → `router` from the deployment file
 *   - MAGNETA_CURVE_FACTORY_ADDRESS pools created hereafter graduate to this
 *     router by default; existing curves keep their original target.
 *
 * V1 = no fee switch on, no migration helpers. Ship it as-is, let user
 * tokens trade. V1.1 will add `factory.setFeeTo(FEE_VAULT)` + `feeToSetter`
 * transfer once we have a fee policy decided.
 *
 * Idempotent across re-runs: writes to `deployments/{net}-magneta-amm.json`.
 * Re-running re-deploys (no skip) — call once per chain.
 */
import { ethers, network } from "hardhat";
import fs from "fs";
import path from "path";

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const balance = await ethers.provider.getBalance(deployer.address);

  console.log(`\nDeployer  : ${deployer.address}`);
  console.log(`Network   : ${network.name} (${chainId})`);
  console.log(`Balance   : ${ethers.formatEther(balance)} native`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  // 1. WETH9 — wraps native, Pair pricing assumes 18 decimals.
  console.log("\nDeploying WETH9 (wraps native)...");
  const WETH9 = await ethers.getContractFactory("WETH9");
  const weth9 = await WETH9.deploy();
  await weth9.waitForDeployment();
  const wethAddr = await weth9.getAddress();
  console.log(`  WETH9   : ${wethAddr}`);

  // 2. UniswapV2Factory — feeToSetter = deployer (transfer to Safe later).
  console.log("\nDeploying UniswapV2Factory...");
  const Factory = await ethers.getContractFactory("UniswapV2Factory");
  const factory = await Factory.deploy(deployer.address);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log(`  Factory : ${factoryAddr}`);

  // 3. MagnetaV2Router02 — vendored fork using MagnetaV2Library (patched
  //    init code hash matching our compiled Pair).
  console.log("\nDeploying MagnetaV2Router02...");
  const Router = await ethers.getContractFactory("MagnetaV2Router02");
  const router = await Router.deploy(factoryAddr, wethAddr);
  await router.waitForDeployment();
  const routerAddr = await router.getAddress();
  console.log(`  Router  : ${routerAddr}`);

  const out = {
    network:           network.name,
    chainId,
    deployer:          deployer.address,
    weth9:             wethAddr,
    factory:           factoryAddr,
    router:            routerAddr,
    pairInitCodeHash:  "0xf40783a955a9be9bf11de05e90244c2b6394edc5f348e5dcd168dba8661a95d2",
    deployedAt:        new Date().toISOString(),
  };
  const outPath = path.join(__dirname, "..", "..", "deployments", `${network.name}-magneta-amm.json`);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
  console.log(`\nWrote ${outPath}`);

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`Gas spent: ${ethers.formatEther(spent)} native\n`);

  console.log("══════════════════════════════════════════════════");
  console.log("NEXT STEPS:");
  console.log("══════════════════════════════════════════════════");
  console.log("1. Transfer Factory feeToSetter to the in-house Safe");
  console.log("2. Update chainConfig.ts defaultRouter on this chain (optional —");
  console.log("   only required if you want CREATE_LP / curve graduations to");
  console.log("   route through Magneta AMM instead of the external default).");
  console.log("3. (V1.1) Set Factory.setFeeTo(FEE_VAULT) once fee policy decided.\n");
}

main().catch((e) => { console.error(e); process.exit(1); });
