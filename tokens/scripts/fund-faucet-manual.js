const hre = require("hardhat");

const FAUCET_BASE_SEPOLIA = "0xC592a71BFafAa2F99122cb238ecba570daDf3810";
const FAUCET_OP_SEPOLIA = "0xC1972f874cFa122CF7DaEa9566b4eDa54B21DAEF";

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    const network = hre.network.name;

    let faucetAddress;
    let amount = "0.0001"; // Default very small amount to be safe

    if (network === "baseSepolia") {
        faucetAddress = FAUCET_BASE_SEPOLIA;
        amount = "0.1"; // We have funds here
    } else if (network === "optimismSepolia") {
        faucetAddress = FAUCET_OP_SEPOLIA;
        amount = "0.001"; // Low balance
    }

    if (!faucetAddress) {
        console.log("No faucet address for this network");
        return;
    }

    console.log(`Funding faucet at ${faucetAddress} with ${amount} ETH on ${network}...`);

    // Check balance again to be sure
    const balance = await hre.ethers.provider.getBalance(deployer.address);
    if (balance < hre.ethers.parseEther(amount) + hre.ethers.parseEther("0.001")) { // + gas buffer
        console.log("Insufficient funds to fund faucet. Skipping.");
        return;
    }

    const tx = await deployer.sendTransaction({
        to: faucetAddress,
        value: hre.ethers.parseEther(amount)
    });

    console.log(`Transaction sent: ${tx.hash}`);
    await tx.wait();
    console.log("Transaction confirmed!");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
