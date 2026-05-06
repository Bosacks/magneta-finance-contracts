/**
 * Deploy the MAG token via the existing tokens-repo factory pattern.
 *
 * V1 launch path:
 *   - Deploy on the **canonical chain** of your choice (Polygon recommended
 *     — cheapest gas, most user activity). Other chains get MAG via the
 *     OFT bridge after launch.
 *   - Total supply: 1,000,000,000 MAG (18 decimals).
 *   - All supply minted to the in-house Safe `0x40ea…b297` (or any address
 *     you pass via TREASURY_OWNER env var). The operator then distributes
 *     to treasury / liquidity / team-vesting / community wallets per the
 *     planned 40/20/15/25 split via separate Safe txs.
 *
 * Usage:
 *   TREASURY_OWNER=0x40ea2908Ea490d58E62D1Fd3364464D8A857b297 \
 *   pnpm hardhat run scripts/deploy/deployMAGToken.ts --network polygon
 *
 * After this script:
 *   - Update chainConfig.ts / frontend constants with the MAG address
 *   - Add MAG to MAGNETA_TREASURY_ADDRESS, swap token lists, etc.
 *   - Wire LayerZero peer addresses on the canonical chain to the eventual
 *     MAG address on other chains (or just keep MAG canonical-only for V1).
 *
 * The token is a standard `MagnetaERC20OFT` (paid path, not curve fair-launch)
 * so it has all the admin features: blacklist, pause, freeze, tax, etc.
 * Revoke flags default to false — operator decides when (if ever) to lock
 * those features down.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG, FEE_VAULT } from "./chainConfig";

const DEFAULT_TOTAL_SUPPLY = ethers.parseUnits("1000000000", 18); // 1B MAG

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No chain config for chainId ${chainId}`);
  if (!cfg.lzEndpoint) {
    throw new Error(`Chain ${chainId} has no LZ V2 endpoint — MAG must launch on a LZ-supported chain`);
  }

  const initialOwner = (process.env.TREASURY_OWNER ?? "").toLowerCase();
  if (!initialOwner || !initialOwner.startsWith("0x") || initialOwner.length !== 42) {
    throw new Error("TREASURY_OWNER env var required (0x… 20-byte address that holds 100% of supply at deploy)");
  }

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`\nDeployer       : ${deployer.address}`);
  console.log(`Network        : ${network.name} (${chainId})`);
  console.log(`Balance        : ${ethers.formatEther(balance)} native`);
  console.log(`LZ endpoint    : ${cfg.lzEndpoint}`);
  console.log(`Initial holder : ${initialOwner} (will receive 100% of supply)`);
  console.log(`Total supply   : 1,000,000,000 MAG (18 decimals)\n`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  // Pull the OFT artifact from the tokens repo (alongside the contracts repo
  // in the workspace). If you maintain a local copy, repoint the import.
  const Token = await ethers.getContractFactory(
    "contracts/solidity/contracts/MagnetaERC20OFT.sol:MagnetaERC20OFT",
  ).catch(async () => {
    // Fallback when the tokens repo's source isn't in this repo's compile
    // path — the operator can copy MagnetaERC20OFT.sol into contracts/tokens/
    // before running, or generate the deploy via the tokens repo's own
    // hardhat config.
    throw new Error(
      "MagnetaERC20OFT not in this repo's compile path. Either copy " +
      "magneta-finance-tokens/contracts/solidity/contracts/MagnetaERC20OFT.sol " +
      "into magneta-finance-contracts/contracts/tokens/ and recompile, OR run " +
      "this deploy via the tokens repo's hardhat (which has the source).",
    );
  });

  const token = await Token.deploy(
    "Magneta",                               // name
    "MAG",                                   // symbol
    "ipfs://magneta-token-metadata.json",    // URI — replace with real IPFS hash
    DEFAULT_TOTAL_SUPPLY,                    // 1B
    initialOwner,                            // initialOwner (also gets full supply)
    false,                                   // revokeUpdate (no — keep flexibility V1)
    false,                                   // revokeFreeze
    false,                                   // revokeMint
    cfg.lzEndpoint,                          // _lzEndpoint
    "0x0000000000000000000000000000000000000000", // tokenOpsModule (none for MAG)
  );
  await token.waitForDeployment();
  const tokenAddr = await token.getAddress();
  console.log(`MAG deployed   : ${tokenAddr}`);

  const out = {
    network: network.name,
    chainId,
    deployer: deployer.address,
    initialOwner,
    feeVault: FEE_VAULT,
    token: tokenAddr,
    totalSupply: DEFAULT_TOTAL_SUPPLY.toString(),
    deployedAt: new Date().toISOString(),
  };
  const outPath = path.join(__dirname, "..", "..", "deployments", `${network.name}-mag.json`);
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
  console.log(`Saved to ${outPath}\n`);

  console.log("══════════════════════════════════════════════════");
  console.log("DISTRIBUTION TODOs (operator runs these via Safe):");
  console.log("══════════════════════════════════════════════════");
  console.log("1. From initial holder, send 400M MAG → treasury wallet");
  console.log("2. From initial holder, send 200M MAG → liquidity wallet (curve / AMM seed)");
  console.log("3. From initial holder, send 150M MAG → team-vesting contract");
  console.log("4. From initial holder, send 250M MAG → community / airdrop pool");
  console.log("5. (Optional) Bridge MAG to other chains via MagnetaBridgeOApp\n");
}

main().catch((e) => { console.error(e); process.exit(1); });
