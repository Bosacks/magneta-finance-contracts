import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * MagnetaCurveFactory hardening tests (Sentinelle audit 2026-05-22).
 *
 * Covers:
 *   - Ownable2Step two-step transfer (LOW SC01)
 *   - Critical-setter timelock for router + feeVault (HIGH SC01)
 *   - Per-creation parameter bounds (HIGH SC04)
 *   - Metadata byte-length caps (MEDIUM SC10)
 *   - Paginated getters (MEDIUM SC10)
 *   - Post-transfer balance assertion path is exercised by existing graduation tests
 */
describe("MagnetaCurveFactory — Sentinelle hardening", function () {
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let feeVault: SignerWithAddress;

  let weth: any;
  let factoryV2: any;
  let router: any;
  let curveFactory: any;

  const TOTAL_SUPPLY = ethers.parseEther("1000000000");
  const CURVE_ALLOC  = ethers.parseEther("800000000");
  const VIRTUAL_RES  = ethers.parseEther("10");
  const GRAD_THRESH  = ethers.parseEther("100");

  beforeEach(async function () {
    [owner, alice, feeVault] = await ethers.getSigners();

    const WETH9 = await ethers.getContractFactory("WETH9");
    weth = await WETH9.deploy();
    await weth.waitForDeployment();

    const Factory = await ethers.getContractFactory("UniswapV2Factory");
    factoryV2 = await Factory.deploy(owner.address);
    await factoryV2.waitForDeployment();

    const Router = await ethers.getContractFactory("MagnetaV2Router02");
    router = await Router.deploy(await factoryV2.getAddress(), await weth.getAddress());
    await router.waitForDeployment();

    const CurveFactory = await ethers.getContractFactory("MagnetaCurveFactory");
    curveFactory = await CurveFactory.deploy(
      await router.getAddress(),
      feeVault.address,
      owner.address,
    );
    await curveFactory.waitForDeployment();
  });

  describe("LOW SC01 — Ownable2Step", function () {
    it("transferOwnership requires acceptOwnership before taking effect", async function () {
      await curveFactory.transferOwnership(alice.address);
      expect(await curveFactory.owner()).to.equal(owner.address);
      expect(await curveFactory.pendingOwner()).to.equal(alice.address);

      await curveFactory.connect(alice).acceptOwnership();
      expect(await curveFactory.owner()).to.equal(alice.address);
      expect(await curveFactory.pendingOwner()).to.equal(ethers.ZeroAddress);
    });
  });

  describe("HIGH SC01 — router/feeVault timelock", function () {
    it("proposeRouter rejects EOAs and zero", async function () {
      await expect(curveFactory.proposeRouter(ethers.ZeroAddress)).to.be.revertedWith("zero router");
      await expect(curveFactory.proposeRouter(alice.address)).to.be.revertedWith("router not a contract");
    });

    it("applyRouter reverts before the delay elapses; succeeds after", async function () {
      const Router2 = await ethers.getContractFactory("MagnetaV2Router02");
      const newRouter = await Router2.deploy(await factoryV2.getAddress(), await weth.getAddress());

      await curveFactory.proposeRouter(await newRouter.getAddress());
      await expect(curveFactory.applyRouter()).to.be.revertedWith("timelock active");

      // Advance 24h
      await ethers.provider.send("evm_increaseTime", [24 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(curveFactory.applyRouter())
        .to.emit(curveFactory, "RouterUpdated")
        .withArgs(await router.getAddress(), await newRouter.getAddress());
      expect(await curveFactory.router()).to.equal(await newRouter.getAddress());
    });

    it("applyFeeVault follows the same timelock", async function () {
      await curveFactory.proposeFeeVault(alice.address);
      await expect(curveFactory.applyFeeVault()).to.be.revertedWith("timelock active");

      await ethers.provider.send("evm_increaseTime", [24 * 3600 + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(curveFactory.applyFeeVault())
        .to.emit(curveFactory, "FeeVaultUpdated")
        .withArgs(feeVault.address, alice.address);
      expect(await curveFactory.feeVault()).to.equal(alice.address);
    });

    it("non-owner cannot propose", async function () {
      await expect(
        curveFactory.connect(alice).proposeRouter(await router.getAddress()),
      ).to.be.reverted;
      await expect(
        curveFactory.connect(alice).proposeFeeVault(alice.address),
      ).to.be.reverted;
    });
  });

  describe("HIGH SC04 — per-creation parameter bounds", function () {
    it("rejects virtualNativeReserve below minVirtualNativeReserve", async function () {
      const tooSmall = (await curveFactory.minVirtualNativeReserve()) - 1n;
      await expect(
        curveFactory.connect(alice).createCurveToken(
          "T", "T", "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, tooSmall, GRAD_THRESH,
        ),
      ).to.be.revertedWith("virtual too small");
    });

    it("rejects graduationThreshold below minGraduationThreshold", async function () {
      const tooSmall = (await curveFactory.minGraduationThreshold()) - 1n;
      await expect(
        curveFactory.connect(alice).createCurveToken(
          "T", "T", "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, tooSmall,
        ),
      ).to.be.revertedWith("threshold too small");
    });

    it("rejects totalSupply above maxTotalSupply", async function () {
      const max = await curveFactory.maxTotalSupply();
      await expect(
        curveFactory.connect(alice).createCurveToken(
          "T", "T", "ipfs://t", max + 1n, CURVE_ALLOC, VIRTUAL_RES, GRAD_THRESH,
        ),
      ).to.be.revertedWith("supply too large");
    });

    it("rejects graduationThreshold above maxGraduationThreshold", async function () {
      const tooLarge = (await curveFactory.maxGraduationThreshold()) + 1n;
      await expect(
        curveFactory.connect(alice).createCurveToken(
          "T", "T", "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, tooLarge,
        ),
      ).to.be.revertedWith("threshold too large");
    });

    it("rejects graduationThreshold not strictly above virtualNativeReserve", async function () {
      // graduationThreshold == virtualNativeReserve: a pool that "graduates"
      // before any real native is deposited beyond the virtual seed.
      await expect(
        curveFactory.connect(alice).createCurveToken(
          "T", "T", "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, VIRTUAL_RES,
        ),
      ).to.be.revertedWith("threshold below virtual");
    });

    it("owner can tune bounds via setParameterBounds", async function () {
      await expect(
        curveFactory.setParameterBounds(
          ethers.parseEther("1"),
          ethers.parseEther("10000000000"),
          ethers.parseEther("10"),
          ethers.parseEther("5000000"),
        ),
      ).to.emit(curveFactory, "ParameterBoundsUpdated");
      expect(await curveFactory.minVirtualNativeReserve()).to.equal(ethers.parseEther("1"));
      expect(await curveFactory.maxGraduationThreshold()).to.equal(ethers.parseEther("5000000"));
    });

    it("setParameterBounds rejects maxGraduationThreshold below minGraduationThreshold", async function () {
      await expect(
        curveFactory.setParameterBounds(
          ethers.parseEther("1"),
          ethers.parseEther("10000000000"),
          ethers.parseEther("10"),
          ethers.parseEther("9"),
        ),
      ).to.be.revertedWith("bad threshold bounds");
    });

    it("non-owner cannot tune bounds", async function () {
      await expect(
        curveFactory.connect(alice).setParameterBounds(1n, 1n, 1n, 1n),
      ).to.be.reverted;
    });
  });

  describe("MEDIUM SC10 — metadata byte caps", function () {
    it("rejects name > 64 bytes", async function () {
      const tooLong = "x".repeat(65);
      await expect(
        curveFactory.connect(alice).createCurveToken(
          tooLong, "T", "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, GRAD_THRESH,
        ),
      ).to.be.revertedWith("name too long");
    });

    it("rejects symbol > 16 bytes", async function () {
      await expect(
        curveFactory.connect(alice).createCurveToken(
          "T", "x".repeat(17), "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, GRAD_THRESH,
        ),
      ).to.be.revertedWith("symbol too long");
    });

    it("rejects uri > 256 bytes", async function () {
      await expect(
        curveFactory.connect(alice).createCurveToken(
          "T", "T", "x".repeat(257), TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, GRAD_THRESH,
        ),
      ).to.be.revertedWith("uri too long");
    });
  });

  describe("MagnetaCurveToken hardening (Sentinelle MED SC01 + LOW SC03)", function () {
    it("factory() returns the deploying MagnetaCurveFactory address", async function () {
      const tx = await curveFactory.connect(alice).createCurveToken(
        "Tok", "T", "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, GRAD_THRESH,
      );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((l: any) => {
        try { return curveFactory.interface.parseLog(l as any)?.name === "CurveTokenCreated"; }
        catch { return false; }
      });
      const parsed = curveFactory.interface.parseLog(event as any);
      const tokenAddr: string = parsed!.args.token;
      const token = await ethers.getContractAt("MagnetaCurveToken", tokenAddr);
      expect(await token.factory()).to.equal(await curveFactory.getAddress());
    });

    it("burnFrom always reverts (allowance-griefing surface closed)", async function () {
      const tx = await curveFactory.connect(alice).createCurveToken(
        "Tok2", "T2", "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, GRAD_THRESH,
      );
      const receipt = await tx.wait();
      const event = receipt!.logs.find((l: any) => {
        try { return curveFactory.interface.parseLog(l as any)?.name === "CurveTokenCreated"; }
        catch { return false; }
      });
      const parsed = curveFactory.interface.parseLog(event as any);
      const tokenAddr: string = parsed!.args.token;
      const token = await ethers.getContractAt("MagnetaCurveToken", tokenAddr);

      await expect(
        token.connect(alice).burnFrom(owner.address, 1n),
      ).to.be.revertedWithCustomError(token, "BurnFromDisabled");
    });
  });

  describe("MEDIUM SC10 — paginated getters", function () {
    beforeEach(async function () {
      // Create 5 tokens for pagination tests
      for (let i = 0; i < 5; i++) {
        await curveFactory.connect(alice).createCurveToken(
          `Tok${i}`, `T${i}`, "ipfs://t", TOTAL_SUPPLY, CURVE_ALLOC, VIRTUAL_RES, GRAD_THRESH,
        );
      }
    });

    it("getUserTokensPaginated returns the requested slice", async function () {
      const all = await curveFactory.getUserTokens(alice.address);
      expect(all.length).to.equal(5);

      const first2 = await curveFactory.getUserTokensPaginated(alice.address, 0, 2);
      expect(first2.length).to.equal(2);
      expect(first2[0]).to.equal(all[0]);
      expect(first2[1]).to.equal(all[1]);

      const last3 = await curveFactory.getUserTokensPaginated(alice.address, 2, 100);
      expect(last3.length).to.equal(3);
      expect(last3[0]).to.equal(all[2]);

      const empty = await curveFactory.getUserTokensPaginated(alice.address, 10, 10);
      expect(empty.length).to.equal(0);
    });

    it("getAllTokensPaginated returns the requested slice", async function () {
      const count = await curveFactory.getTokenCount();
      expect(count).to.equal(5n);

      const middle = await curveFactory.getAllTokensPaginated(1, 2);
      expect(middle.length).to.equal(2);
    });
  });
});
