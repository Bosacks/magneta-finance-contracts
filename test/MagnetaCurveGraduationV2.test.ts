import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Validation tests for the graduation-DoS fix (Sentinelle F-1, 2026-06-22).
 *
 * New model:
 *   - buy()/graduate() only CLOSE the curve (set `graduated`, emit
 *     GraduationReady). They no longer migrate liquidity, so a pre-seeded /
 *     dust-griefed V2 pair can never make a trade or graduation revert.
 *   - finalizeGraduation() is the separate, permissionless, retryable step
 *     that migrates liquidity and burns the LP. It tolerates a pre-existing
 *     pair with reserves (deposits at its ratio, mins = 0) instead of the old
 *     hard-revert that bricked graduation forever.
 *
 * The old MagnetaCurveGraduationSlippage.test.ts asserts the PRE-fix behavior
 * (revert on a seeded pair) and is therefore obsolete — it will be rewritten
 * when this fix is integrated into main.
 */
describe("MagnetaCurvePool — graduation DoS fix (finalizeGraduation)", function () {
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let attacker: SignerWithAddress;
  let feeVault: SignerWithAddress;

  let weth: any;
  let factory: any;
  let router: any;
  let curveFactory: any;
  let token: any;
  let pool: any;

  const TOTAL_SUPPLY = ethers.parseEther("1000000000");
  const CURVE_ALLOC  = ethers.parseEther("800000000");
  const VIRTUAL_RES  = ethers.parseEther("10");
  const GRAD_THRESH  = ethers.parseEther("100");
  const DEAD = "0x000000000000000000000000000000000000dEaD";

  beforeEach(async function () {
    [owner, alice, attacker, feeVault] = await ethers.getSigners();

    const WETH9 = await ethers.getContractFactory("WETH9");
    weth = await WETH9.deploy();
    await weth.waitForDeployment();

    const Factory = await ethers.getContractFactory("UniswapV2Factory");
    factory = await Factory.deploy(owner.address);
    await factory.waitForDeployment();

    const Router = await ethers.getContractFactory("MagnetaV2Router02");
    router = await Router.deploy(await factory.getAddress(), await weth.getAddress());
    await router.waitForDeployment();

    await factory.connect(owner).setFeeTo(feeVault.address);

    const CurveFactory = await ethers.getContractFactory("MagnetaCurveFactory");
    curveFactory = await CurveFactory.deploy(
      await router.getAddress(),
      feeVault.address,
      owner.address,
    );
    await curveFactory.waitForDeployment();

    const tx = await curveFactory.connect(alice).createCurveToken(
      "TestToken", "TEST", "ipfs://test",
      TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, GRAD_THRESH,
    );
    const receipt = await tx.wait();
    const event = receipt.logs.find((l: any) => {
      try { return curveFactory.interface.parseLog(l as any)?.name === "CurveTokenCreated"; }
      catch { return false; }
    });
    const parsed = curveFactory.interface.parseLog(event as any);
    token = await ethers.getContractAt("MagnetaCurveToken", parsed!.args.token);
    pool  = await ethers.getContractAt("MagnetaCurvePool",  parsed!.args.pool);
  });

  function buyToGraduation(buyer: SignerWithAddress) {
    return pool.connect(buyer).buy(0, { value: ethers.parseEther("150") });
  }

  describe("Curve close vs LP migration are separated", function () {
    it("buy() crossing threshold closes the curve but does NOT migrate", async function () {
      await expect(buyToGraduation(alice)).to.emit(pool, "GraduationReady");

      expect(await pool.graduated()).to.equal(true);
      expect(await pool.graduationFinalized()).to.equal(false);

      // No liquidity migrated yet → pair either absent or empty.
      const pairAddr: string = await factory.getPair(
        await token.getAddress(), await weth.getAddress(),
      );
      if (pairAddr !== ethers.ZeroAddress) {
        const pair = await ethers.getContractAt(
          "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol:IUniswapV2Pair", pairAddr);
        const [r0, r1]: [bigint, bigint] = await pair.getReserves();
        expect(r0 === 0n && r1 === 0n).to.equal(true);
      }
    });

    it("finalizeGraduation() migrates into a fresh pair and burns LP at DEAD", async function () {
      await buyToGraduation(alice);
      await expect(pool.connect(attacker).finalizeGraduation()).to.emit(pool, "Graduated");

      expect(await pool.graduationFinalized()).to.equal(true);

      const pairAddr: string = await factory.getPair(
        await token.getAddress(), await weth.getAddress(),
      );
      expect(pairAddr).to.not.equal(ethers.ZeroAddress);
      const pair = await ethers.getContractAt(
        "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol:IUniswapV2Pair", pairAddr);
      expect(await pair.balanceOf(DEAD)).to.be.gt(0n);
    });
  });

  describe("Guards", function () {
    it("finalizeGraduation reverts before the curve has closed", async function () {
      await expect(pool.connect(alice).finalizeGraduation())
        .to.be.revertedWithCustomError(pool, "NotReadyToGraduate");
    });

    it("finalizeGraduation reverts on a second call", async function () {
      await buyToGraduation(alice);
      await pool.connect(attacker).finalizeGraduation();
      await expect(pool.connect(attacker).finalizeGraduation())
        .to.be.revertedWithCustomError(pool, "AlreadyFinalized");
    });
  });

  describe("Graduation gate is monotonic (F84)", function () {
    it("buy() increments totalNativeBought and never decrements it on sell()", async function () {
      await pool.connect(alice).buy(0, { value: ethers.parseEther("40") });
      const boughtAfterBuy: bigint = await pool.totalNativeBought();
      const raisedAfterBuy: bigint = await pool.nativeRaised();
      expect(boughtAfterBuy).to.equal(raisedAfterBuy);
      expect(boughtAfterBuy).to.be.gt(0n);

      // Sell part of the position back.
      const bal: bigint = await token.balanceOf(alice.address);
      await token.connect(alice).approve(await pool.getAddress(), bal);
      await pool.connect(alice).sell(bal / 2n, 0);

      // nativeRaised drops, totalNativeBought is unchanged (monotonic).
      expect(await pool.nativeRaised()).to.be.lt(raisedAfterBuy);
      expect(await pool.totalNativeBought()).to.equal(boughtAfterBuy);
    });

    it("a whale selling near the threshold CANNOT suppress graduation", async function () {
      // Buy past 95 ETH (net ~94), below the 100 ETH threshold → not graduated.
      await pool.connect(alice).buy(0, { value: ethers.parseEther("95") });
      expect(await pool.graduated()).to.equal(false);

      // Whale dumps most of the position: net nativeRaised falls well below the
      // threshold, but totalNativeBought stays put.
      const bal: bigint = await token.balanceOf(alice.address);
      await token.connect(alice).approve(await pool.getAddress(), bal);
      await pool.connect(alice).sell((bal * 80n) / 100n, 0);
      expect(await pool.nativeRaised()).to.be.lt(GRAD_THRESH);
      expect(await pool.graduated()).to.equal(false);

      // A further buy pushes cumulative buy-side native past the threshold even
      // though net nativeRaised is still below it. Under the OLD net-based gate
      // this buy would NOT graduate; under the monotonic gate it does (F84).
      await pool.connect(attacker).buy(0, { value: ethers.parseEther("10") });
      expect(await pool.totalNativeBought()).to.be.gte(GRAD_THRESH);
      expect(await pool.graduated()).to.equal(true);
    });
  });

  describe("DoS resistance — the actual CRITICAL fix", function () {
    it("Pre-seeded (dust-griefed) V2 pair does NOT brick trading; finalize rejects bad ratio (F82)", async function () {
      const wethAddr  = await weth.getAddress();
      const tokenAddr = await token.getAddress();

      // Attacker pre-creates the pair and seeds a bad ratio with dust.
      await factory.connect(attacker).createPair(tokenAddr, wethAddr);
      const pairAddr: string = await factory.getPair(tokenAddr, wethAddr);
      const pair = await ethers.getContractAt(
        "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol:IUniswapV2Pair", pairAddr);

      // Get some curve tokens to seed the token side, set an absurd ratio.
      await pool.connect(alice).buy(0, { value: ethers.parseEther("1") });
      const aliceBal: bigint = await token.balanceOf(alice.address);
      await token.connect(alice).transfer(pairAddr, aliceBal);
      await weth.connect(attacker).deposit({ value: ethers.parseEther("0.001") });
      await weth.connect(attacker).transfer(pairAddr, ethers.parseEther("0.001"));
      await pair.sync();

      const [r0, r1]: [bigint, bigint] = await pair.getReserves();
      expect(r0).to.be.gt(0n);
      expect(r1).to.be.gt(0n);

      // Trading still closes the curve cleanly — the seeded pair can never
      // brick buy()/graduate().
      await expect(buyToGraduation(alice)).to.not.be.reverted;
      expect(await pool.graduated()).to.equal(true);

      // F82: finalizeGraduation now REFUSES to deposit into a pair whose spot
      // ratio deviates from the curve terminal price beyond the band, rather
      // than seeding the V2 launch at the attacker's manipulated price. The
      // revert rolls back graduationFinalized, so the step stays retryable
      // (once the pair is arbed back within band it can complete).
      await expect(pool.connect(attacker).finalizeGraduation())
        .to.be.revertedWithCustomError(pool, "PairRatioOutOfBand");
      expect(await pool.graduationFinalized()).to.equal(false);
    });

    it("H-1: after GRADUATION_RESCUE_DELAY a persistently griefed pair no longer locks funds", async function () {
      const wethAddr  = await weth.getAddress();
      const tokenAddr = await token.getAddress();

      // Same grief setup: attacker pre-seeds an out-of-band pair.
      await factory.connect(attacker).createPair(tokenAddr, wethAddr);
      const pairAddr: string = await factory.getPair(tokenAddr, wethAddr);
      const pair = await ethers.getContractAt(
        "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol:IUniswapV2Pair", pairAddr);

      await pool.connect(alice).buy(0, { value: ethers.parseEther("1") });
      const aliceBal: bigint = await token.balanceOf(alice.address);
      await token.connect(alice).transfer(pairAddr, aliceBal);
      await weth.connect(attacker).deposit({ value: ethers.parseEther("0.001") });
      await weth.connect(attacker).transfer(pairAddr, ethers.parseEther("0.001"));
      await pair.sync();

      await buyToGraduation(alice);
      expect(await pool.graduated()).to.equal(true);

      // Within the delay it still reverts (price band protected).
      await expect(pool.connect(attacker).finalizeGraduation())
        .to.be.revertedWithCustomError(pool, "PairRatioOutOfBand");

      // Advance time past the rescue delay: migration now proceeds at the
      // prevailing (griefed) ratio instead of locking buyer funds forever.
      const delay: bigint = await pool.GRADUATION_RESCUE_DELAY();
      await ethers.provider.send("evm_increaseTime", [Number(delay) + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(pool.connect(attacker).finalizeGraduation())
        .to.emit(pool, "GraduationForced");
      expect(await pool.graduationFinalized()).to.equal(true);
    });
  });
});
