/**
 * One-off: deploy UbeswapCeloAdapter on Celo so our UniV2-based Magneta modules
 * work with Ubeswap (which has no WETH()/addLiquidityETH — CELO is itself an
 * ERC20 at the GoldToken precompile 0x471EcE3750Da237f93B8E339c536989b8978a438).
 * Usage: npx hardhat run scripts/deploy/deployUbeswapCeloAdapter.ts --network celo
 */
import { ethers, network } from "hardhat";

const UBESWAP_ROUTER = "0xE3D8bd6Aed4F159bc8000a9cD47CffDb95F96121";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log(`Network : ${network.name}`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Balance : ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} native`);
    console.log(`Ubeswap : ${UBESWAP_ROUTER}\n`);

    const Adapter = await ethers.getContractFactory("UbeswapCeloAdapter");
    const adapter = await Adapter.deploy(UBESWAP_ROUTER);
    await adapter.waitForDeployment();
    const addr = await adapter.getAddress();

    console.log(`UbeswapCeloAdapter: ${addr}`);
    console.log(`  factory: ${await adapter.factory()}`);
    console.log(`  WETH (CELO precompile): ${await adapter.WETH()}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
