import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Chainlink native/USD price-feed addresses per chain.
 * Used by MagnetaETFFactory to convert the $2 000 creation fee to native tokens.
 */
const PRICE_FEEDS: Record<number, string> = {
    // Mainnets
    1:      "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419", // ETH/USD  — Ethereum
    8453:   "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70", // ETH/USD  — Base
    42161:  "0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612", // ETH/USD  — Arbitrum
    10:     "0x13e3Ee699D1909E989722E753853AE30b17e08c5", // ETH/USD  — Optimism
    137:    "0xAB594600376Ec9fD91F8e8dC009b80F2c2D7E3E4", // MATIC/USD — Polygon
    56:     "0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE", // BNB/USD  — BSC
    43114:  "0x0A77230d17318075983913bC2145DB16C7366156", // AVAX/USD — Avalanche
    59144:  "0x3c6Cd9Cc7c7a4c2Cf5a82734CD249D7D593354dA", // ETH/USD  — Linea
    5000:   "0xB8B41D87C930C7b6BF5e0e4A0fBe835B17286218", // MNT/USD  — Mantle (if available)
    42220:  "0x022F9dCC73C5Fb43F2b4eF8b5989B1Ce15dCf65e", // CELO/USD — Celo

    // Testnets
    84532:  "0x4aDC67d868Ec8285EAA43b19e27Bde93280e3b76", // ETH/USD  — Base Sepolia
    11155420: "0x61Ec26aA57019C486B10502285c5A3D4A4750AD7", // ETH/USD — OP Sepolia
};

/**
 * Treasury addresses per chain (same as the token factory).
 */
const TREASURIES: Record<number, string> = {
    84532: "0x987258079d90635293a17defd9db3a61626f8c3b", // Base Sepolia
    8453:  "0x3708ce94d50fe61113acbfbede05265a5ac74d24", // Base Mainnet
};

async function main() {
    console.log("Deploying MagnetaETFFactory...\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "native\n");

    const network = await ethers.provider.getNetwork();
    const chainId = Number(network.chainId);

    // Resolve treasury
    const treasuryAddress = TREASURIES[chainId]
        ? ethers.getAddress(TREASURIES[chainId])
        : deployer.address;

    if (!TREASURIES[chainId]) {
        console.log("Warning: unknown network, using deployer as treasury");
    }
    console.log("Treasury:", treasuryAddress);

    // Resolve Chainlink price feed
    const priceFeedAddress = PRICE_FEEDS[chainId] || ethers.ZeroAddress;
    if (priceFeedAddress === ethers.ZeroAddress) {
        console.log("Warning: no Chainlink feed for this chain — set a fallback fee after deploy");
    } else {
        console.log("Price feed:", priceFeedAddress);
    }

    // Deploy
    console.log("\nDeploying...");
    const Factory = await ethers.getContractFactory("MagnetaETFFactory");
    const factory = await Factory.deploy(treasuryAddress, priceFeedAddress);
    await factory.waitForDeployment();

    const address = await factory.getAddress();
    console.log("\nMagnetaETFFactory deployed at:", address);

    // If no price feed, queue the fallback fee (timelock: 24 h before it activates).
    // On fresh deploys you may need to wait the ADMIN_TIMELOCK before createETF works.
    if (priceFeedAddress === ethers.ZeroAddress) {
        const fallbackFee = ethers.parseEther("1"); // ~$2000 equivalent, adjust per chain
        const queueTx = await (factory as any).queueSetFallbackFee(fallbackFee);
        await queueTx.wait();
        console.log("Fallback fee queued:", ethers.formatEther(fallbackFee), "native");
        console.log("Execute `executeSetFallbackFee` after the 24 h timelock elapses.");
    }

    // Save deployment info
    const networkName = resolveNetworkName(chainId);
    const deploymentsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
    }

    const deploymentInfo = {
        factoryAddress: address,
        treasury: treasuryAddress,
        priceFeed: priceFeedAddress,
        deployer: deployer.address,
        network: networkName,
        chainId: chainId.toString(),
        deployedAt: new Date().toISOString(),
    };

    const deploymentFile = path.join(deploymentsDir, `${networkName}-etf-factory.json`);
    fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
    console.log("\nDeployment saved to:", deploymentFile);

    console.log("\nTo verify:");
    console.log(`npx hardhat verify --network ${networkName} ${address} "${treasuryAddress}" "${priceFeedAddress}"`);
}

function resolveNetworkName(chainId: number): string {
    const names: Record<number, string> = {
        1: "ethereum", 8453: "base", 42161: "arbitrum", 10: "optimism",
        137: "polygon", 56: "bsc", 43114: "avalanche", 59144: "linea",
        5000: "mantle", 42220: "celo", 84532: "baseSepolia",
        11155420: "optimismSepolia", 421614: "arbitrumSepolia",
        80002: "polygonAmoy", 1337: "localhost",
    };
    return names[chainId] || `chain-${chainId}`;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
