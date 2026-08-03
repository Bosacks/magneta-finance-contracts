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

  describe("Graduation gate is a monotonic high-water mark (F84)", function () {
    it("buy() raises the gate and sell() never lowers it", async function () {
      await pool.connect(alice).buy(0, { value: ethers.parseEther("40") });
      const gateAfterBuy: bigint = await pool.peakNativeRaised();
      const raisedAfterBuy: bigint = await pool.nativeRaised();
      expect(gateAfterBuy).to.equal(raisedAfterBuy);
      expect(gateAfterBuy).to.be.gt(0n);

      // Sell part of the position back.
      const bal: bigint = await token.balanceOf(alice.address);
      await token.connect(alice).approve(await pool.getAddress(), bal);
      await pool.connect(alice).sell(bal / 2n, 0);

      // nativeRaised drops, the gate is unchanged (monotonic).
      expect(await pool.nativeRaised()).to.be.lt(raisedAfterBuy);
      expect(await pool.peakNativeRaised()).to.equal(gateAfterBuy);
    });

    it("a whale selling near the threshold CANNOT suppress graduation", async function () {
      // Buy past 95 ETH (net ~94), below the 100 ETH threshold → not graduated.
      await pool.connect(alice).buy(0, { value: ethers.parseEther("95") });
      const gate: bigint = await pool.peakNativeRaised();
      expect(await pool.graduated()).to.equal(false);

      // Whale dumps most of the position: net nativeRaised falls well below the
      // threshold, but the gate stays put.
      const bal: bigint = await token.balanceOf(alice.address);
      await token.connect(alice).approve(await pool.getAddress(), bal);
      await pool.connect(alice).sell((bal * 80n) / 100n, 0);
      expect(await pool.nativeRaised()).to.be.lt(GRAD_THRESH);
      expect(await pool.peakNativeRaised()).to.equal(gate);
      expect(await pool.graduated()).to.equal(false);

      // Buying the curve back above the threshold closes it. The gate cannot be
      // walked backwards by the dump, so the whale gained nothing by selling.
      await pool.connect(attacker).buy(0, { value: ethers.parseEther("120") });
      expect(await pool.peakNativeRaised()).to.be.gte(GRAD_THRESH);
      expect(await pool.graduated()).to.equal(true);
    });

    it("a buy/sell round-trip does NOT credit the gate (fee-only inflation)", async function () {
      // The old gate summed every buy leg and was never decremented, so a
      // round-trip fed it the full buy each time while only the ~2% round-trip
      // fee stayed in the pool. Ten 10-ETH round-trips would have put the gate
      // at ~100 ETH — the threshold — on a pool holding ~2 ETH.
      // (99% and not 100% per unwind: quoteSell rounds the payout up by a
      // wei-scale dust, so a full unwind trips the pool's own solvency guard.)
      const poolAddr = await pool.getAddress();
      for (let i = 0; i < 10; i++) {
        await pool.connect(alice).buy(0, { value: ethers.parseEther("10") });
        const held: bigint = await token.balanceOf(alice.address);
        await token.connect(alice).approve(poolAddr, held);
        await pool.connect(alice).sell((held * 99n) / 100n, 0);
      }

      // The gate stays near the single largest amount the pool ever held.
      expect(await pool.peakNativeRaised()).to.be.lte(ethers.parseEther("20"));
      expect(await pool.peakNativeRaised()).to.be.lt(GRAD_THRESH);
      expect(await pool.graduated()).to.equal(false);
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

    // Rewritten. The previous version of this test set up the grief, warped
    // past GRADUATION_RESCUE_DELAY, asserted that finalizeGraduation emitted
    // `GraduationForced`, and called that a pass. It never looked at a single
    // balance — and the balances were the whole story: that forced branch
    // deposited with amountTokenMin = amountETHMin = 0 into the attacker's
    // pair, so the raise went to whoever owned that pair or, when the pair's
    // ratio made the token side scarce, to the feeVault via the leftover
    // sweep. The forced branch no longer exists; the escape hatch is refund
    // mode, and the assertions below are on balances.
    it("H-1: a persistently griefed pair NEVER gets a zero-floor deposit, at any time", async function () {
      const wethAddr  = await weth.getAddress();
      const tokenAddr = await token.getAddress();
      const poolAddr  = await pool.getAddress();

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

      const raise: bigint = await pool.nativeRaised();
      const poolBefore: bigint = await ethers.provider.getBalance(poolAddr);
      const vaultBefore: bigint = await ethers.provider.getBalance(feeVault.address);

      // Within the delay it reverts (price band protected).
      await expect(pool.connect(attacker).finalizeGraduation())
        .to.be.revertedWithCustomError(pool, "PairRatioOutOfBand");

      // Past the delay it STILL reverts. This is the fix: the old code took
      // the forced branch here and emitted GraduationForced.
      const delay: bigint = await pool.GRADUATION_RESCUE_DELAY();
      await ethers.provider.send("evm_increaseTime", [Number(delay) + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(pool.connect(attacker).finalizeGraduation())
        .to.be.revertedWithCustomError(pool, "PairRatioOutOfBand");
      expect(await pool.graduationFinalized()).to.equal(false);

      // Nothing moved: the raise is still in the pool, the griefed pair still
      // holds only the attacker's 0.001 WETH, and the vault took nothing.
      expect(await ethers.provider.getBalance(poolAddr)).to.equal(poolBefore);
      expect(await ethers.provider.getBalance(poolAddr)).to.be.gte(raise);
      expect(await ethers.provider.getBalance(feeVault.address)).to.equal(vaultBefore);
      expect(await weth.balanceOf(pairAddr)).to.equal(ethers.parseEther("0.001"));
      expect(await pair.balanceOf(attacker.address)).to.equal(0n);
    });

    it("H-1 escape hatch: refund mode returns the raise to the buyers", async function () {
      const wethAddr  = await weth.getAddress();
      const tokenAddr = await token.getAddress();
      const poolAddr  = await pool.getAddress();

      await factory.connect(attacker).createPair(tokenAddr, wethAddr);
      const pairAddr: string = await factory.getPair(tokenAddr, wethAddr);
      const pair = await ethers.getContractAt(
        "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol:IUniswapV2Pair", pairAddr);

      // The attacker funds the grief out of his own buy, so the tokens he
      // parks in the pair are tokens he paid for. He keeps it small: the pot
      // is shared PRO RATA, and tokens he abandons in the pair are a share he
      // forfeits — his loss, but also a slice of the pot no one can claim.
      await pool.connect(attacker).buy(0, { value: ethers.parseEther("0.01") });
      const attackerTokens: bigint = await token.balanceOf(attacker.address);
      await token.connect(attacker).transfer(pairAddr, attackerTokens);
      await weth.connect(attacker).deposit({ value: ethers.parseEther("0.001") });
      await weth.connect(attacker).transfer(pairAddr, ethers.parseEther("0.001"));
      await pair.sync();

      await buyToGraduation(alice);

      const raise: bigint = await pool.nativeRaised();
      const vaultBefore: bigint = await ethers.provider.getBalance(feeVault.address);

      const delay: bigint = await pool.GRADUATION_RESCUE_DELAY();
      await ethers.provider.send("evm_increaseTime", [Number(delay) + 1]);
      await ethers.provider.send("evm_mine", []);

      // Permissionless — a bystander opens it. Two steps since report 21: the
      // out-of-band state must be observed in an EARLIER block, so skewing the
      // pair and liquidating the launch can no longer happen atomically.
      await pool.connect(owner).flagPairOutOfBand();
      await ethers.provider.send("evm_mine", []);
      await expect(pool.connect(owner).enterRefundMode())
        .to.emit(pool, "RefundModeEntered");
      expect(await pool.refundMode()).to.equal(true);
      expect(await pool.refundNativePot()).to.equal(raise);

      // Graduation is closed for good.
      await expect(pool.connect(attacker).finalizeGraduation())
        .to.be.revertedWithCustomError(pool, "AlreadyFinalized");

      // Alice redeems her whole position. Measured on the POOL's balance so
      // gas does not blur the number.
      const aliceTokens: bigint = await token.balanceOf(alice.address);
      await token.connect(alice).approve(poolAddr, aliceTokens);
      const quoted: bigint = await pool.connect(alice).claimRefund.staticCall(aliceTokens);
      const poolBefore: bigint = await ethers.provider.getBalance(poolAddr);
      await pool.connect(alice).claimRefund(aliceTokens);
      const poolAfter: bigint = await ethers.provider.getBalance(poolAddr);

      expect(poolBefore - poolAfter).to.equal(quoted);
      // Alice put in 150 ETH; 1% left as the trading fee at buy time and the
      // attacker's small position dilutes her slightly. She gets the rest back.
      expect(quoted).to.be.gt((ethers.parseEther("150") * 98n) / 100n);
      expect(await token.balanceOf(alice.address)).to.equal(0n);

      // No LP was ever created and the vault never touched the raise.
      expect(await pair.totalSupply()).to.equal(0n);
      expect(await ethers.provider.getBalance(feeVault.address)).to.equal(vaultBefore);

      // The attacker is out his 1 ETH buy plus the 0.001 WETH seed and holds
      // nothing redeemable: his tokens sit in the pair he donated to.
      expect(await token.balanceOf(attacker.address)).to.equal(0n);
      expect(await pair.balanceOf(attacker.address)).to.equal(0n);
    });

    it("refund mode is refused while graduation is still viable", async function () {
      await buyToGraduation(alice);

      // Before the delay.
      await expect(pool.connect(attacker).enterRefundMode())
        .to.be.revertedWithCustomError(pool, "RescueDelayNotElapsed");

      const delay: bigint = await pool.GRADUATION_RESCUE_DELAY();
      await ethers.provider.send("evm_increaseTime", [Number(delay) + 1]);
      await ethers.provider.send("evm_mine", []);

      // Pair is empty → finalizeGraduation would go through right now, so a
      // griefer cannot use refund mode to tear the launch down. The refusal
      // now lands on the observation, which is what judges viability.
      await expect(pool.connect(attacker).flagPairOutOfBand())
        .to.be.revertedWithCustomError(pool, "GraduationStillViable");

      // And the transition alone gets nowhere without one.
      await expect(pool.connect(attacker).enterRefundMode())
        .to.be.revertedWithCustomError(pool, "PairNotFlagged");

      await expect(pool.connect(attacker).finalizeGraduation()).to.emit(pool, "Graduated");
      expect(await pool.graduationFinalized()).to.equal(true);
    });
  });
});
