const { ethers } = require("hardhat");

// Deployed contract address on Base Sepolia
const CONTRACT_ADDRESS = "0x1960C2d7Ae61aCFFAbE60D21224552a7D4787A42";

async function main() {
    console.log("🧪 Testing ERC20Token Contract Functions\n");
    console.log("Contract Address:", CONTRACT_ADDRESS);
    console.log("=".repeat(60) + "\n");

    // Get signer
    const [owner] = await ethers.getSigners();
    console.log("👤 Owner Address:", owner.address);
    console.log("💰 Owner Balance:", ethers.formatEther(await ethers.provider.getBalance(owner.address)), "ETH\n");

    // Get contract instance
    const ERC20Token = await ethers.getContractFactory("ERC20Token");
    const token = ERC20Token.attach(CONTRACT_ADDRESS);

    // ============================================
    // 1. READ FUNCTIONS
    // ============================================
    console.log("📖 READING CONTRACT STATE");
    console.log("-".repeat(40));

    const name = await token.name();
    const symbol = await token.symbol();
    const decimals = await token.decimals();
    const totalSupply = await token.totalSupply();
    const ownerBalance = await token.balanceOf(owner.address);
    const tokenURI = await token.tokenURI();
    const paused = await token.paused();
    const revokeUpdateEnabled = await token.revokeUpdateEnabled();
    const revokeFreezeEnabled = await token.revokeFreezeEnabled();
    const revokeMintEnabled = await token.revokeMintEnabled();

    console.log("   Name:", name);
    console.log("   Symbol:", symbol);
    console.log("   Decimals:", decimals.toString());
    console.log("   Total Supply:", ethers.formatUnits(totalSupply, decimals));
    console.log("   Owner Balance:", ethers.formatUnits(ownerBalance, decimals));
    console.log("   Token URI:", tokenURI);
    console.log("   Paused:", paused);
    console.log("   Revoke Update Enabled:", revokeUpdateEnabled);
    console.log("   Revoke Freeze Enabled:", revokeFreezeEnabled);
    console.log("   Revoke Mint Enabled:", revokeMintEnabled);
    console.log("");

    // ============================================
    // 2. TEST MINTING (Token Minting feature)
    // ============================================
    console.log("🪙 TEST: Token Minting");
    console.log("-".repeat(40));

    const mintAmount = ethers.parseUnits("1000", decimals);
    console.log("   Minting", ethers.formatUnits(mintAmount, decimals), "tokens...");

    try {
        const mintTx = await token.mint(owner.address, mintAmount);
        await mintTx.wait();
        const newBalance = await token.balanceOf(owner.address);
        console.log("   ✅ Mint successful!");
        console.log("   New Balance:", ethers.formatUnits(newBalance, decimals));
    } catch (error) {
        console.log("   ❌ Mint failed:", error.message);
    }
    console.log("");

    // ============================================
    // 3. TEST UPDATE METADATA (Token Update feature)
    // ============================================
    console.log("📝 TEST: Update Metadata");
    console.log("-".repeat(40));

    const newMetadataURI = "https://magneta.finance/tokens/test/metadata.json";
    console.log("   Updating metadata URI to:", newMetadataURI);

    try {
        const updateTx = await token.updateMetadata(newMetadataURI);
        await updateTx.wait();
        const updatedURI = await token.tokenURI();
        console.log("   ✅ Metadata update successful!");
        console.log("   New URI:", updatedURI);
    } catch (error) {
        console.log("   ❌ Update failed:", error.message);
    }
    console.log("");

    // ============================================
    // 4. TEST PAUSE/UNPAUSE (Freeze/Unfreeze feature)
    // ============================================
    console.log("❄️ TEST: Freeze Account (Pause)");
    console.log("-".repeat(40));

    try {
        console.log("   Pausing token...");
        const pauseTx = await token.pause();
        await pauseTx.wait();
        const isPaused = await token.paused();
        console.log("   ✅ Pause successful! Paused:", isPaused);

        // Try transfer while paused (should fail)
        console.log("   Testing transfer while paused (should fail)...");
        try {
            await token.transfer(owner.address, ethers.parseUnits("1", decimals));
            console.log("   ❌ Transfer succeeded (unexpected)");
        } catch (e) {
            console.log("   ✅ Transfer blocked while paused (expected)");
        }

        // Unpause
        console.log("   Unpausing token...");
        const unpauseTx = await token.unpause();
        await unpauseTx.wait();
        const isUnpaused = !(await token.paused());
        console.log("   ✅ Unpause successful! Active:", isUnpaused);
    } catch (error) {
        console.log("   ❌ Freeze test failed:", error.message);
    }
    console.log("");

    // ============================================
    // 5. TEST REVOKE MINT (Revoke Permission feature)
    // ============================================
    console.log("🔒 TEST: Revoke Mint Permission");
    console.log("-".repeat(40));

    try {
        console.log("   Current revokeMintEnabled:", await token.revokeMintEnabled());
        console.log("   Enabling revoke mint...");
        const revokeMintTx = await token.enableRevokeMint();
        await revokeMintTx.wait();
        console.log("   ✅ Revoke mint enabled!");
        console.log("   New revokeMintEnabled:", await token.revokeMintEnabled());

        // Try to mint after revoke (should fail)
        console.log("   Testing mint after revoke (should fail)...");
        try {
            await token.mint(owner.address, ethers.parseUnits("100", decimals));
            console.log("   ❌ Mint succeeded (unexpected)");
        } catch (e) {
            console.log("   ✅ Mint blocked after revoke (expected)");
        }
    } catch (error) {
        console.log("   ❌ Revoke mint test failed:", error.message);
    }
    console.log("");

    // ============================================
    // 6. TEST REVOKE UPDATE (Revoke Permission feature)
    // ============================================
    console.log("🔒 TEST: Revoke Update Permission");
    console.log("-".repeat(40));

    try {
        console.log("   Current revokeUpdateEnabled:", await token.revokeUpdateEnabled());
        console.log("   Enabling revoke update...");
        const revokeUpdateTx = await token.enableRevokeUpdate();
        await revokeUpdateTx.wait();
        console.log("   ✅ Revoke update enabled!");
        console.log("   New revokeUpdateEnabled:", await token.revokeUpdateEnabled());

        // Try to update metadata after revoke (should fail)
        console.log("   Testing metadata update after revoke (should fail)...");
        try {
            await token.updateMetadata("https://should-fail.com");
            console.log("   ❌ Update succeeded (unexpected)");
        } catch (e) {
            console.log("   ✅ Update blocked after revoke (expected)");
        }
    } catch (error) {
        console.log("   ❌ Revoke update test failed:", error.message);
    }
    console.log("");

    // ============================================
    // 7. TEST REVOKE FREEZE (Revoke Permission feature)
    // ============================================
    console.log("🔒 TEST: Revoke Freeze Permission");
    console.log("-".repeat(40));

    try {
        console.log("   Current revokeFreezeEnabled:", await token.revokeFreezeEnabled());
        console.log("   Enabling revoke freeze...");
        const revokeFreezeTx = await token.enableRevokeFreeze();
        await revokeFreezeTx.wait();
        console.log("   ✅ Revoke freeze enabled!");
        console.log("   New revokeFreezeEnabled:", await token.revokeFreezeEnabled());

        // Try to pause after revoke (should fail)
        console.log("   Testing pause after revoke (should fail)...");
        try {
            await token.pause();
            console.log("   ❌ Pause succeeded (unexpected)");
        } catch (e) {
            console.log("   ✅ Pause blocked after revoke (expected)");
        }
    } catch (error) {
        console.log("   ❌ Revoke freeze test failed:", error.message);
    }
    console.log("");

    // ============================================
    // FINAL STATE
    // ============================================
    console.log("📊 FINAL CONTRACT STATE");
    console.log("-".repeat(40));
    console.log("   Total Supply:", ethers.formatUnits(await token.totalSupply(), decimals));
    console.log("   Owner Balance:", ethers.formatUnits(await token.balanceOf(owner.address), decimals));
    console.log("   Token URI:", await token.tokenURI());
    console.log("   Paused:", await token.paused());
    console.log("   Revoke Update:", await token.revokeUpdateEnabled());
    console.log("   Revoke Freeze:", await token.revokeFreezeEnabled());
    console.log("   Revoke Mint:", await token.revokeMintEnabled());
    console.log("");

    console.log("=".repeat(60));
    console.log("🎉 ALL TESTS COMPLETED!");
    console.log("=".repeat(60));
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Test failed:", error);
        process.exit(1);
    });
