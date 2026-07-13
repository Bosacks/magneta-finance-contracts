/**
 * Redeploy MagnetaCurveFactory pointing at the Magneta V2 router (instead of
 * the external defaultRouter the original launchpad used).
 *
 * Why a separate script: the existing deployCurveLaunchpad.ts reads
 * `defaultRouter` from CHAIN_CONFIG (the chain's external V2 DEX like
 * QuickSwap). This script is for the migration: we want the curve factory
 * to use the freshly deployed `MagnetaV2Router02` instead, so future curve
 * tokens graduate into Magneta-owned pools.
 *
 * Bonus: this redeployment also picks up the slippage protection
 * (Option 3 + Option 1) we baked into MagnetaCurvePool.sol. The on-chain
 * factory's deployed bytecode embeds the pool init code at compile time —
 * the only way for new pools to have the protection is to redeploy the
 * factory with the updated source.
 *
 * Required entries in deployments/<network>.json:
 *   - feeVault (string, EVM address)
 *   - contracts.MagnetaV2Router02 (string, EVM address)
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/redeployCurveFactory.ts --network polygon
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

async function main() {
  const net = network.name;
  const depPath = path.join(__dirname, "..", "..", "deployments", `${net}.json`);
  if (!fs.existsSync(depPath)) throw new Error(`No deployments file at ${depPath}`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));

  const feeVault: string = dep.feeVault;
  const router:   string | undefined = dep.contracts?.MagnetaV2Router02;
  const oldFactory: string | undefined = dep.contracts?.MagnetaCurveFactory;

  if (!feeVault || !ethers.isAddress(feeVault))  throw new Error(`feeVault missing in ${depPath}`);
  if (!router   || !ethers.isAddress(router))    throw new Error(`contracts.MagnetaV2Router02 missing — run deployMagnetaV2Dex.ts first`);

  const [deployer] = await ethers.getSigners();
  console.log(`\n=== Redeploy MagnetaCurveFactory on ${net} ===`);
  console.log(`Deployer:           ${deployer.address}`);
  console.log(`FeeVault:           ${feeVault}`);
  console.log(`Magneta V2 Router:  ${router}`);
  console.log(`Old factory (orph): ${oldFactory ?? "(none)"}`);
  console.log("");

  const Factory = await ethers.getContractFactory("MagnetaCurveFactory");
  const factory = await Factory.deploy(router, feeVault, deployer.address);
  await factory.waitForDeployment();
  const newFactoryAddr = await factory.getAddress();
  console.log(`New MagnetaCurveFactory deployed: ${newFactoryAddr}`);

  // Some public RPCs need a couple of seconds to index the new code before
  // they can answer view calls. Sleep briefly to avoid a spurious BAD_DATA.
  await new Promise((r) => setTimeout(r, 3000));

  // Sanity: router was set as constructor arg, verify on-chain
  let onChainRouter: string;
  try {
    onChainRouter = await factory.router();
    console.log(`On-chain router: ${onChainRouter}`);
  } catch {
    console.warn(`router() lookup failed (RPC lag) — contract is deployed at ${newFactoryAddr}, verify manually:`);
    console.warn(`  cast call ${newFactoryAddr} 'router()(address)' --rpc-url <RPC>`);
    onChainRouter = router;  // assume it's correct since constructor used it
  }

  // Persist — keep the old factory address under a legacy key for audit history
  if (!dep.contracts) dep.contracts = {};
  if (oldFactory) {
    dep.contracts.MagnetaCurveFactoryV1 = oldFactory;
  }
  dep.contracts.MagnetaCurveFactory = newFactoryAddr;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`Wrote to ${depPath}`);

  console.log("\n=== Done ===");
  console.log(`Frontend update:`);
  console.log(`  magneta-finance-tokens lib/constants/contracts.ts`);
  console.log(`  MAGNETA_CURVE_FACTORY_ADDRESS[${dep.chainId}] = "${newFactoryAddr}"`);
  console.log("");
  console.log(`Note: the old factory ${oldFactory ?? "(none)"} stays on-chain but is no longer referenced.`);
  console.log(`      Tokens already created via it keep their immutable router — they will not benefit`);
  console.log(`      from the new slippage protection. Only NEW tokens created via the new factory will.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
