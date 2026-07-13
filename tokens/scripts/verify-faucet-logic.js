const hre = require("hardhat");
const { ethers } = require("hardhat");

const FAUCET_BASE_SEPOLIA = "0xC592a71BFafAa2F99122cb238ecba570daDf3810";
const FAUCET_OP_SEPOLIA = "0xC1972f874cFa122CF7DaEa9566b4eDa54B21DAEF";

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    const network = hre.network.name;

    let faucetAddress;
    if (network === "baseSepolia") {
        faucetAddress = FAUCET_BASE_SEPOLIA;
    } else if (network === "optimismSepolia") {
        faucetAddress = FAUCET_OP_SEPOLIA;
    }

    if (!faucetAddress) {
        console.log("No faucet address for this network");
        return;
    }

    const Faucet = await ethers.getContractFactory("Faucet");
    const faucet = Faucet.attach(faucetAddress);

    const dripAmount = await faucet.dripAmount();
    console.log(`Drip Amount: ${ethers.formatEther(dripAmount)} ETH`);

    // Create a random wallet to receive funds
    const recipient = ethers.Wallet.createRandom();
    const recipientAddress = recipient.address;
    console.log(`Testing dripTo for recipient: ${recipientAddress}`);

    console.log("Sending drip...");
    try {
        const tx = await faucet.dripTo(recipientAddress);
        console.log(`Transaction sent: ${tx.hash}`);
        await tx.wait();
        console.log("Transaction confirmed!");

        const balance = await ethers.provider.getBalance(recipientAddress);
        console.log(`Recipient Balance: ${ethers.formatEther(balance)} ETH`);

        if (balance === dripAmount) {
            console.log("SUCCESS: Recipient received exact drip amount.");
        } else {
            console.error("FAILURE: Recipient balance mismatch.");
        }
    } catch (error) {
        console.error("Error during drip:", error);
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
