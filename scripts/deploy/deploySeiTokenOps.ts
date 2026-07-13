/**
 * One-off: deploy TokenOpsModule on Sei to recover from the rate-limit crash
 * during the main deployAll run, then write the deployments/sei.json checkpoint
 * so configureOnly.ts can resume.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG, FEE_VAULT, PAUSE_GUARDIAN } from "./chainConfig";

const ALREADY_DEPLOYED = {
    MagnetaPool:        "0xBeb7bB26Efe2c9c8571c83590625d5249755ad27",
    MagnetaSwap:        "0x3f5BF77ba60949c4C5B9653159b0A050593B04a8",
    MagnetaLending:     "0x3c21016E57e7A29333f38d200EC8945bfc6BA537",
    MagnetaFactory:     "0xB4f06F01641eFFb376Cc5dcA90F81fed1C6FA76e",
    MagnetaBundler:     "0xe3162944b9D759c23B7D1d99A25075a4313db19c",
    MagnetaGateway:     "0xDe1752E266C3978240014DFc616dd34EbF9cDF31",
    MagnetaBridgeOApp:  "0x9F9A3DC819e5229b63b504d7A0FDE93FA436919E",
    LPModule:           "0xB38e7427D81f755c65AC6bfc865Bfe9918BA7a9b",
    SwapModule:         "0x134855A6702c0AF9FBF1b8F4bB576Bef651eF895",
    TaxClaimModule:     "0x3cA761aa595e6bA0d89f35e9f0af06906b437258",
};

async function main() {
    const [deployer] = await ethers.getSigners();
    const net = await ethers.provider.getNetwork();
    const chainId = Number(net.chainId);
    const cfg = CHAIN_CONFIG[chainId];
    if (!cfg) throw new Error(`No CHAIN_CONFIG for chainId ${chainId}`);

    console.log(`Network : ${network.name} (chainId ${chainId})`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Balance : ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} native\n`);

    const TokenOpsMod = await ethers.getContractFactory("TokenOpsModule");
    const tom = await TokenOpsMod.deploy(ALREADY_DEPLOYED.MagnetaGateway, cfg.usdc!);
    await tom.waitForDeployment();
    const tomAddr = await tom.getAddress();
    console.log(`TokenOpsModule: ${tomAddr}\n`);

    const checkpoint = {
        network: network.name,
        chainId: chainId.toString(),
        deployer: deployer.address,
        feeVault: FEE_VAULT,
        pauseGuardian: PAUSE_GUARDIAN,
        timestamp: new Date().toISOString(),
        chainConfig: cfg,
        contracts: { ...ALREADY_DEPLOYED, TokenOpsModule: tomAddr },
    };
    const outPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(checkpoint, null, 2) + "\n");
    console.log(`Checkpoint written: ${outPath}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
