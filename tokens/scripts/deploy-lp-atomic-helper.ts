/**
 * V1.1 — Deploy MagnetaLpAtomicHelper on a single chain.
 *
 * The helper collapses the two sequential Liquidity-Manage wizards
 * (Pool Fee Collection / LP Rebalance "Compound" and Migrate Liquidity)
 * from a 4-tx flow into a single helper call. See
 * contracts/solidity/contracts/MagnetaLpAtomicHelper.sol.
 *
 * The contract is INTENTIONALLY stateless:
 *   - no constructor args
 *   - no owner / admin role (no Ownable inheritance)
 *   - holds no standing approvals or balances across calls
 * So there is nothing to transfer to the Safe after deploy — the only
 * post-deploy action is recording the address + verifying on the explorer
 * and wiring the address into the frontend (lib/sdk/lpAtomicSdk.ts).
 *
 *   Usage:
 *     pnpm hardhat run scripts/deploy-lp-atomic-helper.ts --network polygon
 *
 *   After running on every target chain:
 *     1. Run the Sentinelle scan on the deployed bytecode (the .sol already
 *        carries a scan; re-scan the deployed instance per policy).
 *     2. Add the address to LP_ATOMIC_HELPER_BY_CHAIN in
 *        lib/sdk/lpAtomicSdk.ts (single source of truth — both
 *        PoolFeeCollection.tsx and MigrateLiquidity.tsx read from there and
 *        auto-fall-back to the V1 sequential flow when a chain is absent).
 *
 * Deploy is a separate owner op (see docs/contract-redeploy-runbook.md);
 * this script only broadcasts the helper-deploy tx — no ownership / wiring
 * transactions are sent.
 */
import { ethers, network, run } from "hardhat";
import * as fs from "fs";
import * as path from "path";

interface HelperDeployment {
  network: string;
  chainId: number;
  contract: "MagnetaLpAtomicHelper";
  address: string;
  deployer: string;
  /** Informational only — the helper has no owner to transfer to. */
  safe: string | null;
  timestamp: string;
}

/**
 * Reads the per-chain Safe address from the sibling contracts repo's
 * `deployments/<chain>.json`. Recorded purely for traceability (the helper
 * is ownerless — there is no transferOwnership step). Mirrors the lookup in
 * deploy-create-token-dispatcher.ts. Returns null if not found.
 */
function readChainSafe(networkName: string): string | null {
  const contractsDeployPath = path.resolve(
    __dirname, "..", "..", "..", "..",
    "magneta-finance-contracts", "deployments", `${networkName}.json`,
  );
  if (!fs.existsSync(contractsDeployPath)) return null;
  const j = JSON.parse(fs.readFileSync(contractsDeployPath, "utf-8"));
  return j.gnosisSafe || null;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n── V1.1 — MagnetaLpAtomicHelper deploy ──`);
  console.log(`Network    : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer   : ${deployer.address}`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance    : ${ethers.formatEther(balance)} native`);
  if (balance === 0n) throw new Error("Deployer balance is 0 — fund it first");

  const safe = readChainSafe(network.name); // informational only
  console.log(`Safe       : ${safe ?? "(none recorded — helper is ownerless)"}\n`);

  // ─── Deploy (no constructor args) ────────────────────────────────────────
  console.log("Deploying MagnetaLpAtomicHelper...");
  const Helper = await ethers.getContractFactory("MagnetaLpAtomicHelper");
  const helper = await Helper.deploy();
  await helper.waitForDeployment();
  const addr = await helper.getAddress();
  console.log(`  → ${addr}`);

  // ─── Persist deployment record ───────────────────────────────────────────
  const result: HelperDeployment = {
    network: network.name,
    chainId,
    contract: "MagnetaLpAtomicHelper",
    address: addr,
    deployer: deployer.address,
    safe,
    timestamp: new Date().toISOString(),
  };

  const outDir = path.join(__dirname, "..", "deployments-lp-atomic");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n");
  console.log(`\nDeployment record: ${outPath}`);

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`Gas spent  : ${ethers.formatEther(spent)} native\n`);

  // ─── Next steps ──────────────────────────────────────────────────────────
  console.log("─── NEXT STEPS ───");
  console.log("1. (No ownership transfer — the helper is ownerless / stateless.)");
  console.log("2. Re-run the Sentinelle scan on the deployed instance per policy.");
  console.log("3. Wire the address into lib/sdk/lpAtomicSdk.ts:");
  console.log(`     ${chainId}: '${addr}',`);
  console.log("   PoolFeeCollection.tsx + MigrateLiquidity.tsx read from there and");
  console.log("   will switch this chain from the V1 4-tx flow to the 1-helper-call flow.");
  console.log("4. Verify on the block explorer (no constructor args):");
  console.log(`   pnpm hardhat verify --network ${network.name} ${addr}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
