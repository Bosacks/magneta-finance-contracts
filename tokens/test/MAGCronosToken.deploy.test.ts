import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Deploy-path security validation for MAGCronosToken (Phase-3 redeploy blocker,
 * see docs/contract-redeploy-runbook.md §"Phase 3 — MAGCronos").
 *
 * Mirrors how scripts/deploy-mag-cronos.ts wires the contract: a Safe `admin`
 * (DEFAULT_ADMIN_ROLE + PAUSER_ROLE), a `relayer` (MINTER_ROLE), and a NON-ZERO
 * mint cap passed IN THE CONSTRUCTOR so the control binds from block 0 (the
 * deployer EOA cannot call setMintCap once admin = Safe).
 *
 * Runs on the in-process Hardhat network — no external RPC / fork required.
 *
 * Guards exercised:
 *   - replay protection (usedMessages / messageId)
 *   - rolling-epoch mint cap (incl. reset after the window elapses)
 *   - access control on relayerMint
 *   - pausable mint (whenNotPaused)
 *   - tracked-relayer rotation revokes the old relayer's MINTER_ROLE
 *
 * OZ v5: AccessControl + Pausable revert with custom errors.
 */
describe("MAGCronosToken — deploy-path security guards", function () {
  let admin: SignerWithAddress;   // stands in for the Cronos in-house Safe
  let relayer: SignerWithAddress; // stands in for the Cronos relayer wallet
  let user: SignerWithAddress;
  let outsider: SignerWithAddress;
  let mag: any;

  // Small cap so the "exceed the cap" path is cheap to drive.
  const CAP = ethers.parseEther("300");
  const EPOCH = 3600; // 1h rolling window
  const SRC_CHAIN = 8453n; // Base, as a representative source chain
  const TX_HASH = "0x" + "ab".repeat(32);
  const AMT = ethers.parseEther("100");

  let MINTER_ROLE: string;
  let PAUSER_ROLE: string;
  let DEFAULT_ADMIN_ROLE: string;

  // Mirrors the deploy script's constructor wiring (cap bound from block 0).
  async function deploy() {
    const Mag = await ethers.getContractFactory("MAGCronosToken");
    const c = await Mag.deploy(admin.address, relayer.address, CAP, EPOCH);
    await c.waitForDeployment();
    return c;
  }

  const mint = (
    signer: SignerWithAddress,
    to: string,
    amount: bigint,
    logIndex: number,
    txHash = TX_HASH,
  ) => mag.connect(signer).relayerMint(to, amount, SRC_CHAIN, txHash, logIndex);

  beforeEach(async function () {
    [admin, relayer, user, outsider] = await ethers.getSigners();
    mag = await deploy();
    MINTER_ROLE = await mag.MINTER_ROLE();
    PAUSER_ROLE = await mag.PAUSER_ROLE();
    DEFAULT_ADMIN_ROLE = await mag.DEFAULT_ADMIN_ROLE();
  });

  describe("constructor wiring (what the deploy script produces)", function () {
    it("grants the right roles and binds the cap from block 0", async function () {
      expect(await mag.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.equal(true);
      expect(await mag.hasRole(PAUSER_ROLE, admin.address)).to.equal(true);
      expect(await mag.hasRole(MINTER_ROLE, relayer.address)).to.equal(true);
      expect(await mag.hasRole(MINTER_ROLE, admin.address)).to.equal(false);

      expect(await mag.currentRelayer()).to.equal(relayer.address);
      expect(await mag.mintCapPerEpoch()).to.equal(CAP); // non-zero → capped from block 0
      expect(await mag.epochLength()).to.equal(EPOCH);
    });

    it("epochLength == 0 defaults to 1 day", async function () {
      const Mag = await ethers.getContractFactory("MAGCronosToken");
      const c = await Mag.deploy(admin.address, relayer.address, CAP, 0);
      await c.waitForDeployment();
      expect(await c.epochLength()).to.equal(86400);
    });

    it("rejects zero admin / relayer", async function () {
      const Mag = await ethers.getContractFactory("MAGCronosToken");
      await expect(Mag.deploy(ethers.ZeroAddress, relayer.address, CAP, EPOCH))
        .to.be.revertedWith("MAGCronos: zero address");
      await expect(Mag.deploy(admin.address, ethers.ZeroAddress, CAP, EPOCH))
        .to.be.revertedWith("MAGCronos: zero address");
    });
  });

  describe("relayerMint + replay protection", function () {
    it("the relayer mints successfully", async function () {
      await expect(mint(relayer, user.address, AMT, 0)).to.emit(mag, "RelayerMint");
      expect(await mag.balanceOf(user.address)).to.equal(AMT);
    });

    it("an exact replay of the same message reverts", async function () {
      await mint(relayer, user.address, AMT, 0);
      await expect(mint(relayer, user.address, AMT, 0))
        .to.be.revertedWith("MAGCronos: message already processed");
      // balance unchanged — the replay minted nothing
      expect(await mag.balanceOf(user.address)).to.equal(AMT);
    });
  });

  describe("rolling-epoch mint cap", function () {
    it("reverts a mint that pushes past the cap within the epoch", async function () {
      await mint(relayer, user.address, CAP, 0); // exactly at the cap
      await expect(mint(relayer, user.address, 1n, 1))
        .to.be.revertedWith("MAGCronos: epoch mint cap exceeded");
    });

    it("resets and succeeds after advancing past epochLength", async function () {
      await mint(relayer, user.address, CAP, 0);
      // still within the epoch → blocked
      await expect(mint(relayer, user.address, 1n, 1))
        .to.be.revertedWith("MAGCronos: epoch mint cap exceeded");

      await time.increase(EPOCH + 1); // advance past the rolling window

      await expect(mint(relayer, user.address, CAP, 2)).to.not.be.reverted;
      expect(await mag.balanceOf(user.address)).to.equal(CAP * 2n);
    });
  });

  describe("access control", function () {
    it("a non-relayer cannot mint", async function () {
      await expect(mint(outsider, user.address, AMT, 0))
        .to.be.revertedWithCustomError(mag, "AccessControlUnauthorizedAccount");
    });
  });

  describe("pausable mint", function () {
    it("pause() blocks relayerMint (whenNotPaused)", async function () {
      await mag.connect(admin).pause();
      await expect(mint(relayer, user.address, AMT, 0))
        .to.be.revertedWithCustomError(mag, "EnforcedPause");
      await mag.connect(admin).unpause();
      await expect(mint(relayer, user.address, AMT, 0)).to.not.be.reverted;
    });
  });

  describe("relayer rotation", function () {
    it("revokes the old relayer's MINTER_ROLE and grants it to the new one", async function () {
      await expect(mag.connect(admin).setRelayer(outsider.address))
        .to.emit(mag, "RelayerRotated");

      expect(await mag.currentRelayer()).to.equal(outsider.address);
      expect(await mag.hasRole(MINTER_ROLE, relayer.address)).to.equal(false);
      expect(await mag.hasRole(MINTER_ROLE, outsider.address)).to.equal(true);

      // old relayer is now locked out
      await expect(mint(relayer, user.address, AMT, 0))
        .to.be.revertedWithCustomError(mag, "AccessControlUnauthorizedAccount");
      // new relayer can mint
      await expect(
        mag.connect(outsider).relayerMint(user.address, AMT, SRC_CHAIN, TX_HASH, 0),
      ).to.not.be.reverted;
    });
  });
});
