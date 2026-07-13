/**
 * Deploy MagnetaTokenFactory on the current network.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy-token-factory.ts --network arbitrum
 *
 * Constructor arg: _treasury (FeeVault address on that chain).
 * After deploy, the script writes deployments/<network>-factory.json and
 * prints the verify command.
 */
import { ethers, network, run } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const TREASURY_BY_CHAIN: Record<number, string> = {
  42161: "0x68109132Ecf7540A0A983e1Aaa7DebC469d9d68b", // Arbitrum FeeVault
  8453:  "0x68109132Ecf7540A0A983e1Aaa7DebC469d9d68b",
  137:   "0x68109132Ecf7540A0A983e1Aaa7DebC469d9d68b",
  25:    "0x68109132Ecf7540A0A983e1Aaa7DebC469d9d68b", // Cronos FeeVault (Sprint D #2 prereq)
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const treasury = TREASURY_BY_CHAIN[chainId];
  if (!treasury) throw new Error(`No treasury configured for chainId ${chainId}`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Network  : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer : ${deployer.address}`);
  console.log(`Balance  : ${ethers.formatEther(balance)} native`);
  console.log(`Treasury : ${treasury}`);
  console.log("");

  console.log("Deploying MagnetaTokenFactory...");
  const Factory = await ethers.getContractFactory("MagnetaTokenFactory");
  const factory = await Factory.deploy(treasury);
  await factory.waitForDeployment();
  const address = await factory.getAddress();

  const deployTx = factory.deploymentTransaction();
  const receipt = deployTx ? await deployTx.wait() : null;
  const gasUsed = receipt?.gasUsed ?? 0n;
  const gasPrice = receipt?.gasPrice ?? deployTx?.gasPrice ?? 0n;
  const gasCost = gasUsed * gasPrice;

  console.log(`\n✅ MagnetaTokenFactory deployed at: ${address}`);
  console.log(`   Gas used : ${gasUsed}`);
  console.log(`   Gas cost : ${ethers.formatEther(gasCost)} native`);

  const outDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${network.name}-factory.json`);
  fs.writeFileSync(
    outFile,
    JSON.stringify(
      {
        network: network.name,
        chainId: chainId.toString(),
        contract: "MagnetaTokenFactory",
        address,
        treasury,
        deployer: deployer.address,
        deployedAt: new Date().toISOString(),
        txHash: deployTx?.hash,
      },
      null,
      2,
    ),
  );
  console.log(`\n📄 Deployment saved to: ${outFile}`);

  console.log(`\n⏳ Verifying on block explorer (60s wait for indexing)...`);
  await new Promise((r) => setTimeout(r, 60000));
  try {
    await run("verify:verify", { address, constructorArguments: [treasury] });
    console.log("✅ Verified.");
  } catch (e: any) {
    if (e?.message?.toLowerCase().includes("already verified")) {
      console.log("✅ Already verified.");
    } else {
      console.warn("⚠️  Verify failed — run manually:");
      console.warn(`   pnpm hardhat verify --network ${network.name} ${address} ${treasury}`);
      console.warn(`   ${e?.message ?? e}`);
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
