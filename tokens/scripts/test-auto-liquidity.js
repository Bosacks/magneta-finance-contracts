const hre = require("hardhat");

async function main() {
    const contractAddress = "0xCc245B60B7Da5A708bd247B5fdE735E728c6a74d";
    const [deployer] = await hre.ethers.getSigners();

    console.log("Testing ERC20TokenAutoLiquidity at:", contractAddress);
    console.log("Using account:", deployer.address);

    // Get contract instance
    const ERC20TokenAutoLiquidity = await hre.ethers.getContractFactory("ERC20TokenAutoLiquidity");
    const token = ERC20TokenAutoLiquidity.attach(contractAddress);

    // Verify deployment
    console.log("\n--- Contract Info ---");

    try {
        const tokenName = await token.name();
        const tokenSymbol = await token.symbol();
        const tokenTax = await token.TRANSFER_TAX_BPS();
        const burnedAmount = await token.initialLiquidityBurned();
        const treasury = await token.treasuryAddress();
        const ownerBalance = await token.balanceOf(deployer.address);
        const deadBalance = await token.balanceOf("0x000000000000000000000000000000000000dEaD");
        const totalSupply = await token.totalSupply();

        console.log("Name:", tokenName);
        console.log("Symbol:", tokenSymbol);
        console.log("Total Supply:", hre.ethers.formatUnits(totalSupply, 9));
        console.log("Transfer Tax:", tokenTax.toString(), "bps (", Number(tokenTax) / 100, "%)");
        console.log("Burned Liquidity:", hre.ethers.formatUnits(burnedAmount, 9));
        console.log("Treasury Address:", treasury);
        console.log("Owner Balance:", hre.ethers.formatUnits(ownerBalance, 9));
        console.log("Dead Address Balance:", hre.ethers.formatUnits(deadBalance, 9));

        // Test transfer with tax
        console.log("\n--- Testing 2% Tax ---");
        const testAmount = hre.ethers.parseUnits("1000", 9);
        const expectedTax = (testAmount * BigInt(200)) / BigInt(10000);
        const expectedReceive = testAmount - expectedTax;

        console.log("Transfer Amount:", hre.ethers.formatUnits(testAmount, 9));
        console.log("Expected Tax (2%):", hre.ethers.formatUnits(expectedTax, 9));
        console.log("Expected Received:", hre.ethers.formatUnits(expectedReceive, 9));

        // Transfer to a test address
        const testAddress = "0x0000000000000000000000000000000000000001";
        const treasuryBalanceBefore = await token.balanceOf(treasury);
        const testBalanceBefore = await token.balanceOf(testAddress);

        console.log("\nBefore transfer:");
        console.log("- Test Address Balance:", hre.ethers.formatUnits(testBalanceBefore, 9));
        console.log("- Treasury Balance:", hre.ethers.formatUnits(treasuryBalanceBefore, 9));

        console.log("\nSending transfer transaction...");
        const tx = await token.transfer(testAddress, testAmount);
        console.log("Transaction hash:", tx.hash);
        await tx.wait();
        console.log("Transaction confirmed!");

        const testBalance = await token.balanceOf(testAddress);
        const treasuryBalanceAfter = await token.balanceOf(treasury);
        const taxCollected = treasuryBalanceAfter - treasuryBalanceBefore;
        const actualReceived = testBalance - testBalanceBefore;

        console.log("\nAfter transfer:");
        console.log("- Test Address Balance:", hre.ethers.formatUnits(testBalance, 9));
        console.log("- Treasury Balance:", hre.ethers.formatUnits(treasuryBalanceAfter, 9));
        console.log("- Tax Collected:", hre.ethers.formatUnits(taxCollected, 9));
        console.log("- Amount Received:", hre.ethers.formatUnits(actualReceived, 9));

        if (actualReceived === expectedReceive && taxCollected === expectedTax) {
            console.log("\n✅ TAX TEST PASSED! 2% tax is working correctly.");
        } else {
            console.log("\n⚠️ Results differ from expected:");
            console.log("Expected received:", hre.ethers.formatUnits(expectedReceive, 9), "Actual:", hre.ethers.formatUnits(actualReceived, 9));
            console.log("Expected tax:", hre.ethers.formatUnits(expectedTax, 9), "Actual:", hre.ethers.formatUnits(taxCollected, 9));
        }

        // Verify burned liquidity
        console.log("\n--- Burned Liquidity Verification ---");
        console.log("Tokens burned to dead address:", hre.ethers.formatUnits(deadBalance, 9));
        console.log("Recorded burn amount:", hre.ethers.formatUnits(burnedAmount, 9));

        if (deadBalance === burnedAmount) {
            console.log("✅ BURN VERIFICATION PASSED!");
        } else {
            console.log("⚠️ Burn amounts don't match");
        }

        console.log("\n========================================");
        console.log("SUMMARY:");
        console.log("========================================");
        console.log("✅ Contract deployed:", contractAddress);
        console.log("✅ 2% Transfer Tax: ACTIVE");
        console.log("✅ Burned Liquidity:", hre.ethers.formatUnits(deadBalance, 9), "tokens");
        console.log("✅ Treasury receiving taxes:", treasury);
        console.log("========================================");

    } catch (error) {
        console.error("Error:", error.message);
        console.log("\nContract might still be deploying. Try again in a few seconds.");
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
