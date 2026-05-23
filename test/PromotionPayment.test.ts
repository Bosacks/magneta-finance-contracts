import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { PromotionPayment } from "../typechain-types";

describe("PromotionPayment", function () {
  let promo: PromotionPayment;
  let owner: SignerWithAddress;
  let feeRecipient: SignerWithAddress;
  let payer: SignerWithAddress;
  let other: SignerWithAddress;

  // A real deployed contract (we use a MockERC20) so `token.code.length > 0`
  // passes. The token isn't actually called — it's purely a label in the event.
  let TOKEN: string;

  const CODE_1H = 1;
  const CODE_6H = 6;
  const PRICE_1H = ethers.parseEther("0.01");
  const PRICE_6H = ethers.parseEther("0.06");
  const NO_MAX = ethers.MaxUint256;

  beforeEach(async function () {
    [owner, feeRecipient, payer, other] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const tokenContract = await MockERC20.deploy("Promo", "PROMO", 18, 1n);
    TOKEN = await tokenContract.getAddress();

    const Factory = await ethers.getContractFactory("PromotionPayment");
    promo = await Factory.deploy(feeRecipient.address);

    await promo.connect(owner).setPricesBatch([CODE_1H, CODE_6H], [PRICE_1H, PRICE_6H]);
  });

  describe("Pricing", function () {
    it("Sets and reads prices via setPrice", async function () {
      await expect(promo.connect(owner).setPrice(12, ethers.parseEther("0.12")))
        .to.emit(promo, "PriceUpdated")
        .withArgs(12, 0, ethers.parseEther("0.12"));
      expect(await promo.priceByCode(12)).to.equal(ethers.parseEther("0.12"));
    });

    it("Batch sets multiple prices atomically", async function () {
      await promo.connect(owner).setPricesBatch([2, 24], [ethers.parseEther("0.02"), ethers.parseEther("0.24")]);
      expect(await promo.priceByCode(2)).to.equal(ethers.parseEther("0.02"));
      expect(await promo.priceByCode(24)).to.equal(ethers.parseEther("0.24"));
    });

    it("Reverts setPricesBatch on length mismatch", async function () {
      await expect(
        promo.connect(owner).setPricesBatch([1, 2], [ethers.parseEther("0.01")]),
      ).to.be.revertedWith("Length mismatch");
    });

    it("Non-owner cannot set prices", async function () {
      await expect(promo.connect(payer).setPrice(1, 1n)).to.be.reverted;
      await expect(promo.connect(payer).setPricesBatch([1], [1n])).to.be.reverted;
    });
  });

  describe("pay() — Sentinelle-hardened (pull-payment + maxPrice + token code check)", function () {
    it("Accrues exact payment internally, emits event, does NOT push to feeRecipient synchronously", async function () {
      const recBefore = await ethers.provider.getBalance(feeRecipient.address);

      await expect(promo.connect(payer).pay(TOKEN, CODE_1H, NO_MAX, { value: PRICE_1H }))
        .to.emit(promo, "PromotionPaid")
        .withArgs(payer.address, TOKEN, CODE_1H, PRICE_1H, (_t: any) => true);

      // Pull-payment: feeRecipient balance unchanged; factory holds the fee.
      expect(await ethers.provider.getBalance(feeRecipient.address)).to.equal(recBefore);
      expect(await promo.accumulatedFees()).to.equal(PRICE_1H);
      expect(await ethers.provider.getBalance(await promo.getAddress())).to.equal(PRICE_1H);
    });

    it("REFUNDS excess msg.value (no more silent-donation semantics, Sentinelle MED SC03)", async function () {
      const overpay = PRICE_6H + ethers.parseEther("0.001");

      const payerBefore = await ethers.provider.getBalance(payer.address);
      const tx = await promo.connect(payer).pay(TOKEN, CODE_6H, NO_MAX, { value: overpay });
      const receipt = await tx.wait();
      const gas = receipt!.gasUsed * receipt!.gasPrice;
      const payerAfter = await ethers.provider.getBalance(payer.address);

      // Payer spent only PRICE_6H + gas; excess refunded.
      expect(payerBefore - payerAfter - gas).to.equal(PRICE_6H);

      // Accumulated reflects only the price; excess never accrued.
      expect(await promo.accumulatedFees()).to.equal(PRICE_6H);
    });

    it("Reverts when price > maxPrice (Sentinelle MED SC03 slippage)", async function () {
      await expect(
        promo.connect(payer).pay(TOKEN, CODE_6H, PRICE_6H - 1n, { value: PRICE_6H }),
      ).to.be.revertedWith("Price exceeds maxPrice");
    });

    it("Reverts on token not a contract (Sentinelle MED SC04)", async function () {
      const eoa = ethers.Wallet.createRandom().address;
      await expect(
        promo.connect(payer).pay(eoa, CODE_1H, NO_MAX, { value: PRICE_1H }),
      ).to.be.revertedWith("Token not a contract");
    });

    it("Reverts on underpayment", async function () {
      await expect(
        promo.connect(payer).pay(TOKEN, CODE_1H, NO_MAX, { value: PRICE_1H - 1n }),
      ).to.be.revertedWith("Insufficient payment");
    });

    it("Reverts on unknown duration code", async function () {
      await expect(
        promo.connect(payer).pay(TOKEN, 99, NO_MAX, { value: PRICE_1H }),
      ).to.be.revertedWith("Unknown duration code");
    });

    it("Reverts on zero token address", async function () {
      await expect(
        promo.connect(payer).pay(ethers.ZeroAddress, CODE_1H, NO_MAX, { value: PRICE_1H }),
      ).to.be.revertedWith("Invalid token");
    });
  });

  describe("withdraw() — Sentinelle HIGH SC10 pull-payment", function () {
    it("Owner withdraws accumulated fees to feeRecipient, resets the counter", async function () {
      await promo.connect(payer).pay(TOKEN, CODE_1H, NO_MAX, { value: PRICE_1H });
      await promo.connect(payer).pay(TOKEN, CODE_6H, NO_MAX, { value: PRICE_6H });
      expect(await promo.accumulatedFees()).to.equal(PRICE_1H + PRICE_6H);

      const recBefore = await ethers.provider.getBalance(feeRecipient.address);
      await expect(promo.connect(owner).withdraw())
        .to.emit(promo, "FeesWithdrawn")
        .withArgs(feeRecipient.address, PRICE_1H + PRICE_6H);

      expect(await ethers.provider.getBalance(feeRecipient.address)).to.equal(
        recBefore + PRICE_1H + PRICE_6H,
      );
      expect(await promo.accumulatedFees()).to.equal(0n);
    });

    it("Reverts when nothing accrued", async function () {
      await expect(promo.connect(owner).withdraw()).to.be.revertedWith("No fees to withdraw");
    });

    it("Non-owner cannot withdraw", async function () {
      await promo.connect(payer).pay(TOKEN, CODE_1H, NO_MAX, { value: PRICE_1H });
      await expect(promo.connect(payer).withdraw()).to.be.reverted;
    });

    it("pay() still succeeds when feeRecipient is a reverting contract (old DoS vector)", async function () {
      // Use an EOA address that's actually a contract with no payable receive.
      // A fresh MockERC20 has no receive() → would revert if sent ETH.
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const reverter = await MockERC20.deploy("R", "R", 18, 0n);
      await promo.connect(owner).setFeeRecipient(await reverter.getAddress());

      // Pre-patch: this would have reverted because pay() push-called the
      // reverting recipient inside the same tx.
      await expect(
        promo.connect(payer).pay(TOKEN, CODE_1H, NO_MAX, { value: PRICE_1H }),
      ).to.not.be.reverted;

      // withdraw() would now revert (recipient is broken), but pay() works.
      await expect(promo.connect(owner).withdraw()).to.be.revertedWith("Withdraw failed");
    });
  });

  describe("setFeeRecipient", function () {
    it("Owner can update fee recipient", async function () {
      await expect(promo.connect(owner).setFeeRecipient(other.address))
        .to.emit(promo, "FeeRecipientUpdated")
        .withArgs(feeRecipient.address, other.address);
      expect(await promo.feeRecipient()).to.equal(other.address);
    });

    it("Rejects zero address", async function () {
      await expect(
        promo.connect(owner).setFeeRecipient(ethers.ZeroAddress),
      ).to.be.revertedWith("Invalid recipient");
    });

    it("Non-owner cannot update", async function () {
      await expect(promo.connect(payer).setFeeRecipient(other.address)).to.be.reverted;
    });
  });

  describe("Ownership", function () {
    it("Uses Ownable2Step (transfer + accept)", async function () {
      await promo.connect(owner).transferOwnership(other.address);
      expect(await promo.owner()).to.equal(owner.address);
      await promo.connect(other).acceptOwnership();
      expect(await promo.owner()).to.equal(other.address);
    });
  });
});
