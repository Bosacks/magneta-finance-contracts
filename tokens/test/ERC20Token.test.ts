import { expect } from "chai";
import { ethers } from "hardhat";
import { ERC20Token } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("ERC20Token", function () {
    let token: ERC20Token;
    let owner: HardhatEthersSigner;
    let addr1: HardhatEthersSigner;
    let addr2: HardhatEthersSigner;
    let marketingWallet: HardhatEthersSigner;
    let addrs: HardhatEthersSigner[];

    // Token parameters
    const NAME = "Magneta Token";
    const SYMBOL = "MAG";
    const INITIAL_SUPPLY = ethers.parseEther("1000000"); // 1 million tokens

    beforeEach(async function () {
        [owner, addr1, addr2, marketingWallet, ...addrs] = await ethers.getSigners();

        const ERC20TokenFactory = await ethers.getContractFactory("ERC20Token");
        token = (await ERC20TokenFactory.deploy(
            NAME,
            SYMBOL,
            "https://example.com/token.json", // initialURI
            INITIAL_SUPPLY,
            owner.address,
            false, // revokeUpdate
            false, // revokeFreeze
            false  // revokeMint
        )) as ERC20Token;
        await token.waitForDeployment();
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            expect(await token.owner()).to.equal(owner.address);
        });

        it("Should assign the total supply to the owner", async function () {
            const ownerBalance = await token.balanceOf(owner.address);
            expect(await token.totalSupply()).to.equal(ownerBalance);
        });

        it("Should set the correct name and symbol", async function () {
            expect(await token.name()).to.equal(NAME);
            expect(await token.symbol()).to.equal(SYMBOL);
        });
    });

    describe("Blacklist", function () {
        it("Should allow owner to blacklist an address", async function () {
            await expect(token.blacklist(addr1.address, true))
                .to.emit(token, "BlacklistUpdated")
                .withArgs(addr1.address, true);

            expect(await token.isBlacklisted(addr1.address)).to.be.true;
        });

        it("Should fail if non-owner tries to blacklist", async function () {
            await expect(token.connect(addr1).blacklist(addr2.address, true))
                .to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount")
                .withArgs(addr1.address);
        });

        it("Should prevent blacklisted address from transferring tokens", async function () {
            // Transfer some tokens to addr1 first
            await token.transfer(addr1.address, ethers.parseEther("100"));

            // Blacklist addr1
            await token.blacklist(addr1.address, true);

            // Try to transfer from addr1
            await expect(
                token.connect(addr1).transfer(addr2.address, ethers.parseEther("50"))
            ).to.be.revertedWith("ERC20Token: Account is blacklisted");
        });

        it("Should prevent sending tokens TO a blacklisted address", async function () {
            // Blacklist addr2
            await token.blacklist(addr2.address, true);

            // Try to transfer to addr2
            await expect(
                token.transfer(addr2.address, ethers.parseEther("50"))
            ).to.be.revertedWith("ERC20Token: Account is blacklisted");
        });

        it("Should prevent blacklisting after freeze has been revoked (INV-7)", async function () {
            // Freeze addr1 BEFORE revoking, so we can prove release still works after.
            await token.blacklist(addr1.address, true);
            expect(await token.isBlacklisted(addr1.address)).to.be.true;

            // Revoke freezing irreversibly
            await token.enableRevokeFreeze();
            expect(await token.revokeFreezeEnabled()).to.be.true;

            // NEW freezes must now revert, mirroring the pause() guard
            await expect(
                token.blacklist(addr2.address, true)
            ).to.be.revertedWith("ERC20Token: Freezing has been revoked");

            // But RELEASING an already-frozen account must still be allowed
            // (otherwise revoking the freeze authority would trap frozen users).
            await token.blacklist(addr1.address, false);
            expect(await token.isBlacklisted(addr1.address)).to.be.false;
        });

        it("Should prevent blacklisting at deploy time when revokeFreeze is set", async function () {
            const ERC20TokenFactory = await ethers.getContractFactory("ERC20Token");
            const revokedToken = (await ERC20TokenFactory.deploy(
                NAME,
                SYMBOL,
                "https://example.com/token.json",
                INITIAL_SUPPLY,
                owner.address,
                false, // revokeUpdate
                true,  // revokeFreeze
                false  // revokeMint
            )) as ERC20Token;
            await revokedToken.waitForDeployment();

            await expect(
                revokedToken.blacklist(addr1.address, true)
            ).to.be.revertedWith("ERC20Token: Freezing has been revoked");
        });

        it("Should allow transfer after unblacklisting", async function () {
            // Transfer some tokens to addr1 first
            await token.transfer(addr1.address, ethers.parseEther("100"));

            // Blacklist then unblacklist
            await token.blacklist(addr1.address, true);
            await token.blacklist(addr1.address, false);

            // Transfer should now succeed
            await expect(
                token.connect(addr1).transfer(addr2.address, ethers.parseEther("50"))
            ).to.changeTokenBalances(token, [addr1, addr2], [ethers.parseEther("-50"), ethers.parseEther("50")]);
        });
    });

    describe("Tax Fees", function () {
        beforeEach(async function () {
            // Set marketing wallet
            await token.setMarketingWallet(marketingWallet.address);
        });

        it("Should allow owner to set tax fee", async function () {
            // Set 5% tax (500 basis points)
            await expect(token.setTaxFee(500))
                .to.emit(token, "TaxFeeUpdated")
                .withArgs(500);

            expect(await token.taxFee()).to.equal(500);
        });

        it("Should fail if fee is too high (e.g. > 25%)", async function () {
            await expect(token.setTaxFee(2501)).to.be.revertedWith("ERC20Token: Fee cannot exceed 25%");
        });

        it("Should deduct tax on transfer and store in contract", async function () {
            // Set 1% tax (100 basis points)
            await token.setTaxFee(100);

            // Transfer 1000 tokens from owner to addr1.
            // Logic: "from != owner() && to != owner()". So Owner -> Addr1 has NO fee.
            await token.transfer(addr1.address, ethers.parseEther("1000"));

            // Addr1 transfers 100 to Addr2
            const amount = ethers.parseEther("100");
            const tax = amount * 100n / 10000n; // 1%
            const amountAfterTax = amount - tax; // 99

            // Verify transfer event and balances
            // addr1 loses 'amount' (100)
            // addr2 gains 'amountAfterTax' (99)
            // contract gains 'tax' (1)
            await expect(
                token.connect(addr1).transfer(addr2.address, amount)
            ).to.changeTokenBalances(
                token,
                [addr1, addr2, token],
                [-amount, amountAfterTax, tax]
            );
        });

        it("Should allow owner to withdraw accumulated fees", async function () {
            // Setup: Accumulate fees
            await token.setTaxFee(100); // 1%
            await token.transfer(addr1.address, ethers.parseEther("1000"));

            // Addr1 -> Addr2 (generates fee)
            await token.connect(addr1).transfer(addr2.address, ethers.parseEther("100")); // 1 token fee

            const feeAmount = ethers.parseEther("1");
            // Check contract balance
            expect(await token.balanceOf(await token.getAddress())).to.equal(feeAmount);

            // Withdraw
            await expect(token.withdrawFees())
                .to.changeTokenBalances(
                    token,
                    [token, marketingWallet],
                    [-feeAmount, feeAmount]
                );
        });
    });
});
