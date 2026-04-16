/**
 * Full testnet deployment of the Magneta DeFi stack.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy-testnet.ts --network arbitrumSepolia
 *   pnpm hardhat run scripts/deploy-testnet.ts --network baseSepolia
 *
 * Writes the result to deployments/<network>.json.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

interface DeployResult {
  network: string;
  chainId: string;
  deployer: string;
  admin: string;
  timestamp: string;
  contracts: Record<string, string>;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  const net = await ethers.provider.getNetwork();

  console.log(`\nDeployer : ${deployer.address}`);
  console.log(`Network  : ${network.name} (chainId ${net.chainId})`);
  console.log(`Balance  : ${ethers.formatEther(balance)} ETH\n`);

  if (balance === 0n) {
    throw new Error("Deployer has 0 balance — fund it first");
  }

  const contracts: Record<string, string> = {};

  // ── 1. MagnetaPool ────────────────────────────────────────
  console.log("1/9  Deploying MagnetaPool...");
  const Pool = await ethers.getContractFactory("MagnetaPool");
  const pool = await Pool.deploy(deployer.address);
  await pool.waitForDeployment();
  contracts.MagnetaPool = await pool.getAddress();
  console.log(`     MagnetaPool: ${contracts.MagnetaPool}`);

  // ── 2. MagnetaSwap ────────────────────────────────────────
  console.log("2/9  Deploying MagnetaSwap...");
  const Swap = await ethers.getContractFactory("MagnetaSwap");
  const swap = await Swap.deploy(deployer.address, contracts.MagnetaPool);
  await swap.waitForDeployment();
  contracts.MagnetaSwap = await swap.getAddress();
  console.log(`     MagnetaSwap: ${contracts.MagnetaSwap}`);

  // ── 3. RewardToken (MockERC20) ────────────────────────────
  console.log("3/9  Deploying RewardToken...");
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const rewardToken = await MockERC20.deploy(
    "Magneta Reward Token",
    "MRT",
    18,
    ethers.parseEther("10000000"),
  );
  await rewardToken.waitForDeployment();
  contracts.RewardToken = await rewardToken.getAddress();
  console.log(`     RewardToken: ${contracts.RewardToken}`);

  // ── 4. MagnetaFarm ────────────────────────────────────────
  console.log("4/9  Deploying MagnetaFarm...");
  const currentBlock = await ethers.provider.getBlockNumber();
  const Farm = await ethers.getContractFactory("MagnetaFarm");
  const farm = await Farm.deploy(
    deployer.address,
    contracts.RewardToken,
    ethers.parseEther("1"), // 1 token per block
    currentBlock + 10,
  );
  await farm.waitForDeployment();
  contracts.MagnetaFarm = await farm.getAddress();
  console.log(`     MagnetaFarm: ${contracts.MagnetaFarm}`);

  // ── 5. MagnetaLending ─────────────────────────────────────
  console.log("5/9  Deploying MagnetaLending...");
  const Lending = await ethers.getContractFactory("MagnetaLending");
  const lending = await Lending.deploy();
  await lending.waitForDeployment();
  contracts.MagnetaLending = await lending.getAddress();
  console.log(`     MagnetaLending: ${contracts.MagnetaLending}`);

  // ── 6. MockTokenX + MockTokenY ────────────────────────────
  console.log("6/9  Deploying MockTokenX...");
  const tokenX = await MockERC20.deploy(
    "Mock Token X",
    "MTX",
    18,
    ethers.parseEther("10000000"),
  );
  await tokenX.waitForDeployment();
  contracts.MockTokenX = await tokenX.getAddress();
  console.log(`     MockTokenX: ${contracts.MockTokenX}`);

  console.log("     Deploying MockTokenY...");
  const tokenY = await MockERC20.deploy(
    "Mock Token Y",
    "MTY",
    18,
    ethers.parseEther("10000000"),
  );
  await tokenY.waitForDeployment();
  contracts.MockTokenY = await tokenY.getAddress();
  console.log(`     MockTokenY: ${contracts.MockTokenY}`);

  // ── 7. MagnetaDLMM ───────────────────────────────────────
  console.log("7/9  Deploying MagnetaDLMM...");
  const DLMM = await ethers.getContractFactory("MagnetaDLMM");
  const dlmm = await DLMM.deploy(
    contracts.MockTokenX,
    contracts.MockTokenY,
    10,       // binStep = 10 (0.1%)
    25,       // lpFeeBps = 0.25%
    5,        // protocolFeeBps = 0.05%
    8388608,  // initialActiveId (2^23 = center bin)
    deployer.address,
    deployer.address, // feeRecipient
  );
  await dlmm.waitForDeployment();
  contracts.MagnetaDLMM = await dlmm.getAddress();
  console.log(`     MagnetaDLMM: ${contracts.MagnetaDLMM}`);

  // ── 8. MagnetaFactory ─────────────────────────────────────
  console.log("8/9  Deploying MagnetaFactory...");
  const Factory = await ethers.getContractFactory("MagnetaFactory");
  const factory = await Factory.deploy(
    contracts.MagnetaPool,
    deployer.address,
  );
  await factory.waitForDeployment();
  contracts.MagnetaFactory = await factory.getAddress();
  console.log(`     MagnetaFactory: ${contracts.MagnetaFactory}`);

  // ── 9. MagnetaBundler ─────────────────────────────────────
  console.log("9/9  Deploying MagnetaBundler...");
  const Bundler = await ethers.getContractFactory("MagnetaBundler");
  const bundler = await Bundler.deploy(contracts.MagnetaSwap);
  await bundler.waitForDeployment();
  contracts.MagnetaBundler = await bundler.getAddress();
  console.log(`     MagnetaBundler: ${contracts.MagnetaBundler}`);

  // ── Write deployment JSON ─────────────────────────────────
  const result: DeployResult = {
    network: network.name,
    chainId: net.chainId.toString(),
    deployer: deployer.address,
    admin: deployer.address,
    timestamp: new Date().toISOString(),
    contracts,
  };

  const outPath = path.join(__dirname, "..", "deployments", `${network.name}.json`);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n");

  console.log(`\nDeployment saved to ${outPath}`);
  console.log("\nAll contracts:");
  for (const [name, addr] of Object.entries(contracts)) {
    console.log(`  ${name}: ${addr}`);
  }

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`\nGas spent: ${ethers.formatEther(spent)} ETH`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
