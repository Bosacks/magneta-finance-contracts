/**
 * Whitelist a set of tokens on the chain's MagnetaSwap so LPModule's
 * `_createLPFromBridgedUsdc` can route USDC → token + USDC → WETH through
 * it. Tokens not on the whitelist make MagnetaSwap.swap revert with
 * "MagnetaSwap: token not whitelisted", which then aborts fulfillValueOp
 * on the destination chain and leaves the bridged USDC parked.
 *
 * Reads MagnetaSwap address from deployments/<network>.json. The list of
 * tokens is hard-wired per chain (USDC + WETH + the test memecoin); add
 * to it as new tokens get cross-chain-LP'd.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/whitelistMagnetaSwapTokens.ts --network base
 *   pnpm hardhat run scripts/deploy/whitelistMagnetaSwapTokens.ts --network polygon
 *
 * Owner-only — must be run from the deployer wallet.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG } from "./chainConfig";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

// Tokens to whitelist per chain (USDC, WETH, plus any tokens already
// tested cross-chain).
const TOKENS_TO_WHITELIST: Record<number, string[]> = {
  137: [
    "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", // USDC Polygon
    "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270", // WMATIC
  ],
  8453: [
    "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", // USDC Base
    "0x4200000000000000000000000000000000000006", // WETH Base
    "0x878aA594a574DA6F57b4b72456ab4a04946D7229", // TMC test memecoin
  ],
};

async function main() {
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const tokens = TOKENS_TO_WHITELIST[chainId];
  if (!tokens || tokens.length === 0) {
    throw new Error(`No tokens to whitelist for chainId ${chainId}`);
  }

  const deployPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  if (!fs.existsSync(deployPath)) {
    throw new Error(`No deployment at ${deployPath}`);
  }
  const deployment = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const swapAddr = deployment.contracts.MagnetaSwap;
  if (!swapAddr) throw new Error(`MagnetaSwap not found in ${deployPath}`);

  console.log(`\n── Whitelist tokens on MagnetaSwap ${swapAddr} (${network.name}) ──`);
  console.log(`   signer: ${signer.address}`);
  console.log(`   tokens: ${tokens.length}`);

  const swap = await ethers.getContractAt("MagnetaSwap", swapAddr);
  const owner = await swap.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(
      `Signer is not the MagnetaSwap owner. Owner: ${owner}; signer: ${signer.address}. ` +
      `If the owner is the Safe, generate a Safe batch instead.`
    );
  }

  // Skip tokens that are already whitelisted.
  const toFlip: string[] = [];
  for (const t of tokens) {
    const isWl = await swap.whitelistedTokens(t);
    if (isWl) {
      console.log(`   ✓ ${t} already whitelisted (skip)`);
    } else {
      toFlip.push(t);
    }
  }

  if (toFlip.length === 0) {
    console.log(`\n── DONE — nothing to do ──`);
    return;
  }

  console.log(`\n── whitelistTokenBatch(${toFlip.length}, true) ──`);
  const tx = await swap.whitelistTokenBatch(toFlip, true);
  const receipt = await tx.wait();
  console.log(`   ✓ tx ${tx.hash} (block ${receipt.blockNumber}, gasUsed ${receipt.gasUsed})`);

  for (const t of toFlip) {
    const isWl = await swap.whitelistedTokens(t);
    console.log(`   ${isWl ? "✓" : "✗"} ${t}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
