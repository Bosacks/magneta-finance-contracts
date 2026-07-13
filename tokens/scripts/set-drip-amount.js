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

    const currentDrip = await faucet.dripAmount();
    console.log(`Current Drip Amount: ${ethers.formatEther(currentDrip)} ETH`);

    const newDripAmount = ethers.parseEther("0.0001");

    if (currentDrip === newDripAmount) {
        console.log("Drip amount is already set to 0.0001 ETH");
        return;
    }

    console.log(`Setting drip amount to 0.0001 ETH...`);
    const tx = await faucet.setDripAmount(newDripAmount);
    console.log(`Transaction sent: ${tx.hash}`);
    await tx.wait();
    console.log("Transaction confirmed!");

    const updatedDrip = await faucet.dripAmount();
    console.log(`Updated Drip Amount: ${ethers.formatEther(updatedDrip)} ETH`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
