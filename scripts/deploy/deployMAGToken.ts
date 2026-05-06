/**
 * Launch the MAG token via the existing `MagnetaOFTStandardFactory` already
 * deployed on every Magneta chain. The factory deploys a `MagnetaERC20OFT`
 * (cross-chain bridgeable) and mints the full supply to the caller.
 *
 * V1 launch path:
 *   - Run on the **canonical chain** of your choice (Polygon recommended:
 *     cheapest gas, most user activity). MAG can be bridged to other chains
 *     after launch via MagnetaBridgeOApp / OFT bridge.
 *   - Total supply: 1,000,000,000 MAG (18 decimals).
 *   - Caller (msg.sender = deployer EOA in this script) receives 100% of
 *     supply. Transfer to the in-house Safe immediately after, then
 *     distribute 40/20/15/25 via Safe txs to treasury / liquidity / team /
 *     community wallets.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployMAGToken.ts --network polygon
 *
 * Reads `contracts.MagnetaOFTStandardFactory` from deployments/{net}.json
 * (already populated by the Sprint 9.6 deploy on each chain). Errors out if
 * the factory isn't deployed yet on this chain — pick a different one.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const TOTAL_SUPPLY = ethers.parseUnits("1000000000", 18); // 1B MAG

const FACTORY_ABI = [
  {
    type: "function", stateMutability: "payable", name: "createOFTStandardToken",
    inputs: [
      { name: "name",         type: "string" },
      { name: "symbol",       type: "string" },
      { name: "tokenURI",     type: "string" },
      { name: "totalSupply",  type: "uint256" },
      { name: "revokeUpdate", type: "bool" },
      { name: "revokeFreeze", type: "bool" },
      { name: "revokeMint",   type: "bool" },
    ],
    outputs: [{ name: "token", type: "address" }],
  },
  { type: "function", stateMutability: "view", name: "createFee", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "event", name: "TokenCreated",
    inputs: [
      { indexed: true,  name: "token",   type: "address" },
      { indexed: true,  name: "creator", type: "address" },
      { indexed: false, name: "kind",    type: "string"  },
      { indexed: false, name: "name",    type: "string"  },
      { indexed: false, name: "symbol",  type: "string"  },
    ],
  },
] as const;

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const balance = await ethers.provider.getBalance(deployer.address);

  const depPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  if (!fs.existsSync(depPath)) throw new Error(`No deployment file for ${network.name}`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  const factoryAddr: string | undefined = dep?.contracts?.MagnetaOFTStandardFactory;
  if (!factoryAddr) {
    throw new Error(`MagnetaOFTStandardFactory not deployed on ${network.name} yet. Run Sprint 9.6 deploy first.`);
  }

  console.log(`\nDeployer       : ${deployer.address}`);
  console.log(`Network        : ${network.name} (${chainId})`);
  console.log(`Balance        : ${ethers.formatEther(balance)} native`);
  console.log(`Factory        : ${factoryAddr}`);
  console.log(`Total supply   : 1,000,000,000 MAG (18 decimals)`);
  console.log(`Initial holder : ${deployer.address} (deployer EOA — transfer to Safe right after)\n`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  const factory = new ethers.Contract(factoryAddr, FACTORY_ABI, deployer);

  const fee: bigint = await factory.createFee();
  console.log(`createFee      : ${ethers.formatEther(fee)} native`);

  console.log("\nSubmitting createOFTStandardToken…");
  const tx = await factory.createOFTStandardToken(
    "Magneta",                            // name
    "MAG",                                // symbol
    "ipfs://magneta-token-metadata.json", // URI — replace with real IPFS hash later
    TOTAL_SUPPLY,                         // 1B
    false,                                // revokeUpdate
    false,                                // revokeFreeze
    false,                                // revokeMint
    { value: fee },
  );
  console.log(`  tx: ${tx.hash}`);
  const receipt = await tx.wait();

  // Find the TokenCreated event in the receipt
  let mag: string | undefined;
  for (const log of receipt.logs ?? []) {
    // TokenCreated has 2 indexed args (token, creator) → topics has 3 entries
    // (signature + token + creator). Earlier filter required ≥4 which dropped it.
    if (log.address.toLowerCase() === factoryAddr.toLowerCase() && log.topics?.length >= 3) {
      mag = "0x" + log.topics[1]!.slice(-40);
      break;
    }
  }
  if (!mag) throw new Error("Couldn't decode TokenCreated event — check the tx on the explorer");

  console.log(`\nMAG deployed   : ${mag}`);

  const out = {
    network:        network.name,
    chainId,
    deployer:       deployer.address,
    initialHolder:  deployer.address,
    factory:        factoryAddr,
    token:          mag,
    totalSupply:    TOTAL_SUPPLY.toString(),
    txHash:         tx.hash,
    deployedAt:     new Date().toISOString(),
  };
  const outPath = path.join(__dirname, "..", "..", "deployments", `${network.name}-mag.json`);
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
  console.log(`Saved to ${outPath}\n`);

  console.log("══════════════════════════════════════════════════");
  console.log("DISTRIBUTION TODOs (run from your wallet / Safe):");
  console.log("══════════════════════════════════════════════════");
  console.log(`1. Transfer entire balance to in-house Safe: 0x40ea2908Ea490d58E62D1Fd3364464D8A857b297`);
  console.log(`2. From Safe, distribute 1B MAG:`);
  console.log(`     400M → treasury wallet`);
  console.log(`     200M → liquidity wallet (curve seed / AMM)`);
  console.log(`     150M → team-vesting contract`);
  console.log(`     250M → community / airdrop pool`);
  console.log(`3. (Optional) Bridge MAG to other chains via MagnetaBridgeOApp`);
  console.log(`4. Activate Discord @verified via Collab.Land TGR with this MAG address`);
}

main().catch((e) => { console.error(e); process.exit(1); });
