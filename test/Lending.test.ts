import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaLending, MockERC20, MockPriceFeed } from "../typechain-types";

describe("MagnetaLending", function () {
    let lending: MagnetaLending;
    let token: MockERC20;
    let token2: MockERC20;
    let priceFeed: MockPriceFeed;
    let priceFeed2: MockPriceFeed;
    let owner: SignerWithAddress;
    let user: SignerWithAddress;
    let liquidator: SignerWithAddress;
    let receiver: SignerWithAddress;

    beforeEach(async function () {
        [owner, user, liquidator, receiver] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        token = await MockERC20.deploy("ETH Token", "ETH", 18, ethers.parseEther("1000000"));
        await token.waitForDeployment();

        token2 = await MockERC20.deploy("USDC Token", "USDC", 6, ethers.parseUnits("1000000", 6));
        await token2.waitForDeployment();

        const MockPriceFeed = await ethers.getContractFactory("MockPriceFeed");
        priceFeed = await MockPriceFeed.deploy(ethers.parseUnits("2000", 18), 18); // $2000 ETH
        await priceFeed.waitForDeployment();

        priceFeed2 = await MockPriceFeed.deploy(ethers.parseUnits("1", 18), 18); // $1 USDC
        await priceFeed2.waitForDeployment();

        const MagnetaLending = await ethers.getContractFactory("MagnetaLending");
        lending = await MagnetaLending.deploy();
        await lending.waitForDeployment();

        // Initialize reserves
        await lending.initReserve(await token.getAddress(), 7500, 8000);
        await lending.setPriceFeed(await token.getAddress(), await priceFeed.getAddress());

        await lending.initReserve(await token2.getAddress(), 8000, 8500);
        await lending.setPriceFeed(await token2.getAddress(), await priceFeed2.getAddress());

        // Give user some tokens
        await token.transfer(user.address, ethers.parseEther("1000"));
        await token2.transfer(liquidator.address, ethers.parseUnits("10000", 6));
        await token2.transfer(user.address, ethers.parseUnits("10000", 6));

        // Give protocol some liquidity in USDC so user can borrow
        await token2.approve(await lending.getAddress(), ethers.parseUnits("50000", 6));
        await lending.deposit(await token2.getAddress(), ethers.parseUnits("50000", 6));
    });

    describe("Core Functions", function () {
        it("Should allow deposit", async function () {
            const amount = ethers.parseEther("100");
            await token.connect(user).approve(await lending.getAddress(), amount);
            await lending.connect(user).deposit(await token.getAddress(), amount);

            expect(await lending.getUserCollateral(user.address, await token.getAddress())).to.equal(amount);
        });

        it("Should allow withdrawal", async function () {
            const amount = ethers.parseEther("100");
            await token.connect(user).approve(await lending.getAddress(), amount);
            await lending.connect(user).deposit(await token.getAddress(), amount);

            await lending.connect(user).withdraw(await token.getAddress(), amount);
            expect(await lending.getUserCollateral(user.address, await token.getAddress())).to.equal(0);
            expect(await token.balanceOf(user.address)).to.equal(ethers.parseEther("1000"));
        });

        it("Should allow borrowing", async function () {
            // First provide some liquidity to the pool from owner
            const liquidity = ethers.parseEther("500");
            await token.approve(await lending.getAddress(), liquidity);
            await lending.deposit(await token.getAddress(), liquidity);

            // User deposits collateral
            const collateral = ethers.parseEther("100");
            await token.connect(user).approve(await lending.getAddress(), collateral);
            await lending.connect(user).deposit(await token.getAddress(), collateral);

            // Borrow
            const borrowAmount = ethers.parseEther("50");
            await lending.connect(user).borrow(await token.getAddress(), borrowAmount);

            // In a real scenario with block mining, some interest might accrue instantly
            expect(await lending.getUserBorrow(user.address, await token.getAddress())).to.be.closeTo(borrowAmount, ethers.parseUnits("100", 0));
        });

        it("Should allow repaying", async function () {
            const liquidity = ethers.parseEther("500");
            await token.approve(await lending.getAddress(), liquidity);
            await lending.deposit(await token.getAddress(), liquidity);

            const collateral = ethers.parseEther("100");
            await token.connect(user).approve(await lending.getAddress(), collateral);
            await lending.connect(user).deposit(await token.getAddress(), collateral);

            const borrowAmount = ethers.parseEther("50");
            await lending.connect(user).borrow(await token.getAddress(), borrowAmount);

            // Repay all debt using type(uint256).max
            await token.connect(user).approve(await lending.getAddress(), ethers.MaxUint256);
            await lending.connect(user).repay(await token.getAddress(), ethers.MaxUint256);

            expect(await lending.getUserBorrow(user.address, await token.getAddress())).to.equal(0);
        });
    });

    describe("Liquidation", function () {
        it("Should allow liquidation when health factor < 1.0", async function () {
            // User deposits ETH collateral
            const collateralAmount = ethers.parseEther("1"); // $2000
            await token.connect(user).approve(await lending.getAddress(), collateralAmount);
            await lending.connect(user).deposit(await token.getAddress(), collateralAmount);

            // Borrow max possible USDC ($2000 * 0.75 = $1500)
            const borrowAmount = ethers.parseUnits("1500", 6);
            await lending.connect(user).borrow(await token2.getAddress(), borrowAmount);

            // Drop ETH price to $1700
            // HF = ($1700 * 0.8) / $1500 = 1360 / 1500 = 0.906
            await priceFeed.setPrice(ethers.parseUnits("1700", 18));

            // Health factor should be < 1.0
            const accountData = await lending.calculateUserAccountData(user.address);
            expect(accountData.healthFactor).to.be.below(ethers.parseEther("1"));

            // Liquidate
            const repayAmount = ethers.parseUnits("750", 6); // Half the debt
            await token2.connect(liquidator).approve(await lending.getAddress(), repayAmount);
            await lending.connect(liquidator).liquidate(
                user.address,
                await token2.getAddress(),
                await token.getAddress(),
                repayAmount
            );

            expect(await lending.getUserBorrow(user.address, await token2.getAddress())).to.be.below(borrowAmount);
            // Liquidator should have received some ETH
            expect(await token.balanceOf(liquidator.address)).to.be.above(0);
        });
    });
});
