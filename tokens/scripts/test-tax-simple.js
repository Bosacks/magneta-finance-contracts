const hre = require("hardhat");

async function main() {
    const contractAddress = "0xCc245B60B7Da5A708bd247B5fdE735E728c6a74d";
    // Use a random address with correct checksum for testing
    const realTestAddr = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"; // Random valid address
    const treasuryAddr = "0x2ffA084561509a6F3F9454Bc0312dCED70E193B4";

    const ERC20TokenAutoLiquidity = await hre.ethers.getContractFactory("ERC20TokenAutoLiquidity");
    const token = ERC20TokenAutoLiquidity.attach(contractAddress);

    console.log("=== Testing 2% Tax Transfer ===\n");

    // Get balances before
    const testBefore = await token.balanceOf(realTestAddr);
    const treasuryBefore = await token.balanceOf(treasuryAddr);

    console.log("Before Transfer:");
    console.log("- Test Address Balance:", hre.ethers.formatUnits(testBefore, 9));
    console.log("- Treasury Balance:", hre.ethers.formatUnits(treasuryBefore, 9));

    // Transfer
    const amount = hre.ethers.parseUnits("1000", 9);
    console.log("\nTransferring 1000 tokens...");
    const tx = await token.transfer(realTestAddr, amount);
    console.log("Tx hash:", tx.hash);
    await tx.wait();
    console.log("Confirmed!");

    // Get balances after
    const testAfter = await token.balanceOf(realTestAddr);
    const treasuryAfter = await token.balanceOf(treasuryAddr);

    const received = testAfter - testBefore;
    const taxed = treasuryAfter - treasuryBefore;

    console.log("\nAfter Transfer:");
    console.log("- Test Address Balance:", hre.ethers.formatUnits(testAfter, 9));
    console.log("- Treasury Balance:", hre.ethers.formatUnits(treasuryAfter, 9));
    console.log("");
    console.log("- Amount Received:", hre.ethers.formatUnits(received, 9), "(expected: 980)");
    console.log("- Tax Collected:", hre.ethers.formatUnits(taxed, 9), "(expected: 20)");

    if (received === hre.ethers.parseUnits("980", 9) && taxed === hre.ethers.parseUnits("20", 9)) {
        console.log("\n✅ SUCCESS! 2% TAX IS WORKING CORRECTLY!");
    } else {
        console.log("\n⚠️ Check the values above");
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
