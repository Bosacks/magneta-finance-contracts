/**
 * Deploy a MAG OFT on a NON-canonical chain (canonical = Polygon, where MAG
 * already lives with full 1B supply).
 *
 * The OFT lock-and-mint pattern means secondary chains start with 0 supply.
 * Bridging MAG from Polygon to chain X via LayerZero burns/locks on Polygon
 * and mints the equivalent on X.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployMAGOnSecondaryChain.ts --network base
 *
 * Reuses the existing `MagnetaOFTStandardFactory` already deployed on every
 * Magneta chain (see deployments/{net}.json → contracts.MagnetaOFTStandardFactory).
 *
 * After running on each of the 17 chains: run scripts/deploy/generateMAGPeerWiringBatches.ts
 * to produce Safe batches that wire `setPeer` between every (Polygon, X) pair
 * AND every (X, Y) pair so users can bridge directly between any two chains.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

// 0 supply — canonical Polygon MAG holds the entire 1B; secondaries mint
// only what gets bridged in.
const SECONDARY_SUPPLY = 0n;

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

  if (chainId === 137) {
    throw new Error("Polygon is the canonical MAG chain — use deployMAGToken.ts there, not this script.");
  }

  const depPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  if (!fs.existsSync(depPath)) throw new Error(`No deployment file for ${network.name}`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  const factoryAddr: string | undefined = dep?.contracts?.MagnetaOFTStandardFactory;
  if (!factoryAddr) {
    throw new Error(`MagnetaOFTStandardFactory not deployed on ${network.name}. Run Sprint 9.6 deploy first.`);
  }

  console.log(`\nDeployer       : ${deployer.address}`);
  console.log(`Network        : ${network.name} (${chainId})`);
  console.log(`Balance        : ${ethers.formatEther(balance)} native`);
  console.log(`Factory        : ${factoryAddr}`);
  console.log(`Initial supply : 0 (secondary chain — supply mints on bridge-in)\n`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  const factory = new ethers.Contract(factoryAddr, FACTORY_ABI, deployer);
  const fee: bigint = await factory.createFee();
  console.log(`createFee      : ${ethers.formatEther(fee)} native`);

  console.log("\nSubmitting createOFTStandardToken (0 supply)…");
  const tx = await factory.createOFTStandardToken(
    "Magneta",
    "MAG",
    "ipfs://magneta-token-metadata.json",
    SECONDARY_SUPPLY,
    false,
    false,
    false,
    { value: fee },
  );
  console.log(`  tx: ${tx.hash}`);
  const receipt = await tx.wait();

  let mag: string | undefined;
  for (const log of receipt.logs ?? []) {
    if (log.address.toLowerCase() === factoryAddr.toLowerCase() && log.topics?.length >= 3) {
      mag = "0x" + log.topics[1]!.slice(-40);
      break;
    }
  }
  if (!mag) throw new Error("Couldn't decode TokenCreated event — check the tx on the explorer");
  console.log(`\nMAG (${network.name}): ${mag}`);

  // Persist into the chain's deployment file so generateMAGPeerWiringBatches
  // can read it without operator gymnastics.
  dep.contracts = { ...(dep.contracts ?? {}), MAG: mag };
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`Saved to ${depPath}\n`);

  console.log("══════════════════════════════════════════════════");
  console.log("NEXT STEPS:");
  console.log("══════════════════════════════════════════════════");
  console.log(`1. Repeat this script on the 16 other secondary chains.`);
  console.log(`2. Run scripts/deploy/generateMAGPeerWiringBatches.ts`);
  console.log(`3. Execute each chain's Safe batch in the Tx Builder.`);
  console.log(`4. Update lib/constants/magnetaToken.ts with the new addresses.\n`);
}

main().catch((e) => { console.error(e); process.exit(1); });
