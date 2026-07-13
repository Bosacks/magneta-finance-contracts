/**
 * Sprint 3 Step 1 — Deploy the MagnetaOFT Standard factory on a single chain.
 *
 * Deploys:
 *   1. MagnetaOFTStandardFactory(treasury, lzEndpoint)
 *
 * NOTE: the AutoLiquidity factory is intentionally NOT deployed here. The
 * AutoLiquidity template was retired (the bonding-curve Launchpad replaced it);
 * the existing AutoLiquidity factories stay live on-chain but are no longer fed
 * by the UI, so there is no reason to deploy a fresh one.
 *
 * After this script runs:
 *   - The factory is owned by the deployer EOA.
 *   - `setCrossChainCreator` is NOT yet set (waits for Step 2 in the contracts
 *     repo, which deploys the TokenCreationModule and wires it).
 *   - Ownership is NOT yet transferred to the Safe (waits for Step 3 batch).
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy-oft-factories.ts --network arbitrum
 *
 * Output:
 *   Writes deployments-oft/<network>.json with the factory address.
 *   The contracts repo's deploy step reads this file.
 *
 * Skip Cronos (no LZ V2). The script self-detects from CHAIN_CONFIG.
 */
import { ethers, network, run } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { CHAIN_CONFIG } from "./chainConfig";

interface OFTDeployment {
  network: string;
  chainId: string;
  deployer: string;
  treasury: string;
  lzEndpoint: string;
  timestamp: string;
  factories: {
    MagnetaOFTStandardFactory: string;
  };
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n── Sprint 3 Step 1 — OFT factories ──`);
  console.log(`Network    : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer   : ${deployer.address}`);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) {
    throw new Error(`No chain config for chainId ${chainId}. Add it to scripts/chainConfig.ts.`);
  }
  if (cfg.lzEndpoint === null) {
    console.log(`\n⚠ Skipping ${network.name} — no LZ V2 endpoint (Cronos pattern).`);
    console.log(`  Cross-chain token creation on this chain is handled by the off-chain Relayer (Sprint 5).`);
    return;
  }

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance    : ${ethers.formatEther(balance)} native`);
  console.log(`Treasury   : ${cfg.treasury}`);
  console.log(`LZ endpoint: ${cfg.lzEndpoint}\n`);

  if (balance === 0n) {
    throw new Error("Deployer has 0 balance — fund it first");
  }

  // ─── Deploy MagnetaOFTStandardFactory ───────────────────────────────────
  console.log("Deploying MagnetaOFTStandardFactory...");
  const StdFactory = await ethers.getContractFactory("MagnetaOFTStandardFactory");
  const stdFactory = await StdFactory.deploy(cfg.treasury, cfg.lzEndpoint);
  await stdFactory.waitForDeployment();
  const stdAddr = await stdFactory.getAddress();
  console.log(`  → ${stdAddr}`);

  // ─── Persist ────────────────────────────────────────────────────────────
  const result: OFTDeployment = {
    network: network.name,
    chainId: chainId.toString(),
    deployer: deployer.address,
    treasury: cfg.treasury,
    lzEndpoint: cfg.lzEndpoint,
    timestamp: new Date().toISOString(),
    factories: {
      MagnetaOFTStandardFactory: stdAddr,
    },
  };

  const outDir = path.join(__dirname, "..", "deployments-oft");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n");
  console.log(`\nDeployment record: ${outPath}`);

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`Gas spent  : ${ethers.formatEther(spent)} native\n`);

  console.log("─── NEXT STEPS ───");
  console.log("1. Run from magneta-finance-contracts/:");
  console.log(`   pnpm hardhat run scripts/deploy/deployTokenCreation.ts --network ${network.name}`);
  console.log("2. After all chains deployed, sign Safe batch:");
  console.log(`   safe/<chain>-OFTSetup-batch.json`);
  console.log("3. Verify contract on Etherscan:");
  console.log(`   pnpm hardhat verify --network ${network.name} ${stdAddr} ${cfg.treasury} ${cfg.lzEndpoint}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
