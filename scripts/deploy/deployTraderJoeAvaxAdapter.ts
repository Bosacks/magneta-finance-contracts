/**
 * One-off: deploy TraderJoeAvaxAdapter on Avalanche so our UniV2-based Magneta modules
 * can use TraderJoe V1 (which renames ETH→AVAX and WETH→WAVAX).
 * Usage: npx hardhat run scripts/deploy/deployTraderJoeAvaxAdapter.ts --network avalanche
 */
import { ethers, network } from "hardhat";

const JOE_ROUTER = "0x60aE616a2155Ee3d9A68541Ba4544862310933d4";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log(`Network : ${network.name}`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Balance : ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} native`);
    console.log(`Joe     : ${JOE_ROUTER}\n`);

    const Adapter = await ethers.getContractFactory("TraderJoeAvaxAdapter");
    const adapter = await Adapter.deploy(JOE_ROUTER);
    await adapter.waitForDeployment();
    const addr = await adapter.getAddress();

    console.log(`TraderJoeAvaxAdapter: ${addr}`);
    console.log(`  factory: ${await adapter.factory()}`);
    console.log(`  WETH (WAVAX): ${await adapter.WETH()}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
