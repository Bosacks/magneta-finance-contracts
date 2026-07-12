import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaServiceFee } from "../typechain-types";

describe("MagnetaServiceFee", () => {
    let collector: MagnetaServiceFee;
    let owner: SignerWithAddress;
    let alice: SignerWithAddress;
    let feeVault: SignerWithAddress;

    const OP = ethers.id("wallet-generation"); // bytes32 opId
    const FEE = ethers.parseEther("0.001");

    beforeEach(async () => {
        [owner, alice, feeVault] = await ethers.getSigners();
        const Factory = await ethers.getContractFactory("MagnetaServiceFee");
        collector = (await Factory.deploy(feeVault.address)) as unknown as MagnetaServiceFee;
        await collector.waitForDeployment();
    });

    it("rejects a zero fee vault at construction", async () => {
        const Factory = await ethers.getContractFactory("MagnetaServiceFee");
        await expect(Factory.deploy(ethers.ZeroAddress)).to.be.revertedWithCustomError(collector, "ZeroVault");
    });

    it("payFee reverts when the op fee is not set (disabled)", async () => {
        await expect(collector.connect(alice).payFee(OP, { value: FEE }))
            .to.be.revertedWithCustomError(collector, "FeeNotSet");
    });

    it("forwards the exact native fee to the FeeVault and emits a nonced event", async () => {
        await collector.setOpFee(OP, FEE);
        const before = await ethers.provider.getBalance(feeVault.address);
        await expect(collector.connect(alice).payFee(OP, { value: FEE }))
            .to.emit(collector, "ServiceFeePaid").withArgs(alice.address, OP, FEE, 0n);
        expect((await ethers.provider.getBalance(feeVault.address)) - before).to.equal(FEE);
    });

    it("reverts on a wrong fee amount (protocol-set, not caller-chosen)", async () => {
        await collector.setOpFee(OP, FEE);
        await expect(collector.connect(alice).payFee(OP, { value: FEE - 1n }))
            .to.be.revertedWithCustomError(collector, "WrongFeeAmount");
        await expect(collector.connect(alice).payFee(OP, { value: FEE + 1n }))
            .to.be.revertedWithCustomError(collector, "WrongFeeAmount");
    });

    it("increments the nonce so each payment is uniquely identifiable", async () => {
        await collector.setOpFee(OP, FEE);
        await expect(collector.connect(alice).payFee(OP, { value: FEE }))
            .to.emit(collector, "ServiceFeePaid").withArgs(alice.address, OP, FEE, 0n);
        await expect(collector.connect(alice).payFee(OP, { value: FEE }))
            .to.emit(collector, "ServiceFeePaid").withArgs(alice.address, OP, FEE, 1n);
        expect(await collector.paymentNonce()).to.equal(2n);
    });

    it("setOpFee is owner-only and bounded by maxOpFee", async () => {
        await expect(collector.connect(alice).setOpFee(OP, FEE))
            .to.be.revertedWith("Ownable: caller is not the owner");
        const max = await collector.maxOpFee();
        await expect(collector.setOpFee(OP, max + 1n))
            .to.be.revertedWithCustomError(collector, "FeeTooHigh");
        await expect(collector.setOpFee(OP, FEE))
            .to.emit(collector, "OpFeeUpdated").withArgs(OP, FEE);
    });

    it("setFeeVault is owner-only and rejects zero", async () => {
        await expect(collector.connect(alice).setFeeVault(alice.address))
            .to.be.revertedWith("Ownable: caller is not the owner");
        await expect(collector.setFeeVault(ethers.ZeroAddress))
            .to.be.revertedWithCustomError(collector, "ZeroVault");
        await expect(collector.setFeeVault(alice.address))
            .to.emit(collector, "FeeVaultUpdated").withArgs(alice.address);
    });
});
