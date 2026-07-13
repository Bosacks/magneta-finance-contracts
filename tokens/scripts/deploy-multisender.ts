import { ethers } from "hardhat";
import { FEE_VAULT } from "./chainConfig";

async function main() {
    const [deployer] = await ethers.getSigners();

    // Multisend fees accumulate in the contract and are swept to this address
    // via withdrawFees(). Defaults to the canonical Magneta FeeVault; override
    // with FEE_RECIPIENT env (e.g. a testnet vault). Zero address would make
    // withdrawFees() fall back to owner() — only use intentionally.
    const feeRecipient = process.env.FEE_RECIPIENT || FEE_VAULT;

    console.log("Deploying Multisender with the account:", deployer.address);
    console.log("Fee recipient (FeeVault):", feeRecipient);

    const Multisender = await ethers.getContractFactory("Multisender");
    const multisender = await Multisender.deploy(feeRecipient);

    await multisender.waitForDeployment();

    const address = await multisender.getAddress();

    console.log("Multisender deployed to:", address);

    // Set default fee (0.00005 ETH = 50000000000000 Wei)
    // const fee = ethers.parseEther("0.00005");
    // await multisender.setFeePerRecipient(fee);
    // console.log("Fee set to:", ethers.formatEther(fee), "ETH");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
