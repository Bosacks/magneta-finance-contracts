const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
    console.log("🚀 Déploiement du contrat ERC20Token...\n");

    // Get the signer
    const [deployer] = await ethers.getSigners();
    console.log("📋 Deployer address:", deployer.address);
    console.log("💰 Deployer balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // Get the contract factory
    const ERC20Token = await ethers.getContractFactory("ERC20Token");

    // Deploy with test parameters
    // Modify these values as needed
    const tokenName = "Test Token";
    const tokenSymbol = "TEST";
    const tokenURI = "https://example.com/metadata.json"; // Replace with actual metadata URI
    const totalSupply = ethers.parseUnits("1000000", 18); // 1 million tokens with 18 decimals
    const revokeUpdate = false;
    const revokeFreeze = false;
    const revokeMint = false;

    console.log("📝 Token Configuration:");
    console.log("   Name:", tokenName);
    console.log("   Symbol:", tokenSymbol);
    console.log("   Total Supply:", ethers.formatUnits(totalSupply, 18));
    console.log("   Revoke Update:", revokeUpdate);
    console.log("   Revoke Freeze:", revokeFreeze);
    console.log("   Revoke Mint:", revokeMint);
    console.log("");

    // Deploy
    console.log("⏳ Deploying...");
    const token = await ERC20Token.deploy(
        tokenName,
        tokenSymbol,
        tokenURI,
        totalSupply,
        deployer.address,
        revokeUpdate,
        revokeFreeze,
        revokeMint
    );

    await token.waitForDeployment();
    const address = await token.getAddress();

    console.log("\n✅ ERC20Token deployed at:", address);

    // Get network info
    const network = await ethers.provider.getNetwork();
    let networkName = "unknown";
    let explorerBase = "";

    switch (Number(network.chainId)) {
        case 84532:
            networkName = "baseSepolia";
            explorerBase = "https://sepolia.basescan.org";
            break;
        case 8453:
            networkName = "base";
            explorerBase = "https://basescan.org";
            break;
        case 11155420:
            networkName = "optimismSepolia";
            explorerBase = "https://sepolia-optimism.etherscan.io";
            break;
        case 421614:
            networkName = "arbitrumSepolia";
            explorerBase = "https://sepolia.arbiscan.io";
            break;
        case 80002:
            networkName = "polygonAmoy";
            explorerBase = "https://amoy.polygonscan.com";
            break;
        case 42161:
            networkName = "arbitrum";
            explorerBase = "https://arbiscan.io";
            break;
        case 137:
            networkName = "polygon";
            explorerBase = "https://polygonscan.com";
            break;
        default:
            networkName = "unknown";
            explorerBase = "https://etherscan.io";
    }

    // Save deployment info
    const artifactsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(artifactsDir)) {
        fs.mkdirSync(artifactsDir, { recursive: true });
    }

    const deploymentInfo = {
        contractAddress: address,
        deployer: deployer.address,
        network: networkName,
        chainId: network.chainId.toString(),
        tokenName,
        tokenSymbol,
        totalSupply: totalSupply.toString(),
        revokeUpdate,
        revokeFreeze,
        revokeMint,
        deployedAt: new Date().toISOString(),
    };

    const deploymentFile = path.join(artifactsDir, `${networkName}-deployment.json`);
    fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
    console.log("\n📄 Deployment info saved to:", deploymentFile);

    // Explorer link
    console.log("\n🔗 View on Explorer:", `${explorerBase}/address/${address}`);

    // Verify instructions
    console.log("\n📋 To verify the contract, run:");
    console.log(`npx hardhat verify --network ${networkName} ${address} "${tokenName}" "${tokenSymbol}" "${tokenURI}" "${totalSupply}" "${deployer.address}" ${revokeUpdate} ${revokeFreeze} ${revokeMint}`);

    return address;
}

main()
    .then((address) => {
        console.log("\n🎉 Deployment complete!");
        process.exit(0);
    })
    .catch((error) => {
        console.error("\n❌ Deployment failed:", error);
        process.exit(1);
    });
