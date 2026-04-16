import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaSwap } from "../typechain-types";
import { MockERC20 } from "../typechain-types";

describe("MagnetaSwap", function () {
  let magnetaSwap: MagnetaSwap;
  let token0: MockERC20;
  let token1: MockERC20;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  let feeRecipient: SignerWithAddress;

  beforeEach(async function () {
    [owner, user, feeRecipient] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    token0 = await MockERC20Factory.deploy("Token0", "TKN0", 18, ethers.parseEther("1000000"));
    token1 = await MockERC20Factory.deploy("Token1", "TKN1", 18, ethers.parseEther("1000000"));

    // Deploy MagnetaSwap
    const MagnetaSwapFactory = await ethers.getContractFactory("MagnetaSwap");
    magnetaSwap = await MagnetaSwapFactory.deploy(feeRecipient.address, owner.address);

    // Whitelist tokens
    await magnetaSwap.setWhitelistedToken(await token0.getAddress(), true);
    await magnetaSwap.setWhitelistedToken(await token1.getAddress(), true);

    // Transfer tokens to user
    await token0.transfer(user.address, ethers.parseEther("1000"));
    await token1.transfer(user.address, ethers.parseEther("1000"));
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await magnetaSwap.owner()).to.equal(owner.address);
    });

    it("Should set the right fee recipient", async function () {
      expect(await magnetaSwap.feeRecipient()).to.equal(feeRecipient.address);
    });

    it("Should have correct fee BPS", async function () {
      expect(await magnetaSwap.FEE_BPS()).to.equal(30); // 0.3%
    });
  });

  describe("Token Whitelisting", function () {
    it("Should allow owner to whitelist tokens", async function () {
      const newToken = await (await ethers.getContractFactory("MockERC20")).deploy(
        "NewToken",
        "NEW",
        18,
        ethers.parseEther("1000")
      );
      await magnetaSwap.setWhitelistedToken(await newToken.getAddress(), true);
      expect(await magnetaSwap.whitelistedTokens(await newToken.getAddress())).to.be.true;
    });

    it("Should not allow non-owner to whitelist tokens", async function () {
      const newToken = await (await ethers.getContractFactory("MockERC20")).deploy(
        "NewToken",
        "NEW",
        18,
        ethers.parseEther("1000")
      );
      await expect(
        magnetaSwap.connect(user).setWhitelistedToken(await newToken.getAddress(), true)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Swapping", function () {
    it("Should revert if token not whitelisted", async function () {
      const newToken = await (await ethers.getContractFactory("MockERC20")).deploy(
        "NewToken",
        "NEW",
        18,
        ethers.parseEther("1000")
      );
      await newToken.transfer(user.address, ethers.parseEther("100"));
      await newToken.connect(user).approve(await magnetaSwap.getAddress(), ethers.parseEther("100"));

      await expect(
        magnetaSwap
          .connect(user)
          .swap(
            await newToken.getAddress(),
            await token1.getAddress(),
            ethers.parseEther("10"),
            ethers.parseEther("9"),
            user.address,
            (await ethers.provider.getBlock("latest"))!.timestamp + 3600
          )
      ).to.be.revertedWith("MagnetaSwap: token not whitelisted");
    });

    it("Should revert if contract is paused", async function () {
      await magnetaSwap.pause();
      await token0.connect(user).approve(await magnetaSwap.getAddress(), ethers.parseEther("100"));

      await expect(
        magnetaSwap
          .connect(user)
          .swap(
            await token0.getAddress(),
            await token1.getAddress(),
            ethers.parseEther("10"),
            ethers.parseEther("9"),
            user.address,
            (await ethers.provider.getBlock("latest"))!.timestamp + 3600
          )
      ).to.be.revertedWith("MagnetaSwap: paused");
    });
  });

  describe("Fee Management", function () {
    it("Should allow owner to update fee recipient", async function () {
      const newFeeRecipient = (await ethers.getSigners())[3];
      await magnetaSwap.setFeeRecipient(newFeeRecipient.address);
      expect(await magnetaSwap.feeRecipient()).to.equal(newFeeRecipient.address);
    });

    it("Should not allow non-owner to update fee recipient", async function () {
      await expect(
        magnetaSwap.connect(user).setFeeRecipient(user.address)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Pause/Unpause", function () {
    it("Should allow owner to pause", async function () {
      await magnetaSwap.pause();
      expect(await magnetaSwap.paused()).to.be.true;
    });

    it("Should allow owner to unpause", async function () {
      await magnetaSwap.pause();
      await magnetaSwap.unpause();
      expect(await magnetaSwap.paused()).to.be.false;
    });

    it("Should not allow non-owner to pause", async function () {
      await expect(magnetaSwap.connect(user).pause()).to.be.revertedWith(
        "Ownable: caller is not the owner"
      );
    });
  });
});

