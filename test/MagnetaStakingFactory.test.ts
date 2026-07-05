import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaStakingFactory, MagnetaStakingRewards, MockERC20 } from "../typechain-types";

describe("MagnetaStakingFactory", function () {
  let factory: MagnetaStakingFactory;
  let stakingToken: MockERC20;
  let rewardsToken: MockERC20;
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let feeVault: SignerWithAddress;
  let creator: SignerWithAddress;

  beforeEach(async function () {
    [owner, alice, feeVault, creator] = await ethers.getSigners();

    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    stakingToken = await MockERC20Factory.deploy("Stake Token", "STK", 18, ethers.parseEther("1000000"));
    rewardsToken = await MockERC20Factory.deploy("Reward Token", "RWD", 18, ethers.parseEther("1000000"));

    const FactoryFactory = await ethers.getContractFactory("MagnetaStakingFactory");
    factory = await FactoryFactory.deploy(feeVault.address, owner.address);
  });

  describe("Deployment", function () {
    it("sets the right owner and feeVault", async function () {
      expect(await factory.owner()).to.equal(owner.address);
      expect(await factory.feeVault()).to.equal(feeVault.address);
      expect(await factory.createFee()).to.equal(0);
    });

    it("rejects a zero feeVault or zero owner", async function () {
      const F = await ethers.getContractFactory("MagnetaStakingFactory");
      await expect(F.deploy(ethers.ZeroAddress, owner.address)).to.be.revertedWith("zero address");
      await expect(F.deploy(feeVault.address, ethers.ZeroAddress)).to.be.revertedWith("zero address");
    });
  });

  describe("createStakingPool", function () {
    it("deploys a pool owned by the creator and records it", async function () {
      const tx = await factory
        .connect(creator)
        .createStakingPool(await stakingToken.getAddress(), await rewardsToken.getAddress());

      await expect(tx).to.emit(factory, "StakingPoolCreated");

      expect(await factory.getPoolCount()).to.equal(1);
      const pools = await factory.getUserPools(creator.address);
      expect(pools.length).to.equal(1);

      const poolAddress = pools[0];
      expect(await factory.allPools(0)).to.equal(poolAddress);

      const pool = (await ethers.getContractAt(
        "MagnetaStakingRewards",
        poolAddress
      )) as MagnetaStakingRewards;
      expect(await pool.owner()).to.equal(creator.address);
      expect(await pool.stakingToken()).to.equal(await stakingToken.getAddress());
      expect(await pool.rewardsToken()).to.equal(await rewardsToken.getAddress());
    });

    it("reverts when msg.value is below createFee", async function () {
      await factory.setCreateFee(ethers.parseEther("0.01"));
      await expect(
        factory
          .connect(creator)
          .createStakingPool(await stakingToken.getAddress(), await rewardsToken.getAddress())
      ).to.be.revertedWith("insufficient fee");
    });

    it("forwards the fee to feeVault and refunds any excess", async function () {
      const fee = ethers.parseEther("0.01");
      await factory.setCreateFee(fee);

      const vaultBalBefore = await ethers.provider.getBalance(feeVault.address);
      const overpay = fee + ethers.parseEther("0.005");

      await factory
        .connect(creator)
        .createStakingPool(await stakingToken.getAddress(), await rewardsToken.getAddress(), {
          value: overpay,
        });

      const vaultBalAfter = await ethers.provider.getBalance(feeVault.address);
      expect(vaultBalAfter - vaultBalBefore).to.equal(fee);
    });

    it("reverts while paused", async function () {
      await factory.pause();
      await expect(
        factory
          .connect(creator)
          .createStakingPool(await stakingToken.getAddress(), await rewardsToken.getAddress())
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  describe("Owner setters", function () {
    it("setCreateFee is owner-only and emits an event", async function () {
      await expect(factory.connect(creator).setCreateFee(1)).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
      await expect(factory.setCreateFee(ethers.parseEther("0.02")))
        .to.emit(factory, "CreateFeeUpdated")
        .withArgs(0, ethers.parseEther("0.02"));
    });

    it("setFeeVault rejects the zero address", async function () {
      await expect(factory.setFeeVault(ethers.ZeroAddress)).to.be.revertedWith("zero vault");
    });
  });

  describe("Pause / multi-pauser", function () {
    it("lets an owner-added pauser pause but not unpause", async function () {
      await factory.addPauser(alice.address);
      expect(await factory.isPauser(alice.address)).to.be.true;

      await factory.connect(alice).pause();
      expect(await factory.paused()).to.be.true;

      await expect(factory.connect(alice).unpause()).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
      await factory.unpause();
      expect(await factory.paused()).to.be.false;
    });

    it("removePauser revokes the pause right", async function () {
      await factory.addPauser(alice.address);
      await factory.removePauser(alice.address);
      expect(await factory.isPauser(alice.address)).to.be.false;

      await expect(factory.connect(alice).pause()).to.be.revertedWith(
        "MagnetaStakingFactory: not owner or pauser"
      );
    });

    it("rejects non-owner/non-pauser calls to pause", async function () {
      await expect(factory.connect(creator).pause()).to.be.revertedWith(
        "MagnetaStakingFactory: not owner or pauser"
      );
    });
  });

  describe("Ownable2Step", function () {
    it("requires acceptOwnership before the transfer takes effect", async function () {
      await factory.transferOwnership(alice.address);
      expect(await factory.owner()).to.equal(owner.address);
      expect(await factory.pendingOwner()).to.equal(alice.address);

      await expect(
        factory.connect(alice).setCreateFee(ethers.parseEther("0.01"))
      ).to.be.revertedWith("Ownable: caller is not the owner");

      await factory.connect(alice).acceptOwnership();
      expect(await factory.owner()).to.equal(alice.address);
      expect(await factory.pendingOwner()).to.equal(ethers.ZeroAddress);

      await expect(factory.connect(alice).setCreateFee(ethers.parseEther("0.01"))).to.not.be.reverted;
    });
  });
});
