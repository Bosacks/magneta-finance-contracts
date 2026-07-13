const hre = require("hardhat");

async function main() {
    console.log("Starting Faucet deployment...");

    const [deployer] = await hre.ethers.getSigners();
    console.log("Deploying contracts with the account:", deployer.address);

    // Deploy Faucet with 0.01 ETH drip amount
    const DRIP_AMOUNT = hre.ethers.parseEther("0.01");
    const Faucet = await hre.ethers.getContractFactory("Faucet");
    const faucet = await Faucet.deploy(DRIP_AMOUNT);

    await faucet.waitForDeployment();
    const address = await faucet.getAddress();

    console.log(`Faucet deployed to: ${address}`);

    // Fund the faucet with 0.1 ETH (optional, can be done later)
    const FUND_AMOUNT = hre.ethers.parseEther("0.1");
    const balance = await deployer.provider.getBalance(deployer.address);

    if (balance >= FUND_AMOUNT + hre.ethers.parseEther("0.01")) { // Check if enough for gas + fund
        console.log(`Funding faucet with ${hre.ethers.formatEther(FUND_AMOUNT)} ETH...`);
        const tx = await deployer.sendTransaction({
            to: address,
            value: FUND_AMOUNT
        });
        await tx.wait();
        console.log("Faucet funded!");
    } else {
        console.log("Not enough funds to pre-fund faucet. Please fund manually.");
    }

    // Verify if valid network
    if (hre.network.name !== "hardhat" && hre.network.name !== "localhost") {
        console.log("Waiting for block confirmations...");
        await faucet.deploymentTransaction().wait(5);

        try {
            await hre.run("verify:verify", {
                address: address,
                constructorArguments: [DRIP_AMOUNT],
            });
        } catch (e) {
            console.log("Verification failed:", e.message);
        }
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
