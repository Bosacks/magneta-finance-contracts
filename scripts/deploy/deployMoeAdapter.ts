/**
 * One-off: deploy MoeRouterAdapter on Mantle so our UniV2-based Magneta modules
 * can use Merchant Moe V1 (which renames ETH→Native and WETH→wNative).
 * Usage: npx hardhat run scripts/deploy/deployMoeAdapter.ts --network mantle
 */
import { ethers, network } from "hardhat";

const MOE_ROUTER = "0xeaEE7EE68874218c3558b40063c42B82D3E7232a";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log(`Network : ${network.name}`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Balance : ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} native`);
    console.log(`Moe     : ${MOE_ROUTER}\n`);

    const Adapter = await ethers.getContractFactory("MoeRouterAdapter");
    const adapter = await Adapter.deploy(MOE_ROUTER);
    await adapter.waitForDeployment();
    const addr = await adapter.getAddress();

    console.log(`MoeRouterAdapter: ${addr}`);
    console.log(`  factory: ${await adapter.factory()}`);
    console.log(`  WETH (wNative): ${await adapter.WETH()}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
