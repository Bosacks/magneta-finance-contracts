import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaMultiPool } from "../typechain-types";
import { MockERC20 } from "../typechain-types";

describe("MagnetaMultiPool", function () {
    let multiPool: MagnetaMultiPool;
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

        // Deploy MagnetaMultiPool with 3 tokens
        const MagnetaMultiPoolFactory = await ethers.getContractFactory("MagnetaMultiPool");

        const tokens = [await token0.getAddress(), await token1.getAddress(), await token2.getAddress()];
        const weights = [ethers.parseEther("0.3"), ethers.parseEther("0.3"), ethers.parseEther("0.4")]; // 30%, 30%, 40%
        const swapFee = ethers.parseEther("0.003"); // 0.3%

        multiPool = await MagnetaMultiPoolFactory.deploy(
            "Magneta Multi Pool",
            "MMP",
            tokens,
            weights,
            swapFee,
            owner.address
        );

        // Transfer tokens to user
        await token0.transfer(user.address, ethers.parseEther("10000"));
        await token1.transfer(user.address, ethers.parseEther("10000"));
        await token2.transfer(user.address, ethers.parseEther("10000"));
    });

    describe("Initialization", function () {
        it("Should initialize with correct tokens and weights", async function () {
            expect(await multiPool.isTokenInPool(await token0.getAddress())).to.be.true;
            expect(await multiPool.isTokenInPool(await token1.getAddress())).to.be.true;
            expect(await multiPool.isTokenInPool(await token2.getAddress())).to.be.true;

            const poolTokens = await multiPool.getTokens();
            expect(poolTokens).to.have.length(3);
        });
    });

    describe("Adding Liquidity", function () {
        it("Should add liquidity proportionally", async function () {
            const amount0 = ethers.parseEther("100");
            const amount1 = ethers.parseEther("100");
            const amount2 = ethers.parseEther("133.333333333333333333"); // Roughly proportional to 30/30/40 ratio logic for simplified test
            // Actually the current simplified implementations might just take amounts as is for initial mint

            const amounts = [ethers.parseEther("30"), ethers.parseEther("30"), ethers.parseEther("40")];

            await token0.connect(user).approve(await multiPool.getAddress(), ethers.parseEther("10000"));
            await token1.connect(user).approve(await multiPool.getAddress(), ethers.parseEther("10000"));
            await token2.connect(user).approve(await multiPool.getAddress(), ethers.parseEther("10000"));

            await expect(multiPool.connect(user).addLiquidity(amounts, 0))
                .to.emit(multiPool, "LiquidityAdded");

            expect(await multiPool.balanceOf(user.address)).to.be.gt(0);
        });
    });

    describe("Swapping", function () {
        beforeEach(async function () {
            const amounts = [ethers.parseEther("3000"), ethers.parseEther("3000"), ethers.parseEther("4000")];

            await token0.connect(user).approve(await multiPool.getAddress(), ethers.parseEther("10000"));
            await token1.connect(user).approve(await multiPool.getAddress(), ethers.parseEther("10000"));
            await token2.connect(user).approve(await multiPool.getAddress(), ethers.parseEther("10000"));

            await multiPool.connect(user).addLiquidity(amounts, 0);
        });

        it("Should swap tokens correctly", async function () {
            const amountIn = ethers.parseEther("100");

            // Approve check
            await token0.connect(user).approve(await multiPool.getAddress(), ethers.parseEther("10000"));

            // Check balance before
            const balance1Before = await token1.balanceOf(user.address);

            await expect(
                multiPool.connect(user).swap(
                    await token0.getAddress(),
                    await token1.getAddress(),
                    amountIn,
                    0
                )
            ).to.emit(multiPool, "Swap");

            const balance1After = await token1.balanceOf(user.address);
            expect(balance1After).to.be.gt(balance1Before);
        });
    });
});
