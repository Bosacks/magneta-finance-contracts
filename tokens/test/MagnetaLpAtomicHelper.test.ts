import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * MagnetaLpAtomicHelper — V1.1 atomic LP flows.
 *
 * Exercises the two single-signature flows the helper collapses out of the
 * V1 sequential wizards:
 *   - compoundPosition : remove from a UniV2 pair, immediately re-add at the
 *                        current ratio, new LP back to the user.
 *   - migratePosition  : remove from src DEX's pair, re-add on dst DEX's
 *                        router, new dst LP back to the user.
 *
 * Runs entirely on the in-process Hardhat network against minimal UniV2
 * mocks (contracts/mocks/MockUniV2.sol) — no external RPC / mainnet fork
 * required, so it's fast and deterministic.
 *
 * Guards exercised:
 *   - happy-path compound (LP back to user, no helper residual)
 *   - happy-path migrate across two routers (different factories)
 *   - DeadlineTooClose on an already-expired / too-close deadline
 *   - LpAmountZero / ZeroAddress / ZeroRecipient input validation
 *   - the helper holds no token/LP balance after a successful call
 *   - amountAMin/amountBMin slippage floor reverts the re-add when too tight
 */
describe("MagnetaLpAtomicHelper", function () {
  let user: SignerWithAddress;
  let outsider: SignerWithAddress;

  let helper: any;
  let factoryA: SignerWithAddress; // stands in for src factory address
  let factoryB: SignerWithAddress; // stands in for dst factory address
  let routerA: any;
  let routerB: any;
  let tokenX: any;
  let tokenY: any;
  let pairA: string;

  const RESERVE0 = ethers.parseEther("1000");
  const RESERVE1 = ethers.parseEther("4000");

  // Far-enough deadline to clear the helper's MIN_DEADLINE_BUFFER (60s).
  const farDeadline = async () => BigInt(await time.latest()) + 3600n;

  // Sort two token addresses the way the mock router does.
  function sorted(a: string, b: string): [string, string] {
    return a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
  }

  beforeEach(async function () {
    [user, outsider, factoryA, factoryB] = await ethers.getSigners();

    const Helper = await ethers.getContractFactory("MagnetaLpAtomicHelper");
    helper = await Helper.deploy();
    await helper.waitForDeployment();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    tokenX = await MockERC20.deploy("Token X", "TKX");
    tokenY = await MockERC20.deploy("Token Y", "TKY");
    await tokenX.waitForDeployment();
    await tokenY.waitForDeployment();

    const Router = await ethers.getContractFactory("MockUniV2Router");
    routerA = await Router.deploy(factoryA.address);
    routerB = await Router.deploy(factoryB.address);
    await routerA.waitForDeployment();
    await routerB.waitForDeployment();

    // Seed routerA's pair with reserves in sorted order, LP to the user.
    const [t0, t1] = sorted(await tokenX.getAddress(), await tokenY.getAddress());
    const [amt0, amt1] =
      t0.toLowerCase() === (await tokenX.getAddress()).toLowerCase()
        ? [RESERVE0, RESERVE1]
        : [RESERVE1, RESERVE0];

    await tokenX.mint(user.address, ethers.parseEther("1000000"));
    await tokenY.mint(user.address, ethers.parseEther("1000000"));
    await tokenX.connect(user).approve(await routerA.getAddress(), ethers.MaxUint256);
    await tokenY.connect(user).approve(await routerA.getAddress(), ethers.MaxUint256);

    await routerA.connect(user).seed(t0, t1, amt0, amt1, user.address);
    pairA = await routerA.getPair(await tokenX.getAddress(), await tokenY.getAddress());
  });

  async function lpBalance(account: string): Promise<bigint> {
    const pair = await ethers.getContractAt("MockUniV2Pair", pairA);
    return pair.balanceOf(account);
  }

  describe("compoundPosition", function () {
    it("removes + re-adds in one call, new LP back to the user", async function () {
      const pair = await ethers.getContractAt("MockUniV2Pair", pairA);
      const lp = await pair.balanceOf(user.address);
      expect(lp).to.be.gt(0n);

      await pair.connect(user).approve(await helper.getAddress(), lp);

      const dl = await farDeadline();
      await expect(
        helper.connect(user).compoundPosition(
          pairA,
          await routerA.getAddress(),
          lp,
          0n,
          0n,
          dl,
        ),
      ).to.emit(helper, "Compounded");

      // User holds fresh LP again (≈ same, minus rounding), and the helper
      // holds nothing.
      expect(await pair.balanceOf(user.address)).to.be.gt(0n);
      expect(await pair.balanceOf(await helper.getAddress())).to.equal(0n);
      expect(
        await tokenX.balanceOf(await helper.getAddress()),
      ).to.equal(0n);
      expect(
        await tokenY.balanceOf(await helper.getAddress()),
      ).to.equal(0n);
    });

    it("reverts DeadlineTooClose for an expired / too-close deadline", async function () {
      const pair = await ethers.getContractAt("MockUniV2Pair", pairA);
      const lp = await pair.balanceOf(user.address);
      await pair.connect(user).approve(await helper.getAddress(), lp);

      const now = BigInt(await time.latest());
      await expect(
        helper.connect(user).compoundPosition(pairA, await routerA.getAddress(), lp, 0n, 0n, now),
      ).to.be.revertedWithCustomError(helper, "DeadlineTooClose");
    });

    it("reverts LpAmountZero when lpAmount == 0", async function () {
      const dl = await farDeadline();
      await expect(
        helper.connect(user).compoundPosition(pairA, await routerA.getAddress(), 0n, 0n, 0n, dl),
      ).to.be.revertedWithCustomError(helper, "LpAmountZero");
    });

    it("reverts ZeroAddress for a zero pair or router", async function () {
      const dl = await farDeadline();
      await expect(
        helper.connect(user).compoundPosition(ethers.ZeroAddress, await routerA.getAddress(), 1n, 0n, 0n, dl),
      ).to.be.revertedWithCustomError(helper, "ZeroAddress");
      await expect(
        helper.connect(user).compoundPosition(pairA, ethers.ZeroAddress, 1n, 0n, 0n, dl),
      ).to.be.revertedWithCustomError(helper, "ZeroAddress");
    });

    it("reverts when the re-add slippage floor is unsatisfiable", async function () {
      const pair = await ethers.getContractAt("MockUniV2Pair", pairA);
      const lp = await pair.balanceOf(user.address);
      await pair.connect(user).approve(await helper.getAddress(), lp);

      const dl = await farDeadline();
      // Demand more out of the re-add than the pool can possibly provide.
      const impossibleMin = ethers.parseEther("100000000");
      await expect(
        helper.connect(user).compoundPosition(
          pairA, await routerA.getAddress(), lp, impossibleMin, impossibleMin, dl,
        ),
      ).to.be.reverted; // MockRouter INSUFFICIENT_* — re-add fails closed
    });
  });

  describe("compoundPositionFor", function () {
    it("reverts ZeroRecipient when recipient == 0", async function () {
      const pair = await ethers.getContractAt("MockUniV2Pair", pairA);
      const lp = await pair.balanceOf(user.address);
      await pair.connect(user).approve(await helper.getAddress(), lp);
      const dl = await farDeadline();
      await expect(
        helper.connect(user).compoundPositionFor(
          pairA, await routerA.getAddress(), lp, 0n, 0n, dl, ethers.ZeroAddress,
        ),
      ).to.be.revertedWithCustomError(helper, "ZeroRecipient");
    });

    it("sends the new LP to an explicit recipient", async function () {
      const pair = await ethers.getContractAt("MockUniV2Pair", pairA);
      const lp = await pair.balanceOf(user.address);
      await pair.connect(user).approve(await helper.getAddress(), lp);
      const dl = await farDeadline();

      const before = await pair.balanceOf(outsider.address);
      await helper.connect(user).compoundPositionFor(
        pairA, await routerA.getAddress(), lp, 0n, 0n, dl, outsider.address,
      );
      expect(await pair.balanceOf(outsider.address)).to.be.gt(before);
    });
  });

  describe("migratePosition", function () {
    it("moves LP from routerA's pair to routerB, new dst LP back to the user", async function () {
      const srcPairC = await ethers.getContractAt("MockUniV2Pair", pairA);
      const lp = await srcPairC.balanceOf(user.address);
      await srcPairC.connect(user).approve(await helper.getAddress(), lp);

      const dl = await farDeadline();
      await expect(
        helper.connect(user).migratePosition(
          pairA,
          await routerA.getAddress(),
          await routerB.getAddress(),
          lp,
          0n,
          0n,
          dl,
        ),
      ).to.emit(helper, "Migrated");

      // Source LP fully consumed.
      expect(await srcPairC.balanceOf(user.address)).to.equal(0n);

      // Destination pair created + LP minted to the user.
      const dstPairAddr = await routerB.getPair(
        await tokenX.getAddress(),
        await tokenY.getAddress(),
      );
      expect(dstPairAddr).to.not.equal(ethers.ZeroAddress);
      const dstPair = await ethers.getContractAt("MockUniV2Pair", dstPairAddr);
      expect(await dstPair.balanceOf(user.address)).to.be.gt(0n);

      // Helper holds nothing afterwards.
      expect(await tokenX.balanceOf(await helper.getAddress())).to.equal(0n);
      expect(await tokenY.balanceOf(await helper.getAddress())).to.equal(0n);
    });

    it("reverts ZeroAddress for a zero src/dst router", async function () {
      const dl = await farDeadline();
      await expect(
        helper.connect(user).migratePosition(
          pairA, ethers.ZeroAddress, await routerB.getAddress(), 1n, 0n, 0n, dl,
        ),
      ).to.be.revertedWithCustomError(helper, "ZeroAddress");
    });

    it("reverts ZeroRecipient on migratePositionFor with recipient == 0", async function () {
      const pair = await ethers.getContractAt("MockUniV2Pair", pairA);
      const lp = await pair.balanceOf(user.address);
      await pair.connect(user).approve(await helper.getAddress(), lp);
      const dl = await farDeadline();
      await expect(
        helper.connect(user).migratePositionFor(
          pairA, await routerA.getAddress(), await routerB.getAddress(), lp, 0n, 0n, dl, ethers.ZeroAddress,
        ),
      ).to.be.revertedWithCustomError(helper, "ZeroRecipient");
    });
  });
});
