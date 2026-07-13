import { expect } from "chai";
import { ethers } from "hardhat";
import { Multisender, ERC20Token } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Multisender", function () {
    let multisender: Multisender;
    let token: ERC20Token;
    let owner: HardhatEthersSigner;
    let addr1: HardhatEthersSigner;
    let addr2: HardhatEthersSigner;
    let addr3: HardhatEthersSigner;

    const FEE_PER_RECIPIENT = ethers.parseEther("0.00005");

    beforeEach(async function () {
        [owner, addr1, addr2, addr3] = await ethers.getSigners();

        // Deploy Multisender
        // Constructor takes the fee recipient (FeeVault). Use owner in tests.
        const MultisenderFactory = await ethers.getContractFactory("Multisender");
        multisender = (await MultisenderFactory.deploy(owner.address)) as Multisender;
        await multisender.waitForDeployment();

        // Deploy Mock ERC20 Token for testing
        const ERC20TokenFactory = await ethers.getContractFactory("ERC20Token");
        token = (await ERC20TokenFactory.deploy(
            "Test Token",
            "TEST",
            "https://test.uri",
            ethers.parseEther("1000000"), // 1M Supply
            owner.address,
            false,
            false,
            false
        )) as ERC20Token;
        await token.waitForDeployment();
    });

    describe("Fee Management", function () {
        it("Should set initial fee correctly", async function () {
            expect(await multisender.feePerRecipient()).to.equal(FEE_PER_RECIPIENT);
        });

        it("Should execute update fee as owner", async function () {
            const newFee = ethers.parseEther("0.001");
            await multisender.setFeePerRecipient(newFee);
            expect(await multisender.feePerRecipient()).to.equal(newFee);
        });

        it("Should revert fee update from non-owner", async function () {
            await expect(multisender.connect(addr1).setFeePerRecipient(0))
                .to.be.revertedWithCustomError(multisender, "OwnableUnauthorizedAccount")
                .withArgs(addr1.address);
        });
    });

    describe("ETH Multisend", function () {
        it("Should distribute ETH correctly and collect fees", async function () {
            const recipients = [addr1.address, addr2.address];
            const amounts = [ethers.parseEther("1"), ethers.parseEther("2")];
            const totalAmount = ethers.parseEther("3");
            const totalFee = FEE_PER_RECIPIENT * BigInt(recipients.length);

            await expect(
                multisender.multisendEther(recipients, amounts, { value: totalAmount + totalFee })
            ).to.changeEtherBalances(
                [addr1, addr2, multisender],
                [amounts[0], amounts[1], totalFee]
            );
        });

        it("Should revert if insufficient ETH sent", async function () {
            const recipients = [addr1.address];
            const amounts = [ethers.parseEther("1")];
            const totalFee = FEE_PER_RECIPIENT;

            // Send exact amount without fee
            await expect(
                multisender.multisendEther(recipients, amounts, { value: amounts[0] })
            ).to.be.revertedWith("Insufficient ETH sent");
        });

        it("Should refund excess ETH", async function () {
            const recipients = [addr1.address];
            const amounts = [ethers.parseEther("1")];
            const totalFee = FEE_PER_RECIPIENT;
            const excess = ethers.parseEther("0.5");

            await expect(
                multisender.multisendEther(recipients, amounts, { value: amounts[0] + totalFee + excess })
            ).to.changeEtherBalances(
                [owner, multisender],
                [-(amounts[0] + totalFee), totalFee] // Owner spends amount+fee, receives nothing back (excess refunded implicitly in validation logic balance change?)
                // Actually changeEtherBalances checks limits. Let's inspect final balance manually or simpler check.
            );
            // Better check specifically the refund:
            // The expectation above is net change: -sent + refund.
            // sent = 1 + 0.00005 + 0.5 = 1.50005
            // refund = 0.5
            // net = -1.00005
            // contract gain = 0.00005 (fee)
            // addr1 gain = 1.0
        });
    });

    describe("Token Multisend", function () {
        it("Should distribute tokens correctly and collect ETH fees", async function () {
            const recipients = [addr1.address, addr2.address];
            const amounts = [ethers.parseEther("100"), ethers.parseEther("200")];
            const totalTokens = ethers.parseEther("300");
            const totalFee = FEE_PER_RECIPIENT * BigInt(recipients.length);

            // Approve Multisender to spend tokens
            await token.approve(await multisender.getAddress(), totalTokens);

            await expect(
                multisender.multisendToken(await token.getAddress(), recipients, amounts, { value: totalFee })
            ).to.changeTokenBalances(
                token,
                [owner, addr1, addr2],
                [-totalTokens, amounts[0], amounts[1]]
            );

            // Verify ETH fee collection
            expect(await ethers.provider.getBalance(await multisender.getAddress())).to.equal(totalFee);
        });

        it("Should fail if allowance is insufficient", async function () {
            const recipients = [addr1.address];
            const amounts = [ethers.parseEther("100")];
            const totalFee = FEE_PER_RECIPIENT;

            // No approval
            await expect(
                multisender.multisendToken(await token.getAddress(), recipients, amounts, { value: totalFee })
            ).to.be.reverted; // Accepts custom errors or legacy strings

        });

        it("Should reject a fee-on-transfer token instead of mis-distributing", async function () {
            // Deploy a 10% deflationary token: the contract receives less than
            // `totalTokens`, so the batch must revert clearly rather than fail on
            // the last recipient or leak stranded balances.
            const FotFactory = await ethers.getContractFactory("MockFeeOnTransferToken");
            const fot = await FotFactory.deploy(ethers.parseEther("1000"), 1000n); // 10% fee
            await fot.waitForDeployment();

            const recipients = [addr1.address, addr2.address];
            const amounts = [ethers.parseEther("100"), ethers.parseEther("200")];
            const totalTokens = ethers.parseEther("300");
            const totalFee = FEE_PER_RECIPIENT * BigInt(recipients.length);

            await fot.approve(await multisender.getAddress(), totalTokens);
            await expect(
                multisender.multisendToken(await fot.getAddress(), recipients, amounts, { value: totalFee })
            ).to.be.revertedWith("Multisender: fee-on-transfer token unsupported");
        });
    });

    describe("Withdrawals", function () {
        it("Should allow owner to withdraw accumulated fees", async function () {
            // Send some ETH to contract as fees
            const recipients = [addr1.address];
            const amounts = [ethers.parseEther("1")];
            const totalFee = FEE_PER_RECIPIENT;

            await multisender.multisendEther(recipients, amounts, { value: amounts[0] + totalFee });

            const initialOwnerBalance = await ethers.provider.getBalance(owner.address);

            // Withdraw
            const tx = await multisender.withdrawFees();
            const receipt = await tx.wait();

            // Calculate gas cost
            const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

            const finalOwnerBalance = await ethers.provider.getBalance(owner.address);

            // Owner balance should increase by fee - gas
            expect(finalOwnerBalance + gasUsed).to.equal(initialOwnerBalance + totalFee);
            expect(await ethers.provider.getBalance(await multisender.getAddress())).to.equal(0);
        });
    });
});
