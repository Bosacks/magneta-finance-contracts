/**
 * Deploy canonical Safe v1.4.1 contracts on a chain that doesn't have them.
 *
 * Used only for chains where Safe team has not deployed (e.g., Dexalot subnet).
 * Almost every other EVM chain has these already.
 *
 * Strategy:
 *   1. Deploy SafeSingletonFactory (a deterministic CREATE2 deployer) — this is itself
 *      deployed via a pre-signed transaction so it has the same address everywhere.
 *   2. Use SafeSingletonFactory to deploy:
 *      - SafeL2 singleton at the canonical address
 *      - SafeProxyFactory at the canonical address
 *      - CompatibilityFallbackHandler at the canonical address
 *      - MultiSendCallOnly at the canonical address
 *
 * Usage: pnpm hardhat run scripts/safe/inhouse/deploySafeInfra.ts --network dexalot
 *
 * Note: This is a placeholder. For production use, prefer fetching the deployment
 * transactions from @safe-global/safe-singleton-factory and submitting them via
 * the deployer EOA. The pre-signed tx approach guarantees same addresses everywhere.
 *
 * For now, this script CHECKS what's missing and prints instructions.
 */
import { ethers, network } from "hardhat";
import {
  SAFE_PROXY_FACTORY,
  SAFE_L2_SINGLETON,
  COMPATIBILITY_FALLBACK_HANDLER,
  MULTISEND_CALLONLY,
  SAFE_SINGLETON_FACTORY,
} from "./lib/safe";

async function main() {
  const provider = ethers.provider;

  const checks = [
    { name: "SafeSingletonFactory", addr: SAFE_SINGLETON_FACTORY },
    { name: "SafeProxyFactory", addr: SAFE_PROXY_FACTORY },
    { name: "SafeL2 singleton", addr: SAFE_L2_SINGLETON },
    { name: "CompatibilityFallbackHandler", addr: COMPATIBILITY_FALLBACK_HANDLER },
    { name: "MultiSendCallOnly", addr: MULTISEND_CALLONLY },
  ];

  console.log(`Network    : ${network.name}`);
  console.log(`Checking canonical Safe v1.4.1 contracts...\n`);

  let missing = 0;
  for (const c of checks) {
    const code = await provider.getCode(c.addr);
    const ok = code !== "0x";
    if (ok) {
      console.log(`  ✅ ${c.name.padEnd(35)} ${c.addr}`);
    } else {
      console.log(`  ❌ ${c.name.padEnd(35)} ${c.addr}  (NOT DEPLOYED)`);
      missing++;
    }
  }

  console.log();

  if (missing === 0) {
    console.log(`All canonical Safe contracts are present on ${network.name}.`);
    console.log(`You can now run: pnpm hardhat run scripts/safe/inhouse/createMagnetaSafe.ts --network ${network.name}`);
    return;
  }

  console.log(`${missing} canonical contract(s) missing.`);
  console.log();
  console.log(`To deploy them, fetch the pre-signed deployment transactions from:`);
  console.log(`  https://github.com/safe-global/safe-singleton-factory`);
  console.log(`  https://github.com/safe-global/safe-deployments`);
  console.log();
  console.log(`Or use the Safe CLI:`);
  console.log(`  npx @safe-global/safe-deployments deploy --network ${network.name}`);
  console.log();
  console.log(`Each deployment costs ~$0.50-2 in gas. Total for all 5: ~$3-10.`);
  console.log(`After this, addresses will be IDENTICAL to canonical addresses on all other chains.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
