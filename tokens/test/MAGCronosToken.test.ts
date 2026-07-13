import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Validation tests for the MAGCronosToken hardening (Sentinelle 2026-06-22):
 *   F-1  per-message replay protection (usedMessages / messageId)
 *   F-2  rolling-epoch mint cap (bounds a compromised relayer)
 *   +    Pausable mint + tracked-relayer rotation (F-5)
 *
 * OZ v5: AccessControl and Pausable revert with custom errors.
 */
describe("MAGCronosToken — bridge mint hardening", function () {
  let admin: SignerWithAddress;
  let relayer: SignerWithAddress;
  let user: SignerWithAddress;
  let other: SignerWithAddress;
  let mag: any;

  const CAP   = ethers.parseEther("1000");        // per-epoch mint cap
  const EPOCH = 3600;                             // 1h rolling window
  const SRC_CHAIN = 8453n;                        // Base
  const TX_HASH = "0x" + "11".repeat(32);
  const AMT = ethers.parseEther("100");

  let MINTER_ROLE: string;
  let PAUSER_ROLE: string;

  beforeEach(async function () {
    [admin, relayer, user, other] = await ethers.getSigners();
    const Mag = await ethers.getContractFactory("MAGCronosToken");
    mag = await Mag.deploy(admin.address, relayer.address, CAP, EPOCH);
    await mag.waitForDeployment();
    MINTER_ROLE = await mag.MINTER_ROLE();
    PAUSER_ROLE = await mag.PAUSER_ROLE();
  });

  const mint = (signer: SignerWithAddress, to: string, amount: bigint, logIndex: number, txHash = TX_HASH) =>
    mag.connect(signer).relayerMint(to, amount, SRC_CHAIN, txHash, logIndex);

  describe("F-1 — replay protection", function () {
    it("mints once and rejects an exact replay of the same message", async function () {
      await expect(mint(relayer, user.address, AMT, 0)).to.emit(mag, "RelayerMint");
      expect(await mag.balanceOf(user.address)).to.equal(AMT);

      await expect(mint(relayer, user.address, AMT, 0))
        .to.be.revertedWith("MAGCronos: message already processed");
      expect(await mag.balanceOf(user.address)).to.equal(AMT);
    });

    it("F113: same source event with a different to/amount cannot be re-keyed", async function () {
      await mint(relayer, user.address, AMT, 0);
      // Same (chain, tx, logIndex) but different recipient AND amount → must still
      // be rejected, because the messageId no longer includes to/amount.
      await expect(
        mag.connect(relayer).relayerMint(other.address, AMT * 5n, SRC_CHAIN, TX_HASH, 0),
      ).to.be.revertedWith("MAGCronos: message already processed");
      expect(await mag.balanceOf(other.address)).to.equal(0n);
    });

    it("treats distinct log indexes within the same tx as independent mints", async function () {
      await mint(relayer, user.address, AMT, 0);
      await mint(relayer, user.address, AMT, 1);
      expect(await mag.balanceOf(user.address)).to.equal(AMT * 2n);
    });

    it("treats the same logIndex on different source chains/txs as independent", async function () {
      await mint(relayer, user.address, AMT, 0, TX_HASH);
      await mint(relayer, user.address, AMT, 0, "0x" + "22".repeat(32));
      expect(await mag.balanceOf(user.address)).to.equal(AMT * 2n);
    });
  });

  describe("F-2 — epoch mint cap", function () {
    it("rejects a mint that would exceed the per-epoch cap", async function () {
      await mint(relayer, user.address, CAP, 0);                 // exactly at cap
      await expect(mint(relayer, user.address, 1n, 1))
        .to.be.revertedWith("MAGCronos: epoch mint cap exceeded");
    });

    it("resets the cap after the epoch window elapses", async function () {
      await mint(relayer, user.address, CAP, 0);
      await time.increase(EPOCH + 1);
      await expect(mint(relayer, user.address, CAP, 1)).to.not.be.reverted;
      expect(await mag.balanceOf(user.address)).to.equal(CAP * 2n);
    });

    it("F36: rejects a zero cap at deploy (no 'uncapped' state)", async function () {
      const Mag = await ethers.getContractFactory("MAGCronosToken");
      await expect(
        Mag.deploy(admin.address, relayer.address, 0, EPOCH),
      ).to.be.revertedWith("MAGCronos: zero cap");
    });

    it("F36: a zero cap set later DISABLES minting (fails closed, never uncapped)", async function () {
      await mag.connect(admin).setMintCap(0, EPOCH);
      await expect(
        mag.connect(relayer).relayerMint(user.address, 1n, SRC_CHAIN, TX_HASH, 0),
      ).to.be.revertedWith("MAGCronos: minting disabled");
    });

    it("only the admin can change the cap", async function () {
      await expect(mag.connect(other).setMintCap(CAP * 2n, EPOCH))
        .to.be.revertedWithCustomError(mag, "AccessControlUnauthorizedAccount");
      await expect(mag.connect(admin).setMintCap(CAP * 2n, EPOCH)).to.emit(mag, "MintCapUpdated");
      expect(await mag.mintCapPerEpoch()).to.equal(CAP * 2n);
    });
  });

  describe("Pausable mint", function () {
    it("blocks minting while paused and resumes after unpause", async function () {
      await mag.connect(admin).pause();
      await expect(mint(relayer, user.address, AMT, 0))
        .to.be.revertedWithCustomError(mag, "EnforcedPause");
      await mag.connect(admin).unpause();
      await expect(mint(relayer, user.address, AMT, 0)).to.not.be.reverted;
    });

    it("only a PAUSER can pause", async function () {
      await expect(mag.connect(other).pause())
        .to.be.revertedWithCustomError(mag, "AccessControlUnauthorizedAccount");
    });
  });

  describe("F-5 — tracked-relayer rotation", function () {
    it("rotates MINTER_ROLE off the tracked relayer onto the new one", async function () {
      await expect(mag.connect(admin).setRelayer(other.address)).to.emit(mag, "RelayerRotated");
      expect(await mag.currentRelayer()).to.equal(other.address);
      expect(await mag.hasRole(MINTER_ROLE, relayer.address)).to.equal(false);
      expect(await mag.hasRole(MINTER_ROLE, other.address)).to.equal(true);

      // old relayer can no longer mint
      await expect(mint(relayer, user.address, AMT, 0))
        .to.be.revertedWithCustomError(mag, "AccessControlUnauthorizedAccount");
      // new relayer can
      await expect(mag.connect(other).relayerMint(user.address, AMT, SRC_CHAIN, TX_HASH, 0))
        .to.not.be.reverted;
    });

    it("only the admin can rotate the relayer", async function () {
      await expect(mag.connect(other).setRelayer(other.address))
        .to.be.revertedWithCustomError(mag, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Access control on mint", function () {
    it("a non-minter cannot mint", async function () {
      await expect(
        mag.connect(other).relayerMint(user.address, AMT, SRC_CHAIN, TX_HASH, 0),
      ).to.be.revertedWithCustomError(mag, "AccessControlUnauthorizedAccount");
    });
  });
});
