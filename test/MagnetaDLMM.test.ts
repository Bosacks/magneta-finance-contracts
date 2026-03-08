import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaDLMM } from "../typechain-types";
import { MockERC20 } from "../typechain-types";

describe("MagnetaDLMM", function () {
    let dlmm: MagnetaDLMM;
    let tokenX: MockERC20;
    let tokenY: MockERC20;
    let owner: SignerWithAddress;
    let user: SignerWithAddress;

    const BIN_STEP = 10; // 0.1%
    const ACTIVE_ID = 8388608; // 2^23, price = 1

    beforeEach(async function () {
        [owner, user] = await ethers.getSigners();

        // Deploy mock tokens
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        tokenX = await MockERC20Factory.deploy("TokenX", "TKNX", 18, ethers.parseEther("1000000"));
        tokenY = await MockERC20Factory.deploy("TokenY", "TKNY", 18, ethers.parseEther("1000000"));

        // Deploy MagnetaDLMM
        // Constructor: tokenX, tokenY, binStep, lpFeeBps, protocolFeeBps, initialActiveId, owner, feeRecipient
        const MagnetaDLMMFactory = await ethers.getContractFactory("MagnetaDLMM");
        dlmm = await MagnetaDLMMFactory.deploy(
            await tokenX.getAddress(),
            await tokenY.getAddress(),
            BIN_STEP,       // binStep (uint16)
            30,             // lpFeeBps: 0.3%
            10,             // protocolFeeBps: 0.1%
            ACTIVE_ID,      // initialActiveId (uint24)
            owner.address,  // owner
            owner.address   // feeRecipient
        );

        // Transfer tokens to user
        await tokenX.transfer(user.address, ethers.parseEther("10000"));
        await tokenY.transfer(user.address, ethers.parseEther("10000"));
    });

    describe("Initialization", function () {
        it("Should initialize with correct parameters", async function () {
            expect(await dlmm.activeId()).to.equal(ACTIVE_ID);
            expect(await dlmm.binStep()).to.equal(BIN_STEP);
        });
    });

    describe("Adding Liquidity to Bin", function () {
        it("Should add liquidity to active bin", async function () {
            const amountX = ethers.parseEther("100");
            const amountY = ethers.parseEther("100");

            await tokenX.connect(user).approve(await dlmm.getAddress(), ethers.parseEther("10000"));
            await tokenY.connect(user).approve(await dlmm.getAddress(), ethers.parseEther("10000"));

            // addLiquidity(binId, amountX, amountY, minShares, to)
            await expect(dlmm.connect(user).addLiquidity(ACTIVE_ID, amountX, amountY, 0, user.address))
                .to.emit(dlmm, "LiquidityAdded")
                .withArgs(user.address, ACTIVE_ID, amountX, amountY, (val: any) => val > 0n);

            const bin = await dlmm.bins(ACTIVE_ID);
            expect(bin.reserveX).to.equal(amountX);
            expect(bin.reserveY).to.equal(amountY);
            expect(bin.totalShares).to.be.gt(0);
        });
    });

    describe("Swapping", function () {
        beforeEach(async function () {
            // Add liquidity to active bin
            const amountX = ethers.parseEther("100");
            const amountY = ethers.parseEther("100");

            await tokenX.connect(user).approve(await dlmm.getAddress(), ethers.parseEther("10000"));
            await tokenY.connect(user).approve(await dlmm.getAddress(), ethers.parseEther("10000"));
            await dlmm.connect(user).addLiquidity(ACTIVE_ID, amountX, amountY, 0, user.address);

            // Bins above active accept only X; bins below active accept only Y.
            await dlmm.connect(user).addLiquidity(ACTIVE_ID + 1, amountX, 0, 0, user.address);
            await dlmm.connect(user).addLiquidity(ACTIVE_ID - 1, 0, amountY, 0, user.address);
        });

        it("Should swap X for Y", async function () {
            const amountIn = ethers.parseEther("10");
            const minAmountOut = 0; // Slippage check disabled for test

            const balanceYBefore = await tokenY.balanceOf(user.address);

            // swap(swapForY, amountIn, minAmountOut, to)
            await expect(dlmm.connect(user).swap(true, amountIn, minAmountOut, user.address))
                .to.emit(dlmm, "Swap");

            const balanceYAfter = await tokenY.balanceOf(user.address);
            expect(balanceYAfter).to.be.gt(balanceYBefore);
            // At activeId = 2^23 the price is 1:1. Fee = lpFeeBps(30) + protocolFeeBps(10) = 40 bps.
            // expectedOut = amountIn * (10000 - 40) / 10000
            const expectedOutY = (amountIn * 9960n) / 10000n;
            expect(balanceYAfter - balanceYBefore).to.equal(expectedOutY);
        });

        it("Should swap Y for X", async function () {
            const amountIn = ethers.parseEther("10");
            const minAmountOut = 0;

            const balanceXBefore = await tokenX.balanceOf(user.address);

            await expect(dlmm.connect(user).swap(false, amountIn, minAmountOut, user.address))
                .to.emit(dlmm, "Swap");

            const balanceXAfter = await tokenX.balanceOf(user.address);
            expect(balanceXAfter).to.be.gt(balanceXBefore);
            // Same 40 bps fee applies for Y→X direction
            const expectedOutX = (amountIn * 9960n) / 10000n;
            expect(balanceXAfter - balanceXBefore).to.equal(expectedOutX);
        });
    });
});
