const hre = require("hardhat");

const FAUCET_BASE_SEPOLIA = "0xC592a71BFafAa2F99122cb238ecba570daDf3810";
const FAUCET_OP_SEPOLIA = "0xC1972f874cFa122CF7DaEa9566b4eDa54B21DAEF";

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    const network = hre.network.name;

    console.log(`Checking balances on ${network}...`);
    console.log(`Deployer: ${deployer.address}`);

    const balance = await hre.ethers.provider.getBalance(deployer.address);
    console.log(`Deployer Balance: ${hre.ethers.formatEther(balance)} ETH`);

    let faucetAddress;
    if (network === "baseSepolia") {
        faucetAddress = FAUCET_BASE_SEPOLIA;
    } else if (network === "optimismSepolia") {
        faucetAddress = FAUCET_OP_SEPOLIA;
    }

    if (faucetAddress) {
        const faucetBalance = await hre.ethers.provider.getBalance(faucetAddress);
        console.log(`Faucet Contract (${faucetAddress}) Balance: ${hre.ethers.formatEther(faucetBalance)} ETH`);
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
