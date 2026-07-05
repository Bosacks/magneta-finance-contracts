import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaStakingRewards, MockERC20 } from "../typechain-types";

describe("MagnetaStakingRewards", function () {
  let staking: MagnetaStakingRewards;
  let stakingToken: MockERC20;
  let rewardsToken: MockERC20;
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let user: SignerWithAddress;

  const REWARD_FUND = ethers.parseEther("100000");

  beforeEach(async function () {
    [owner, alice, user] = await ethers.getSigners();

    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    stakingToken = await MockERC20Factory.deploy("Stake Token", "STK", 18, ethers.parseEther("1000000"));
    rewardsToken = await MockERC20Factory.deploy("Reward Token", "RWD", 18, ethers.parseEther("1000000"));

    const StakingFactory = await ethers.getContractFactory("MagnetaStakingRewards");
    staking = await StakingFactory.deploy(
      owner.address,
      await stakingToken.getAddress(),
      await rewardsToken.getAddress()
    );

    // Fund the user with staking tokens.
    await stakingToken.transfer(user.address, ethers.parseEther("1000"));

    // Fund the pool with reward tokens for payouts.
    await rewardsToken.transfer(await staking.getAddress(), REWARD_FUND);
  });

  describe("Deployment", function () {
    it("sets the right owner and tokens", async function () {
      expect(await staking.owner()).to.equal(owner.address);
      expect(await staking.stakingToken()).to.equal(await stakingToken.getAddress());
      expect(await staking.rewardsToken()).to.equal(await rewardsToken.getAddress());
    });
  });

  describe("Staking / withdraw / reward happy paths", function () {
    it("allows a user to stake", async function () {
      const amount = ethers.parseEther("100");
      await stakingToken.connect(user).approve(await staking.getAddress(), amount);

      const tx = await staking.connect(user).stake(amount);
      await expect(tx).to.emit(staking, "Staked").withArgs(user.address, amount);

      expect(await staking.balanceOf(user.address)).to.equal(amount);
      expect(await staking.totalSupply()).to.equal(amount);
    });

    it("reverts staking a zero amount", async function () {
      await expect(staking.connect(user).stake(0)).to.be.revertedWith("zero amount");
    });

    it("accrues rewards over time after notifyRewardAmount funding", async function () {
      const stakeAmount = ethers.parseEther("100");
      await stakingToken.connect(user).approve(await staking.getAddress(), stakeAmount);
      await staking.connect(user).stake(stakeAmount);

      const rewardAmount = ethers.parseEther("3000"); // 30 days * ~100/day, well within REWARD_FUND
      const tx = await staking.notifyRewardAmount(rewardAmount);
      await expect(tx).to.emit(staking, "RewardAdded");

      await ethers.provider.send("evm_increaseTime", [3600]); // 1 hour
      await ethers.provider.send("evm_mine", []);

      const earned = await staking.earned(user.address);
      expect(earned).to.be.gt(0);
    });

    it("allows a user to withdraw part of their stake", async function () {
      const stakeAmount = ethers.parseEther("100");
      await stakingToken.connect(user).approve(await staking.getAddress(), stakeAmount);
      await staking.connect(user).stake(stakeAmount);

      const withdrawAmount = ethers.parseEther("40");
      const tx = await staking.connect(user).withdraw(withdrawAmount);
      await expect(tx).to.emit(staking, "Withdrawn").withArgs(user.address, withdrawAmount);

      expect(await staking.balanceOf(user.address)).to.equal(stakeAmount - withdrawAmount);
      expect(await stakingToken.balanceOf(user.address)).to.equal(
        ethers.parseEther("1000") - stakeAmount + withdrawAmount
      );
    });

    it("allows a user to claim accumulated rewards via getReward", async function () {
      const stakeAmount = ethers.parseEther("100");
      await stakingToken.connect(user).approve(await staking.getAddress(), stakeAmount);
      await staking.connect(user).stake(stakeAmount);

      await staking.notifyRewardAmount(ethers.parseEther("3000"));
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine", []);

      const before = await rewardsToken.balanceOf(user.address);
      await expect(staking.connect(user).getReward()).to.emit(staking, "RewardPaid");
      const after = await rewardsToken.balanceOf(user.address);
      expect(after).to.be.gt(before);
    });

    it("exit() withdraws the full stake and claims rewards in one tx", async function () {
      const stakeAmount = ethers.parseEther("100");
      await stakingToken.connect(user).approve(await staking.getAddress(), stakeAmount);
      await staking.connect(user).stake(stakeAmount);

      await staking.notifyRewardAmount(ethers.parseEther("3000"));
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine", []);

      const rewardBalBefore = await rewardsToken.balanceOf(user.address);
      const stakeBalBefore = await stakingToken.balanceOf(user.address);

      await staking.connect(user).exit();

      expect(await staking.balanceOf(user.address)).to.equal(0);
      expect(await stakingToken.balanceOf(user.address)).to.equal(stakeBalBefore + stakeAmount);
      expect(await rewardsToken.balanceOf(user.address)).to.be.gt(rewardBalBefore);
    });
  });

  describe("notifyRewardAmount funding", function () {
    it("sets rewardRate and periodFinish", async function () {
      const rewardAmount = ethers.parseEther("3000");
      await staking.notifyRewardAmount(rewardAmount);

      const duration = await staking.rewardsDuration();
      expect(await staking.rewardRate()).to.equal(rewardAmount / duration);
      expect(await staking.periodFinish()).to.be.gt(0);
    });

    it("reverts when the reward exceeds the funded balance", async function () {
      // Contract holds REWARD_FUND; ask for far more than that.
      await expect(
        staking.notifyRewardAmount(REWARD_FUND * 10n)
      ).to.be.revertedWith("reward > balance");
    });

    it("is owner-only", async function () {
      await expect(
        staking.connect(user).notifyRewardAmount(ethers.parseEther("100"))
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Pause / multi-pauser", function () {
    it("stake reverts when paused", async function () {
      await staking.pause();
      await stakingToken.connect(user).approve(await staking.getAddress(), ethers.parseEther("100"));
      await expect(staking.connect(user).stake(ethers.parseEther("100"))).to.be.revertedWith(
        "Pausable: paused"
      );
    });

    it("withdraw, getReward and exit still work while paused", async function () {
      const stakeAmount = ethers.parseEther("100");
      await stakingToken.connect(user).approve(await staking.getAddress(), stakeAmount);
      await staking.connect(user).stake(stakeAmount);
      await staking.notifyRewardAmount(ethers.parseEther("3000"));
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine", []);

      await staking.pause();
      expect(await staking.paused()).to.be.true;

      await expect(staking.connect(user).withdraw(ethers.parseEther("10"))).to.not.be.reverted;
      await expect(staking.connect(user).getReward()).to.not.be.reverted;
      await expect(staking.connect(user).exit()).to.not.be.reverted;
    });

    it("lets an owner-added pauser pause but not unpause", async function () {
      await staking.addPauser(alice.address);
      expect(await staking.isPauser(alice.address)).to.be.true;

      await staking.connect(alice).pause();
      expect(await staking.paused()).to.be.true;

      await expect(staking.connect(alice).unpause()).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
      await staking.unpause();
      expect(await staking.paused()).to.be.false;
    });

    it("removePauser revokes the pause right", async function () {
      await staking.addPauser(alice.address);
      await staking.removePauser(alice.address);
      expect(await staking.isPauser(alice.address)).to.be.false;

      await expect(staking.connect(alice).pause()).to.be.revertedWith(
        "MagnetaStakingRewards: not owner or pauser"
      );
    });

    it("rejects non-owner/non-pauser calls to pause", async function () {
      await expect(staking.connect(user).pause()).to.be.revertedWith(
        "MagnetaStakingRewards: not owner or pauser"
      );
    });
  });

  describe("Ownable2Step", function () {
    it("requires acceptOwnership before the transfer takes effect", async function () {
      await staking.transferOwnership(alice.address);
      expect(await staking.owner()).to.equal(owner.address);
      expect(await staking.pendingOwner()).to.equal(alice.address);

      // Pending owner cannot act until they accept.
      await expect(
        staking.connect(alice).setRewardsDuration(60 * 60 * 24 * 7)
      ).to.be.revertedWith("Ownable: caller is not the owner");

      await staking.connect(alice).acceptOwnership();
      expect(await staking.owner()).to.equal(alice.address);
      expect(await staking.pendingOwner()).to.equal(ethers.ZeroAddress);

      // New owner can now act.
      await expect(staking.connect(alice).setRewardsDuration(60 * 60 * 24 * 7)).to.not.be.reverted;
    });
  });
});
