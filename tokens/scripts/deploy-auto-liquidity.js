const hre = require("hardhat");

async function main() {
    const [deployer] = await hre.ethers.getSigners();

    console.log("Deploying ERC20TokenAutoLiquidity with the account:", deployer.address);
    console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

    // Token parameters
    const name = "Test Auto Liquidity Token";
    const symbol = "TALT";
    const initialURI = "https://example.com/metadata.json";
    const totalSupply = hre.ethers.parseUnits("1000000000", 9); // 1 billion with 9 decimals
    const treasuryAddress = "0x2ffA084561509a6F3F9454Bc0312dCED70E193B4"; // Magneta Treasury for Base
    const liquidityToBurn = hre.ethers.parseUnits("100000000", 9); // 100 million (10%) burned

    console.log("\nDeployment parameters:");
    console.log("- Name:", name);
    console.log("- Symbol:", symbol);
    console.log("- Total Supply:", "1,000,000,000");
    console.log("- Treasury Address:", treasuryAddress);
    console.log("- Liquidity to Burn:", "100,000,000 (10%)");
    console.log("- Transfer Tax:", "2%");

    // Deploy the contract
    const ERC20TokenAutoLiquidity = await hre.ethers.getContractFactory("ERC20TokenAutoLiquidity");
    const token = await ERC20TokenAutoLiquidity.deploy(
        name,
        symbol,
        initialURI,
        totalSupply,
        deployer.address,
        treasuryAddress,
        liquidityToBurn
    );

    await token.waitForDeployment();
    const contractAddress = await token.getAddress();

    console.log("\n✅ ERC20TokenAutoLiquidity deployed to:", contractAddress);
    console.log("Transaction hash:", token.deploymentTransaction()?.hash);

    // Verify deployment
    console.log("\n--- Verification ---");

    const tokenName = await token.name();
    const tokenSymbol = await token.symbol();
    const tokenTax = await token.TRANSFER_TAX_BPS();
    const burnedAmount = await token.initialLiquidityBurned();
    const treasury = await token.treasuryAddress();
    const ownerBalance = await token.balanceOf(deployer.address);
    const deadBalance = await token.balanceOf("0x000000000000000000000000000000000000dEaD");

    console.log("Name:", tokenName);
    console.log("Symbol:", tokenSymbol);
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
    const treasuryBalanceBefore = await token.balanceOf(treasuryAddress);

    const tx = await token.transfer(testAddress, testAmount);
    await tx.wait();

    const testBalance = await token.balanceOf(testAddress);
    const treasuryBalanceAfter = await token.balanceOf(treasuryAddress);
    const taxCollected = treasuryBalanceAfter - treasuryBalanceBefore;

    console.log("\nActual Results:");
    console.log("Test Address Balance:", hre.ethers.formatUnits(testBalance, 9));
    console.log("Tax Collected to Treasury:", hre.ethers.formatUnits(taxCollected, 9));

    if (testBalance === expectedReceive && taxCollected === expectedTax) {
        console.log("\n✅ TAX TEST PASSED! 2% tax is working correctly.");
    } else {
        console.log("\n❌ TAX TEST FAILED!");
        console.log("Expected received:", hre.ethers.formatUnits(expectedReceive, 9), "Actual:", hre.ethers.formatUnits(testBalance, 9));
        console.log("Expected tax:", hre.ethers.formatUnits(expectedTax, 9), "Actual:", hre.ethers.formatUnits(taxCollected, 9));
    }

    // Save deployment info
    const fs = require("fs");
    const deploymentInfo = {
        contract: "ERC20TokenAutoLiquidity",
        address: contractAddress,
        network: hre.network.name,
        deployer: deployer.address,
        treasuryAddress: treasuryAddress,
        transferTaxBps: 200,
        liquidityBurned: burnedAmount.toString(),
        deployedAt: new Date().toISOString()
    };

    fs.writeFileSync(
        `./deployments/ERC20TokenAutoLiquidity-${hre.network.name}.json`,
        JSON.stringify(deploymentInfo, null, 2)
    );

    console.log("\n📁 Deployment info saved to deployments/ERC20TokenAutoLiquidity-" + hre.network.name + ".json");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
