const { ethers } = require("hardhat");

async function main() {
    const FACTORY_ADDRESS = "0xb4AfddBE494f5b3062A19b7dc00368E4fcD87855";
    console.log("🔍 Verifying MagnetaTokenFactory at:", FACTORY_ADDRESS);

    const [signer] = await ethers.getSigners();
    console.log("👤 Using address:", signer.address);

    const Factory = await ethers.getContractAt("MagnetaTokenFactory", FACTORY_ADDRESS);

    // 1. Fetch current fee
    const fee = await Factory.createFee();
    console.log("💰 Current Factory Fee:", ethers.formatEther(fee), "ETH");

    // 2. Test Standard Token Creation
    console.log("\n🚀 Testing Standard Token Creation...");
    console.log("📤 Sending fee:", ethers.formatEther(fee), "ETH");
    const tx1 = await Factory.createStandardToken(
        "Factory Test Token",
        "FTT",
        "ipfs://test-metadata",
        ethers.parseUnits("1000000", 18),
        false, // revokeUpdate
        false, // revokeFreeze
        false, // revokeMint
        {
            value: fee,
            gasLimit: 3000000 // Force high gas limit to see real error if it fails
        }
    );
    console.log("⏳ Waiting for confirmation (tx: " + tx1.hash + ")...");
    const receipt1 = await tx1.wait();

    // Find TokenCreated event
    const event1 = receipt1.logs.find(log => {
        try {
            const parsed = Factory.interface.parseLog(log);
            return parsed && parsed.name === "TokenCreated";
        } catch (e) { return false; }
    });

    if (event1) {
        const parsed = Factory.interface.parseLog(event1);
        console.log("✅ Standard Token Created at:", parsed.args.tokenAddress);
    } else {
        console.log("❌ TokenCreated event not found for Standard Token");
    }

    // 3. Test Auto-Liquidity Token Creation
    console.log("\n🚀 Testing Auto-Liquidity Token Creation...");
    const tx2 = await Factory.createAutoLiquidityToken(
        "Factory Tax Token",
        "TAX",
        "ipfs://test-tax",
        ethers.parseUnits("1000000", 18),
        200, // 2% tax
        { value: 0 }
    );
    console.log("⏳ Waiting for confirmation (tx: " + tx2.hash + ")...");
    const receipt2 = await tx2.wait();

    const event2 = receipt2.logs.find(log => {
        try {
            const parsed = Factory.interface.parseLog(log);
            return parsed && parsed.name === "TokenCreated";
        } catch (e) { return false; }
    });

    if (event2) {
        const parsed = Factory.interface.parseLog(event2);
        console.log("✅ Auto-Liquidity Token Created at:", parsed.args.tokenAddress);
    } else {
        console.log("❌ TokenCreated event not found for Auto-Liquidity Token");
    }

    // 4. Check Registry
    console.log("\n📋 Checking User Tokens Registry...");
    const tokens = await Factory.getUserTokens(signer.address);
    console.log("🔢 Total tokens in registry for user:", tokens.length);
    console.log("📄 Last few tokens:", tokens.slice(-2));

    console.log("\n✨ On-chain verification complete!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
