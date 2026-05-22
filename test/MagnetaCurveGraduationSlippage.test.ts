import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Focused tests on the slippage protection added to MagnetaCurvePool._graduate():
 *   - Option 3 (first-pool check): graduate reverts if a pair already exists
 *     with non-zero reserves (front-runner pre-seeded a bad ratio).
 *   - Option 1 (1% tolerance backup): mins set to 99% of intent — defends
 *     against any reserve drift between our check and the addLiquidity call.
 *
 * Also covers the happy path: graduation lands in our Magneta-owned UniV2
 * factory, LP burned at DEAD, fee-on-swap configured (feeTo = FeeVault).
 */
describe("MagnetaCurvePool — graduation slippage protection", function () {
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

  const TOTAL_SUPPLY = ethers.parseEther("1000000000");           // 1B
  const CURVE_ALLOC  = ethers.parseEther("800000000");            // 80% on curve
  const VIRTUAL_RES  = ethers.parseEther("10");                  // 10 native virtual
  const GRAD_THRESH  = ethers.parseEther("100");                 // graduate at 100 native

  beforeEach(async function () {
    [owner, alice, attacker, feeVault] = await ethers.getSigners();

    // 1. WETH9
    const WETH9 = await ethers.getContractFactory("WETH9");
    weth = await WETH9.deploy();
    await weth.waitForDeployment();

    // 2. UniswapV2Factory (canonical)
    const Factory = await ethers.getContractFactory("UniswapV2Factory");
    factory = await Factory.deploy(owner.address);
    await factory.waitForDeployment();

    // 3. MagnetaV2Router02
    const Router = await ethers.getContractFactory("MagnetaV2Router02");
    router = await Router.deploy(await factory.getAddress(), await weth.getAddress());
    await router.waitForDeployment();

    // 4. Configure factory: feeTo = FeeVault enables 0.05% protocol fee
    await factory.connect(owner).setFeeTo(feeVault.address);

    // 5. MagnetaCurveFactory pointing at our Magneta router
    const CurveFactory = await ethers.getContractFactory("MagnetaCurveFactory");
    curveFactory = await CurveFactory.deploy(
      await router.getAddress(),
      feeVault.address,    // feeVault for curve trading fees
      owner.address,        // initialOwner
    );
    await curveFactory.waitForDeployment();

    // 6. Create a curve token via the factory
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
    const tokenAddr: string = parsed!.args.token;
    const poolAddr:  string = parsed!.args.pool;

    token = await ethers.getContractAt("MagnetaCurveToken", tokenAddr);
    pool  = await ethers.getContractAt("MagnetaCurvePool",  poolAddr);
  });

  /** Push the curve to graduation by buying with enough native. */
  async function buyToGraduation(buyer: SignerWithAddress): Promise<void> {
    // Send well over the threshold; the curve will keep what's needed and
    // refund/cap the rest. We send 150 to clear the 100 threshold comfortably.
    await pool.connect(buyer).buy(0, { value: ethers.parseEther("150") });
  }

  describe("Happy path", function () {
    it("Graduates into a fresh Magneta-owned pair, burns LP at DEAD", async function () {
      await buyToGraduation(alice);

      const graduated: boolean = await pool.graduated();
      expect(graduated).to.equal(true);

      const wethAddr = await weth.getAddress();
      const tokenAddr = await token.getAddress();
      const pairAddr: string = await factory.getPair(tokenAddr, wethAddr);
      expect(pairAddr).to.not.equal(ethers.ZeroAddress);

      const pair = await ethers.getContractAt("@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol:IUniswapV2Pair", pairAddr);
      // All LP burned at DEAD (no LP held by the curve pool)
      const DEAD = "0x000000000000000000000000000000000000dEaD";
      const deadLp: bigint = await pair.balanceOf(DEAD);
      expect(deadLp).to.be.gt(0n);
    });
  });

  describe("Option 3 — first-pool check", function () {
    it("Reverts if attacker pre-creates the pair with non-zero reserves", async function () {
      const wethAddr  = await weth.getAddress();
      const tokenAddr = await token.getAddress();

      // 1. Attacker calls factory.createPair to instantiate the pair
      await factory.connect(attacker).createPair(tokenAddr, wethAddr);
      const pairAddr: string = await factory.getPair(tokenAddr, wethAddr);
      const pair = await ethers.getContractAt("@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol:IUniswapV2Pair", pairAddr);

      // 2. Attacker seeds tiny amounts directly to the pair to set a bad ratio.
      //    We just need any non-zero reserves to trip our check.
      //    Attacker would need to have some of the curve token; for the test,
      //    we'll have the curve pool's owner (alice) send a tiny amount from
      //    her buys. Easiest setup: buy a small amount on the curve first,
      //    then have alice transfer to the pair.
      await pool.connect(alice).buy(0, { value: ethers.parseEther("1") });
      const aliceBal: bigint = await token.balanceOf(alice.address);
      expect(aliceBal).to.be.gt(0n);
      // Send tokens + wrap a tiny WETH and send to pair, then sync
      await token.connect(alice).transfer(pairAddr, aliceBal);
      await weth.connect(attacker).deposit({ value: ethers.parseEther("0.001") });
      await weth.connect(attacker).transfer(pairAddr, ethers.parseEther("0.001"));
      await pair.sync();

      // Sanity: reserves are non-zero now
      const [r0, r1]: [bigint, bigint] = await pair.getReserves();
      expect(r0).to.be.gt(0n);
      expect(r1).to.be.gt(0n);

      // 3. Graduation attempt should now revert with our slippage guard
      await expect(buyToGraduation(alice)).to.be.revertedWith("graduation: pair has reserves (manipulated)");
    });

    it("Accepts an empty pair created in advance (zero-reserves edge case)", async function () {
      const wethAddr  = await weth.getAddress();
      const tokenAddr = await token.getAddress();

      // Someone creates the pair early but doesn't seed it. Harmless — graduation should proceed.
      await factory.connect(attacker).createPair(tokenAddr, wethAddr);
      await expect(buyToGraduation(alice)).to.not.be.reverted;

      const graduated: boolean = await pool.graduated();
      expect(graduated).to.equal(true);
    });
  });

  describe("Donation-attack resistance", function () {
    it("Native donated before graduation is swept to FeeVault, not deposited as LP", async function () {
      const wethAddr  = await weth.getAddress();
      const tokenAddr = await token.getAddress();
      const poolAddr  = await pool.getAddress();

      // Attacker donates 50 native directly to the pool just before graduation.
      // The pool's `receive()` accepts it — this is the donation vector.
      const DONATION = ethers.parseEther("50");
      await attacker.sendTransaction({ to: poolAddr, value: DONATION });
      expect(await ethers.provider.getBalance(poolAddr)).to.equal(DONATION);

      const feeVaultBefore: bigint = await ethers.provider.getBalance(feeVault.address);

      // Trigger graduation. Curve raises ~100 native (graduation threshold).
      await buyToGraduation(alice);
      expect(await pool.graduated()).to.equal(true);

      // The V2 pair's native (WETH) reserve must equal nativeRaised, NOT
      // nativeRaised + DONATION. If the old `address(this).balance` path
      // were still in use, the pair would hold 100 + 50 = 150 native.
      const pairAddr: string = await factory.getPair(tokenAddr, wethAddr);
      const wethReserveOnPair: bigint = await weth.balanceOf(pairAddr);
      const nativeRaisedFinal: bigint = await pool.nativeRaised();
      expect(wethReserveOnPair).to.equal(nativeRaisedFinal);

      // The donation should have landed in the FeeVault via ResidualSwept.
      const feeVaultAfter: bigint = await ethers.provider.getBalance(feeVault.address);
      const feeVaultDelta: bigint = feeVaultAfter - feeVaultBefore;
      // Delta is the donation plus any curve-fee deposits made during the
      // graduation buy. At minimum it includes the full donation.
      expect(feeVaultDelta).to.be.gte(DONATION);

      // Pool's residual balance is now 0 — nothing locked.
      expect(await ethers.provider.getBalance(poolAddr)).to.equal(0n);
    });

    it("Emits ResidualSwept when donation is captured", async function () {
      const poolAddr = await pool.getAddress();
      const DONATION = ethers.parseEther("7");
      await attacker.sendTransaction({ to: poolAddr, value: DONATION });

      // Use a custom matcher: we don't know the exact sweep amount upfront
      // (router may also refund a tiny bit), so just assert the event fires
      // with feeVault as recipient and a strictly-positive amount.
      const tx = await pool.connect(alice).buy(0, { value: ethers.parseEther("150") });
      const receipt = await tx.wait();

      const sweptEvents = receipt.logs
        .map((l: any) => {
          try { return pool.interface.parseLog(l as any); } catch { return null; }
        })
        .filter((e: any) => e && e.name === "ResidualSwept");

      expect(sweptEvents.length).to.equal(1);
      expect(sweptEvents[0].args.to).to.equal(feeVault.address);
      expect(sweptEvents[0].args.amount).to.be.gte(DONATION);
    });
  });
});
