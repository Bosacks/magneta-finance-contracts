/**
 * Deploy MAG (MagnetaERC20OFT) on a NON-canonical chain — direct constructor
 * call, no factory wrapper. The factory exists on Polygon (where MAG was first
 * deployed with 1B supply) but we don't need it elsewhere.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy-mag-oft-secondary.ts --network base
 *
 * Reads:
 *   - chainConfig.ts → lzEndpoint per chain (skips Cronos which has no LZ V2)
 *   - ../../../magneta-finance-contracts/deployments/{net}.json → TokenOpsModule
 *
 * Writes the MAG address into:
 *   1. magneta-finance-contracts/deployments/{net}.json under contracts.MAG
 *   2. deployments-mag/{net}.json (local copy for cross-script lookups)
 *
 * Refuses to run on Polygon (canonical 1B-supply chain — use deployMAGToken.ts there).
 */
import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { CHAIN_CONFIG } from "./chainConfig";

const CONTRACTS_REPO = path.join(__dirname, "..", "..", "..", "..", "magneta-finance-contracts");
const SECONDARY_SUPPLY = 0n;

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  if (chainId === 137) {
    throw new Error("Polygon is the canonical MAG chain — use deployMAGToken.ts there, not this script.");
  }

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) {
    throw new Error(`No chain config for chainId ${chainId}. Add it to scripts/chainConfig.ts.`);
  }
  if (cfg.lzEndpoint === null) {
    console.log(`⚠ Skipping ${network.name} — no LZ V2 endpoint (e.g. Cronos)`);
    return;
  }

  // TokenOpsModule lives in the contracts repo deployments file.
  const contractsDep = path.join(CONTRACTS_REPO, "deployments", `${network.name}.json`);
  if (!fs.existsSync(contractsDep)) {
    throw new Error(`No contracts-repo deployment for ${network.name} at ${contractsDep}`);
  }
  const dep = JSON.parse(fs.readFileSync(contractsDep, "utf8"));
  const tokenOpsModule: string | undefined = dep?.contracts?.TokenOpsModule;
  if (!tokenOpsModule) {
    // The MagnetaERC20OFT constructor will accept address(0) but freeze/burn
    // ops on the OFT will be unavailable. For V1.1.B that's fine — bridging
    // doesn't need TokenOps. Surface a warning, don't error.
    console.warn(`⚠ TokenOpsModule missing for ${network.name} — deploying MAG with address(0).`);
  }

  if (dep?.contracts?.MAG) {
    console.log(`⏭  MAG already deployed at ${dep.contracts.MAG} on ${network.name} — skipping.`);
    return;
  }

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`\nDeployer       : ${deployer.address}`);
  console.log(`Network        : ${network.name} (${chainId})`);
  console.log(`Balance        : ${ethers.formatEther(balance)} native`);
  console.log(`LZ endpoint    : ${cfg.lzEndpoint}`);
  console.log(`TokenOpsModule : ${tokenOpsModule ?? "(none)"}`);
  console.log(`Initial supply : 0 (secondary chain — supply mints on bridge-in)\n`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  const Factory = await ethers.getContractFactory("MagnetaERC20OFT");
  const mag = await Factory.deploy(
    "Magneta",                            // name
    "MAG",                                // symbol
    "ipfs://magneta-token-metadata.json", // URI
    SECONDARY_SUPPLY,                     // 0
    deployer.address,                     // initialOwner — transfer to Safe later
    false,                                // revokeUpdate
    false,                                // revokeFreeze
    false,                                // revokeMint
    cfg.lzEndpoint,                       // _lzEndpoint
    tokenOpsModule ?? ethers.ZeroAddress, // _tokenOpsModule
  );
  await mag.waitForDeployment();
  const addr = await mag.getAddress();
  console.log(`MAG deployed   : ${addr}`);

  // Persist into contracts-repo deployments file (so generateMAGPeerWiringBatches
  // can find it) AND a local copy.
  dep.contracts = { ...(dep.contracts ?? {}), MAG: addr };
  fs.writeFileSync(contractsDep, JSON.stringify(dep, null, 2) + "\n");
  console.log(`Saved to ${contractsDep}`);

  const localDir = path.join(__dirname, "..", "deployments-mag");
  if (!fs.existsSync(localDir)) fs.mkdirSync(localDir, { recursive: true });
  fs.writeFileSync(
    path.join(localDir, `${network.name}.json`),
    JSON.stringify({
      network: network.name, chainId, mag: addr,
      lzEndpoint: cfg.lzEndpoint,
      tokenOpsModule: tokenOpsModule ?? ethers.ZeroAddress,
      deployer: deployer.address, deployedAt: new Date().toISOString(),
    }, null, 2) + "\n"
  );
}

main().catch((e) => { console.error(e); process.exit(1); });
