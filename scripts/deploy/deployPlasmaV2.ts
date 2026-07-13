/**
 * One-off: deploy our own UniV2 fork on Plasma (chainId 9745).
 * Plasma has no audited V2 DEX, so we deploy the stack ourselves:
 *   1. WETH9          (wraps native XPL for the router) → becomes WXPL
 *   2. UniswapV2Factory (npm @uniswap/v2-core, unchanged)
 *   3. MagnetaV2Router02 (vendored fork with patched init code hash)
 *
 * Outputs JSON to deployments/plasma-v2.json so deployAll.ts / chainConfig
 * can pick up the addresses for the 11 Magneta contracts.
 *
 * Usage: npx hardhat run scripts/deploy/deployPlasmaV2.ts --network plasma
 */
import { ethers, network } from "hardhat";
import fs from "fs";
import path from "path";

async function main() {
    const [deployer] = await ethers.getSigners();
    const balance = await ethers.provider.getBalance(deployer.address);
    console.log(`Network : ${network.name} (chainId ${network.config.chainId})`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Balance : ${ethers.formatEther(balance)} native\n`);

    // 1. WETH9 — the router expects a wrapped-native contract.
    //    On Plasma the native token is XPL → this contract is effectively WXPL.
    console.log("Deploying WETH9 (WXPL on Plasma)...");
    const WETH9 = await ethers.getContractFactory("WETH9");
    const weth9 = await WETH9.deploy();
    await weth9.waitForDeployment();
    const wethAddr = await weth9.getAddress();
    console.log(`  WETH9 : ${wethAddr}`);

    // 2. UniswapV2Factory — feeToSetter = deployer (we can transfer later).
    console.log("\nDeploying UniswapV2Factory...");
    const Factory = await ethers.getContractFactory("UniswapV2Factory");
    const factory = await Factory.deploy(deployer.address);
    await factory.waitForDeployment();
    const factoryAddr = await factory.getAddress();
    console.log(`  Factory: ${factoryAddr}`);
    console.log(`  feeToSetter: ${await factory.feeToSetter()}`);

    // 3. MagnetaV2Router02 — vendored fork of UniswapV2Router02 using our
    //    MagnetaV2Library (patched init code hash matching our compiled Pair).
    console.log("\nDeploying MagnetaV2Router02...");
    const Router = await ethers.getContractFactory("MagnetaV2Router02");
    const router = await Router.deploy(factoryAddr, wethAddr);
    await router.waitForDeployment();
    const routerAddr = await router.getAddress();
    console.log(`  Router : ${routerAddr}`);
    console.log(`  factory() = ${await router.factory()}`);
    console.log(`  WETH()    = ${await router.WETH()}`);

    const out = {
        network: network.name,
        chainId: Number(network.config.chainId),
        deployer: deployer.address,
        weth9: wethAddr,
        factory: factoryAddr,
        router: routerAddr,
        pairInitCodeHash:
            "0xf40783a955a9be9bf11de05e90244c2b6394edc5f348e5dcd168dba8661a95d2",
        deployedAt: new Date().toISOString(),
    };
    const outDir = path.join(__dirname, "..", "..", "deployments");
    if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
    const outPath = path.join(outDir, `${network.name}-v2.json`);
    fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
    console.log(`\nWrote ${outPath}`);

    const finalBal = await ethers.provider.getBalance(deployer.address);
    console.log(`\nGas used: ${ethers.formatEther(balance - finalBal)} native`);
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
