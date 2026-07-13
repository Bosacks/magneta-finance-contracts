/**
 * One-off: deploy DragonSwapSeiAdapter on Sei so our UniV2-based Magneta modules
 * can use DragonSwap V1 (which renames ETH→SEI and WETH→WSEI).
 * Usage: npx hardhat run scripts/deploy/deployDragonSwapSeiAdapter.ts --network sei
 */
import { ethers, network } from "hardhat";

const DRAGON_ROUTER = "0x11DA6463D6Cb5a03411Dbf5ab6f6bc3997Ac7428";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log(`Network : ${network.name}`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Balance : ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} native`);
    console.log(`Dragon  : ${DRAGON_ROUTER}\n`);

    const Adapter = await ethers.getContractFactory("DragonSwapSeiAdapter");
    const adapter = await Adapter.deploy(DRAGON_ROUTER);
    await adapter.waitForDeployment();
    const addr = await adapter.getAddress();

    console.log(`DragonSwapSeiAdapter: ${addr}`);
    console.log(`  factory: ${await adapter.factory()}`);
    console.log(`  WETH (WSEI): ${await adapter.WETH()}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
