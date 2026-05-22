import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaBundler, MockV2Router, MockERC20, MockWETH } from "../typechain-types";

/**
 * V2-specific tests: verify that bundleSell and sellAndBundleBuy now forward
 * the service fee (msg.value) to feeRecipient. The functions used to be
 * non-payable in V1 and skipped fee collection entirely.
 */
describe("MagnetaBundler V2 — fee forwarding on sell paths", function () {
  let bundler: MagnetaBundler;
  let router: MockV2Router;
  let weth: MockWETH;
  let tokenA: MockERC20;
  let tokenB: MockERC20;
  let owner: SignerWithAddress;
  let feeRecipient: SignerWithAddress;
  let user: SignerWithAddress;

  const SERVICE_FEE = ethers.parseEther("0.001");

  beforeEach(async function () {
    [owner, feeRecipient, user] = await ethers.getSigners();

    const MockWETHFactory = await ethers.getContractFactory("MockWETH");
    weth = await MockWETHFactory.deploy();

    const MockV2RouterFactory = await ethers.getContractFactory("MockV2Router");
    router = await MockV2RouterFactory.deploy(await weth.getAddress());

    const BundlerFactory = await ethers.getContractFactory("MagnetaBundler");
    bundler = await BundlerFactory.deploy(await router.getAddress(), feeRecipient.address);

    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    tokenA = await MockERC20Factory.deploy("TokenA", "TKA", 18, ethers.parseEther("1000000"));
    tokenB = await MockERC20Factory.deploy("TokenB", "TKB", 18, ethers.parseEther("1000000"));

    // Pre-fund router with native (mock pays out ETH on tokens-for-ETH swaps)
    await owner.sendTransaction({ to: await router.getAddress(), value: ethers.parseEther("100") });

    // Fund user
    await tokenA.transfer(user.address, ethers.parseEther("1000"));
    await tokenB.transfer(user.address, ethers.parseEther("1000"));
  });

  describe("bundleSell", function () {
    it("Is payable and forwards msg.value to feeRecipient", async function () {
      const before = await ethers.provider.getBalance(feeRecipient.address);

      await tokenA.connect(user).approve(await bundler.getAddress(), ethers.parseEther("10"));

      await expect(
        bundler.connect(user).bundleSell(
          [await tokenA.getAddress()],
          [ethers.parseEther("10")],
          [0n],
          { value: SERVICE_FEE },
        ),
      )
        .to.emit(bundler, "FeeForwarded")
        .withArgs(feeRecipient.address, SERVICE_FEE);

      const after = await ethers.provider.getBalance(feeRecipient.address);
      expect(after - before).to.equal(SERVICE_FEE);
    });

    it("Still works with zero msg.value (backward compatible — no fee)", async function () {
      await tokenA.connect(user).approve(await bundler.getAddress(), ethers.parseEther("5"));

      // Should not emit FeeForwarded when value is 0
      const before = await ethers.provider.getBalance(feeRecipient.address);
      await bundler.connect(user).bundleSell(
        [await tokenA.getAddress()],
        [ethers.parseEther("5")],
        [0n],
        { value: 0 },
      );
      const after = await ethers.provider.getBalance(feeRecipient.address);
      expect(after).to.equal(before);
    });

    it("Reverts on arrays length mismatch (fee not retained by contract)", async function () {
      const balBefore = await ethers.provider.getBalance(await bundler.getAddress());
      await expect(
        bundler.connect(user).bundleSell(
          [await tokenA.getAddress(), await tokenB.getAddress()],
          [ethers.parseEther("1")],
          [0n],
          { value: SERVICE_FEE },
        ),
      ).to.be.revertedWith("Arrays length mismatch");
      // Contract still empty (whole tx reverted)
      expect(await ethers.provider.getBalance(await bundler.getAddress())).to.equal(balBefore);
    });
  });

  describe("sellAndBundleBuy", function () {
    it("Is payable and forwards msg.value to feeRecipient", async function () {
      const sellAmount = ethers.parseEther("10");
      await tokenA.connect(user).approve(await bundler.getAddress(), sellAmount);

      // Pre-fund router with tokenB so the buy leg has something to give
      await tokenB.transfer(await router.getAddress(), ethers.parseEther("100"));

      const before = await ethers.provider.getBalance(feeRecipient.address);

      await expect(
        bundler.connect(user).sellAndBundleBuy(
          await tokenA.getAddress(),
          sellAmount,
          0n,
          await tokenB.getAddress(),
          0n,
          [user.address],
          [ethers.parseEther("1")],
          { value: SERVICE_FEE },
        ),
      ).to.emit(bundler, "FeeForwarded").withArgs(feeRecipient.address, SERVICE_FEE);

      const after = await ethers.provider.getBalance(feeRecipient.address);
      expect(after - before).to.equal(SERVICE_FEE);
    });

    it("Reverts on arrays length mismatch", async function () {
      await expect(
        bundler.connect(user).sellAndBundleBuy(
          await tokenA.getAddress(),
          ethers.parseEther("1"),
          0n,
          await tokenB.getAddress(),
          0n,
          [user.address],
          [ethers.parseEther("1"), ethers.parseEther("1")],
          { value: SERVICE_FEE },
        ),
      ).to.be.revertedWith("Arrays length mismatch");
    });
  });

  describe("Hardening (MB-1/2/3/4/5)", function () {
    describe("MB-1/2: maxFeePerTx cap", function () {
      it("exposes a default cap of 1 ether", async function () {
        expect(await bundler.maxFeePerTx()).to.equal(ethers.parseEther("1"));
      });

      it("rejects msg.value above the cap in bundleSell (silent overpay protection)", async function () {
        await tokenA.connect(user).approve(await bundler.getAddress(), ethers.parseEther("10"));
        // Default cap = 1 ETH. Send 2 ETH = far above legitimate fees.
        await expect(
          bundler.connect(user).bundleSell(
            [await tokenA.getAddress()],
            [ethers.parseEther("10")],
            [0n],
            { value: ethers.parseEther("2") },
          ),
        ).to.be.revertedWith("MagnetaBundler: fee exceeds cap");
      });

      it("setMaxFeePerTx updates the cap and emits an event", async function () {
        await expect(bundler.setMaxFeePerTx(ethers.parseEther("5")))
          .to.emit(bundler, "MaxFeePerTxUpdated")
          .withArgs(ethers.parseEther("1"), ethers.parseEther("5"));
        expect(await bundler.maxFeePerTx()).to.equal(ethers.parseEther("5"));
      });

      it("setMaxFeePerTx rejects zero", async function () {
        await expect(
          bundler.setMaxFeePerTx(0n),
        ).to.be.revertedWith("MagnetaBundler: zero cap");
      });

      it("non-owner cannot adjust the cap", async function () {
        await expect(
          bundler.connect(user).setMaxFeePerTx(ethers.parseEther("5")),
        ).to.be.reverted;
      });
    });

    describe("MB-3: Ownable2Step migration", function () {
      it("transferOwnership now uses two-step flow (pending owner must accept)", async function () {
        await bundler.transferOwnership(user.address);
        // After step 1: owner unchanged, user is pendingOwner
        expect(await bundler.owner()).to.equal(owner.address);
        expect(await bundler.pendingOwner()).to.equal(user.address);

        // Step 2: user accepts → ownership transfers
        await bundler.connect(user).acceptOwnership();
        expect(await bundler.owner()).to.equal(user.address);
        expect(await bundler.pendingOwner()).to.equal(ethers.ZeroAddress);
      });
    });

    describe("MB-4: pause guardian", function () {
      it("guardian can pause (fast-path)", async function () {
        await bundler.setPauseGuardian(user.address);
        expect(await bundler.pauseGuardian()).to.equal(user.address);

        await bundler.connect(user).pause();
        expect(await bundler.paused()).to.equal(true);
      });

      it("guardian CANNOT unpause (owner-only)", async function () {
        await bundler.setPauseGuardian(user.address);
        await bundler.connect(user).pause();
        await expect(bundler.connect(user).unpause()).to.be.reverted;

        // Owner can unpause
        await bundler.unpause();
        expect(await bundler.paused()).to.equal(false);
      });

      it("setPauseGuardian emits PauseGuardianUpdated", async function () {
        await expect(bundler.setPauseGuardian(user.address))
          .to.emit(bundler, "PauseGuardianUpdated")
          .withArgs(ethers.ZeroAddress, user.address);
      });

      it("non-guardian non-owner cannot pause", async function () {
        await expect(
          bundler.connect(user).pause(),
        ).to.be.revertedWith("MagnetaBundler: not owner or guardian");
      });
    });

    describe("MB-5: rescueTokens zero-checks", function () {
      it("rejects zero token", async function () {
        await expect(
          bundler.rescueTokens(ethers.ZeroAddress, 1n),
        ).to.be.revertedWith("MagnetaBundler: zero token");
      });

      it("rejects zero amount", async function () {
        await expect(
          bundler.rescueTokens(await tokenA.getAddress(), 0n),
        ).to.be.revertedWith("MagnetaBundler: zero amount");
      });
    });
  });
});
