import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaFactory, MagnetaPool, MockERC20 } from "../typechain-types";

describe("MagnetaFactory", function () {
    let factory: MagnetaFactory;
    let standardPool: MagnetaPool;
    let token0: MockERC20;
    let token1: MockERC20;
    let token2: MockERC20;
    let owner: SignerWithAddress;
    let user: SignerWithAddress;

    beforeEach(async function () {
        [owner, user] = await ethers.getSigners();

        // Deploy mock tokens
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        token0 = await MockERC20Factory.deploy("Token0", "TKN0", 18, ethers.parseEther("1000000"));
        token1 = await MockERC20Factory.deploy("Token1", "TKN1", 18, ethers.parseEther("1000000"));
        token2 = await MockERC20Factory.deploy("Token2", "TKN2", 18, ethers.parseEther("1000000"));

        // Deploy standard pool manager
        const MagnetaPoolFactory = await ethers.getContractFactory("MagnetaPool");
        standardPool = await MagnetaPoolFactory.deploy(owner.address);

        // Deploy Factory
        const MagnetaFactoryContract = await ethers.getContractFactory("MagnetaFactory");
        factory = await MagnetaFactoryContract.deploy(await standardPool.getAddress(), owner.address);

        // Give pool creation permission to factory in standard pool
        // Actually standardPool.createPool is public, but let's check
    });

    it("Should create a Multi-Token Pool", async function () {
        const tokens = [await token0.getAddress(), await token1.getAddress(), await token2.getAddress()];
        const weights = [ethers.parseEther("0.4"), ethers.parseEther("0.3"), ethers.parseEther("0.3")];
        const swapFee = ethers.parseEther("0.003"); // 0.3%

        const tx = await factory.createMultiPool(
            "Triple Pool",
            "TRP",
            tokens,
            weights,
            swapFee
        );

        await expect(tx).to.emit(factory, "MultiPoolCreated");

        const counts = await factory.getPoolCounts();
        expect(counts.multiCount).to.equal(1);

        const poolAddress = await factory.multiPools(0);
        expect(poolAddress).to.not.equal(ethers.ZeroAddress);
    });

    it("Should create a DLMM Pool", async function () {
        const binStep = 10;
        const activeId = 2 ** 23; // Middle active ID

        // createDLMMPool: tokenX, tokenY, binStep, lpFeeBps, protocolFeeBps, initialActiveId, feeRecipient
        const tx = await factory.createDLMMPool(
            await token0.getAddress(),
            await token1.getAddress(),
            binStep,        // binStep (uint16)
            30,             // lpFeeBps: 0.3%
            10,             // protocolFeeBps: 0.1%
            activeId,       // initialActiveId (uint24)
            owner.address   // feeRecipient
        );

        await expect(tx).to.emit(factory, "DLMMPoolCreated");

        const counts = await factory.getPoolCounts();
        expect(counts.dlmmCount).to.equal(1);

        const poolAddress = await factory.dlmmPools(0);
        expect(poolAddress).to.not.equal(ethers.ZeroAddress);
    });

    it("Should create a Standard Pool via wrapper", async function () {
        // StandardPool needs creation enabled
        await standardPool.setPoolCreationEnabled(true);

        const tx = await factory.createStandardPool(
            await token0.getAddress(),
            await token1.getAddress(),
            30 // 0.3%
        );

        await expect(tx).to.emit(factory, "StandardPoolCreated");

        const poolId = await standardPool.getPool(await token0.getAddress(), await token1.getAddress(), 30);
        expect(poolId).to.equal(1);
    });
});
