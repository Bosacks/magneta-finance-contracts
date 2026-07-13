const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
    console.log("🚀 Déploiement de MagnetaTokenFactory...\n");

    const [deployer] = await ethers.getSigners();
    console.log("📋 Deployer address:", deployer.address);
    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("💰 Deployer balance:", ethers.formatEther(balance), "ETH\n");

    // Network-specific treasury addresses
    const network = await ethers.provider.getNetwork();
    const chainId = Number(network.chainId);

    let treasuryAddress;
    if (chainId === 84532) { // Base Sepolia
        treasuryAddress = ethers.getAddress("0x987258079d90635293a17defd9db3a61626f8c3b");
    } else if (chainId === 8453) { // Base Mainnet
        treasuryAddress = ethers.getAddress("0x3708ce94d50fe61113acbfbede05265a5ac74d24");
    } else {
        // Fallback to deployer for local testing
        treasuryAddress = deployer.address;
        console.log("⚠️ Unknown network, using deployer as treasury");
    }

    console.log("🏛️ Treasury Address:", treasuryAddress);

    const MagnetaTokenFactory = await ethers.getContractFactory("MagnetaTokenFactory");

    console.log("⏳ Deploying Factory...");
    const factory = await MagnetaTokenFactory.deploy(treasuryAddress);

    await factory.waitForDeployment();
    const address = await factory.getAddress();

    console.log("\n✅ MagnetaTokenFactory deployed at:", address);

    // Save deployment info
    const networkName = chainId === 84532 ? "baseSepolia" :
        chainId === 8453 ? "base" : "localhost";

    const deploymentsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
    }

    const deploymentInfo = {
        factoryAddress: address,
        treasury: treasuryAddress,
        deployer: deployer.address,
        network: networkName,
        chainId: chainId.toString(),
        deployedAt: new Date().toISOString(),
    };

    const deploymentFile = path.join(deploymentsDir, `${networkName}-factory.json`);
    fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
    console.log("\n📄 Deployment info saved to:", deploymentFile);

    // Verify instructions
    console.log("\n📋 To verify the factory, run:");
    console.log(`npx hardhat verify --network ${networkName} ${address} "${treasuryAddress}"`);

    return address;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
