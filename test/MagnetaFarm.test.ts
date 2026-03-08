import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaFarm } from "../typechain-types";
import { MockERC20 } from "../typechain-types";

describe("MagnetaFarm", function () {
  let magnetaFarm: MagnetaFarm;
  let rewardToken: MockERC20;
  let lpToken: MockERC20;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  beforeEach(async function () {
    [owner, user] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    rewardToken = await MockERC20Factory.deploy("Reward Token", "RWD", 18, ethers.parseEther("1000000"));
    lpToken = await MockERC20Factory.deploy("LP Token", "LP", 18, ethers.parseEther("1000000"));

    // Deploy MagnetaFarm
    const MagnetaFarmFactory = await ethers.getContractFactory("MagnetaFarm");
    const startBlock = await ethers.provider.getBlockNumber();
    magnetaFarm = await MagnetaFarmFactory.deploy(
      owner.address,
      await rewardToken.getAddress(),
      ethers.parseEther("1"), // 1 token per block
      startBlock
    );

    // Transfer LP tokens to user
    await lpToken.transfer(user.address, ethers.parseEther("10000"));

    // Transfer reward tokens to farm
    await rewardToken.transfer(await magnetaFarm.getAddress(), ethers.parseEther("100000"));
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await magnetaFarm.owner()).to.equal(owner.address);
    });

    it("Should set the right reward token", async function () {
      expect(await magnetaFarm.rewardToken()).to.equal(await rewardToken.getAddress());
    });

    it("Should set the right reward per block", async function () {
      expect(await magnetaFarm.rewardPerBlock()).to.equal(ethers.parseEther("1"));
    });
  });

  describe("Pool Management", function () {
    it("Should allow owner to add a pool", async function () {
      const tx = await magnetaFarm.addPool(await lpToken.getAddress(), 100, false, false);

      await expect(tx)
        .to.emit(magnetaFarm, "PoolAdded")
        .withArgs(0, await lpToken.getAddress(), 100, false);

      const pool = await magnetaFarm.poolInfo(0);
      expect(pool.lpToken).to.equal(await lpToken.getAddress());
      expect(pool.allocPoint).to.equal(100);
      expect(pool.exists).to.be.true;
    });

    it("Should not allow non-owner to add a pool", async function () {
      await expect(
        magnetaFarm.connect(user).addPool(await lpToken.getAddress(), 100, false, false)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should allow owner to update pool allocation", async function () {
      await magnetaFarm.addPool(await lpToken.getAddress(), 100, false, false);
      await magnetaFarm.setPool(0, 200, false);

      const pool = await magnetaFarm.poolInfo(0);
      expect(pool.allocPoint).to.equal(200);
    });
  });

  describe("Staking", function () {
    beforeEach(async function () {
      await magnetaFarm.addPool(await lpToken.getAddress(), 100, false, false);
    });

    it("Should allow user to deposit LP tokens", async function () {
      const amount = ethers.parseEther("100");
      await lpToken.connect(user).approve(await magnetaFarm.getAddress(), amount);

      const tx = await magnetaFarm.connect(user).deposit(0, amount);

      await expect(tx)
        .to.emit(magnetaFarm, "Deposit")
        .withArgs(user.address, 0, amount);

      const userInfo = await magnetaFarm.userInfo(0, user.address);
      expect(userInfo.amount).to.equal(amount);
    });

    it("Should allow user to withdraw LP tokens", async function () {
      const depositAmount = ethers.parseEther("100");
      await lpToken.connect(user).approve(await magnetaFarm.getAddress(), depositAmount);
      await magnetaFarm.connect(user).deposit(0, depositAmount);

      const withdrawAmount = ethers.parseEther("50");
      const tx = await magnetaFarm.connect(user).withdraw(0, withdrawAmount);

      await expect(tx)
        .to.emit(magnetaFarm, "Withdraw")
        .withArgs(user.address, 0, withdrawAmount);

      const userInfo = await magnetaFarm.userInfo(0, user.address);
      expect(userInfo.amount).to.equal(depositAmount - withdrawAmount);
    });
  });

  describe("Rewards", function () {
    beforeEach(async function () {
      await magnetaFarm.addPool(await lpToken.getAddress(), 100, false, false);
      const amount = ethers.parseEther("100");
      await lpToken.connect(user).approve(await magnetaFarm.getAddress(), amount);
      await magnetaFarm.connect(user).deposit(0, amount);
    });

    it("Should accumulate rewards over time", async function () {
      // Mine some blocks
      for (let i = 0; i < 10; i++) {
        await ethers.provider.send("evm_mine", []);
      }

      const pending = await magnetaFarm.pendingRewards(0, user.address);
      expect(pending).to.be.gt(0);
    });

    it("Should allow user to claim rewards", async function () {
      // Mine some blocks
      for (let i = 0; i < 10; i++) {
        await ethers.provider.send("evm_mine", []);
      }

      const tx = await magnetaFarm.connect(user).claimRewards(0);

      await expect(tx).to.emit(magnetaFarm, "RewardClaimed");
    });
  });
});

