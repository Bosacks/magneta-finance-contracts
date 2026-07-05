import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaMasterChef, MockERC20 } from "../typechain-types";

describe("MagnetaMasterChef", function () {
  let chef: MagnetaMasterChef;
  let rewardsToken: MockERC20;
  let lpToken: MockERC20;
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let user: SignerWithAddress;

  const REWARDS_PER_SECOND = ethers.parseEther("0.01");
  let endTime: number;

  beforeEach(async function () {
    [owner, alice, user] = await ethers.getSigners();

    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    rewardsToken = await MockERC20Factory.deploy("Reward Token", "RWD", 18, ethers.parseEther("1000000"));
    lpToken = await MockERC20Factory.deploy("LP Token", "LP", 18, ethers.parseEther("1000000"));

    const latestBlock = await ethers.provider.getBlock("latest");
    endTime = latestBlock!.timestamp + 30 * 24 * 60 * 60; // 30 days out

    const ChefFactory = await ethers.getContractFactory("MagnetaMasterChef");
    chef = await ChefFactory.deploy(
      owner.address,
      await rewardsToken.getAddress(),
      REWARDS_PER_SECOND,
      endTime
    );

    // Fund the farm with reward tokens for payouts.
    await rewardsToken.transfer(await chef.getAddress(), ethers.parseEther("100000"));

    // Give the user LP tokens to farm with.
    await lpToken.transfer(user.address, ethers.parseEther("1000"));
  });

  describe("Pool management", function () {
    it("allows the owner to add a pool", async function () {
      const tx = await chef.addPool(100, await lpToken.getAddress(), false);
      await expect(tx).to.emit(chef, "PoolAdded").withArgs(0, await lpToken.getAddress(), 100);
      expect(await chef.poolLength()).to.equal(1);
    });

    it("rejects a non-owner adding a pool", async function () {
      await expect(
        chef.connect(user).addPool(100, await lpToken.getAddress(), false)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("rejects a duplicate lpToken pool", async function () {
      await chef.addPool(100, await lpToken.getAddress(), false);
      await expect(chef.addPool(50, await lpToken.getAddress(), false)).to.be.revertedWith("dup pool");
    });
  });

  describe("Deposit / pending rewards / withdraw", function () {
    beforeEach(async function () {
      await chef.addPool(100, await lpToken.getAddress(), false);
      await lpToken.connect(user).approve(await chef.getAddress(), ethers.parseEther("1000"));
    });

    it("allows a user to deposit LP tokens", async function () {
      const amount = ethers.parseEther("100");
      const tx = await chef.connect(user).deposit(0, amount);
      await expect(tx).to.emit(chef, "Deposit").withArgs(user.address, 0, amount);

      const info = await chef.userInfo(0, user.address);
      expect(info.amount).to.equal(amount);

      const pool = await chef.poolInfo(0);
      expect(pool.totalStaked).to.equal(amount);
    });

    it("accrues pending rewards over time", async function () {
      await chef.connect(user).deposit(0, ethers.parseEther("100"));

      await ethers.provider.send("evm_increaseTime", [100]);
      await ethers.provider.send("evm_mine", []);

      const pending = await chef.pendingReward(0, user.address);
      expect(pending).to.be.gt(0);
    });

    it("pays out pending rewards and reduces stake on withdraw", async function () {
      const amount = ethers.parseEther("100");
      await chef.connect(user).deposit(0, amount);

      await ethers.provider.send("evm_increaseTime", [100]);
      await ethers.provider.send("evm_mine", []);

      const rewardBalBefore = await rewardsToken.balanceOf(user.address);
      const withdrawAmount = ethers.parseEther("40");
      const tx = await chef.connect(user).withdraw(0, withdrawAmount);
      await expect(tx).to.emit(chef, "Withdraw").withArgs(user.address, 0, withdrawAmount);

      const info = await chef.userInfo(0, user.address);
      expect(info.amount).to.equal(amount - withdrawAmount);
      expect(await rewardsToken.balanceOf(user.address)).to.be.gt(rewardBalBefore);
    });

    it("harvests via withdraw(pid, 0) without touching the stake", async function () {
      const amount = ethers.parseEther("100");
      await chef.connect(user).deposit(0, amount);

      await ethers.provider.send("evm_increaseTime", [100]);
      await ethers.provider.send("evm_mine", []);

      const rewardBalBefore = await rewardsToken.balanceOf(user.address);
      await chef.connect(user).withdraw(0, 0);

      const info = await chef.userInfo(0, user.address);
      expect(info.amount).to.equal(amount);
      expect(await rewardsToken.balanceOf(user.address)).to.be.gt(rewardBalBefore);
    });

    it("emergencyWithdraw returns the stake and zeroes the user's position", async function () {
      const amount = ethers.parseEther("100");
      await chef.connect(user).deposit(0, amount);

      const lpBalBefore = await lpToken.balanceOf(user.address);
      const tx = await chef.connect(user).emergencyWithdraw(0);
      await expect(tx).to.emit(chef, "EmergencyWithdraw").withArgs(user.address, 0, amount);

      const info = await chef.userInfo(0, user.address);
      expect(info.amount).to.equal(0);
      expect(await lpToken.balanceOf(user.address)).to.equal(lpBalBefore + amount);
    });
  });

  describe("Pause / multi-pauser", function () {
    beforeEach(async function () {
      await chef.addPool(100, await lpToken.getAddress(), false);
      await lpToken.connect(user).approve(await chef.getAddress(), ethers.parseEther("1000"));
    });

    it("blocks deposit while paused", async function () {
      await chef.pause();
      await expect(chef.connect(user).deposit(0, ethers.parseEther("100"))).to.be.revertedWith(
        "Pausable: paused"
      );
    });

    it("still allows withdraw and emergencyWithdraw while paused", async function () {
      const amount = ethers.parseEther("100");
      await chef.connect(user).deposit(0, amount);

      await chef.pause();
      expect(await chef.paused()).to.be.true;

      await expect(chef.connect(user).withdraw(0, ethers.parseEther("10"))).to.not.be.reverted;
      await expect(chef.connect(user).emergencyWithdraw(0)).to.not.be.reverted;
    });

    it("still allows harvest via withdraw(pid, 0) while paused", async function () {
      const amount = ethers.parseEther("100");
      await chef.connect(user).deposit(0, amount);
      await ethers.provider.send("evm_increaseTime", [100]);
      await ethers.provider.send("evm_mine", []);

      await chef.pause();
      await expect(chef.connect(user).withdraw(0, 0)).to.not.be.reverted;
    });

    it("lets an owner-added pauser pause but not unpause", async function () {
      await chef.addPauser(alice.address);
      expect(await chef.isPauser(alice.address)).to.be.true;

      await chef.connect(alice).pause();
      expect(await chef.paused()).to.be.true;

      await expect(chef.connect(alice).unpause()).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
      await chef.unpause();
      expect(await chef.paused()).to.be.false;
    });

    it("removePauser revokes the pause right", async function () {
      await chef.addPauser(alice.address);
      await chef.removePauser(alice.address);
      expect(await chef.isPauser(alice.address)).to.be.false;

      await expect(chef.connect(alice).pause()).to.be.revertedWith(
        "MagnetaMasterChef: not owner or pauser"
      );
    });
  });

  describe("Ownable2Step", function () {
    it("requires acceptOwnership before the transfer takes effect", async function () {
      await chef.transferOwnership(alice.address);
      expect(await chef.owner()).to.equal(owner.address);
      expect(await chef.pendingOwner()).to.equal(alice.address);

      await expect(
        chef.connect(alice).setRewardsPerSecond(REWARDS_PER_SECOND)
      ).to.be.revertedWith("Ownable: caller is not the owner");

      await chef.connect(alice).acceptOwnership();
      expect(await chef.owner()).to.equal(alice.address);
      expect(await chef.pendingOwner()).to.equal(ethers.ZeroAddress);

      await expect(chef.connect(alice).setRewardsPerSecond(REWARDS_PER_SECOND)).to.not.be.reverted;
    });
  });
});
