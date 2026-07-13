const hre = require("hardhat");

async function main() {
    const contractAddress = "0xCc245B60B7Da5A708bd247B5fdE735E728c6a74d";
    const [deployer] = await hre.ethers.getSigners();

    const token = await hre.ethers.getContractAt("ERC20TokenAutoLiquidity", contractAddress);

    console.log("=== Debugging Tax Transfer ===\n");

    // Check owner exemption
    const isOwnerExempt = await token.isTaxExempt(deployer.address);
    console.log("Owner", deployer.address);
    console.log("Owner is tax exempt:", isOwnerExempt);

    // First, remove owner from tax exemption to test
    console.log("\nRemoving owner from tax exemption...");
    const exemptTx = await token.setTaxExempt(deployer.address, false);
    await exemptTx.wait();

    const isOwnerExemptNow = await token.isTaxExempt(deployer.address);
    console.log("Owner is now exempt:", isOwnerExemptNow);

    // Now try new address
    const testAddr = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B";
    const treasuryAddr = "0x2ffA084561509a6F3F9454Bc0312dCED70E193B4";

    console.log("\n=== Tax Test ===");
    const treasuryBefore = await token.balanceOf(treasuryAddr);
    const testBefore = await token.balanceOf(testAddr);
    const ownerBefore = await token.balanceOf(deployer.address);

    console.log("Before:");
    console.log("- Owner:", hre.ethers.formatUnits(ownerBefore, 9));
    console.log("- Test:", hre.ethers.formatUnits(testBefore, 9));
    console.log("- Treasury:", hre.ethers.formatUnits(treasuryBefore, 9));

    const amount = hre.ethers.parseUnits("1000", 9);
    console.log("\nTransferring 1000 tokens to test address...");

    try {
        const tx = await token.transfer(testAddr, amount);
        console.log("TX:", tx.hash);
        await tx.wait();
        console.log("Confirmed!");
    } catch (e) {
        console.log("Transfer failed:", e.message);
    }

    const treasuryAfter = await token.balanceOf(treasuryAddr);
    const testAfter = await token.balanceOf(testAddr);
    const ownerAfter = await token.balanceOf(deployer.address);

    console.log("\nAfter:");
    console.log("- Owner:", hre.ethers.formatUnits(ownerAfter, 9), "(spent:", hre.ethers.formatUnits(ownerBefore - ownerAfter, 9), ")");
    console.log("- Test:", hre.ethers.formatUnits(testAfter, 9), "(received:", hre.ethers.formatUnits(testAfter - testBefore, 9), ")");
    console.log("- Treasury:", hre.ethers.formatUnits(treasuryAfter, 9), "(taxed:", hre.ethers.formatUnits(treasuryAfter - treasuryBefore, 9), ")");

    const spent = ownerBefore - ownerAfter;
    const received = testAfter - testBefore;
    const taxed = treasuryAfter - treasuryBefore;

    if (spent > 0 && received > 0) {
        console.log("\n✅ Transfer successful!");
        console.log("Tax rate:", Number(taxed) / Number(spent) * 100, "%");
    }

    // Re-enable owner exemption
    console.log("\nRestoring owner tax exemption...");
    const restoreTx = await token.setTaxExempt(deployer.address, true);
    await restoreTx.wait();
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
