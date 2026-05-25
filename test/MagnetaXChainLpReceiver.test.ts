import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * Unit tests for MagnetaXChainLpReceiver — the permissionless destination-chain
 * receiver that turns LI.FI-bridged native into a token/native V2 LP position.
 *
 * The receiver is exercised through MockLpReceiverRouter, a configurable
 * V2-router stand-in that can be dialed to leave token/native dust and to
 * under/over-deliver on the swap, so the dust-refund and donation-safety paths
 * are covered (the always-1:1 MockV2Router cannot).
 */
describe("MagnetaXChainLpReceiver", () => {
  let owner: SignerWithAddress;
  let user: SignerWithAddress;     // LP recipient (`to`)
  let executor: SignerWithAddress; // stands in for the LI.FI executor (caller)
  let stranger: SignerWithAddress;

  let weth: any;
  let token: any;
  let router: any;
  let receiver: any;
  let lp: any;

  const ONE = ethers.parseEther("1");

  beforeEach(async () => {
    [owner, user, executor, stranger] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    weth = await MockERC20.deploy("WETH", "WETH", 18, 0);
    token = await MockERC20.deploy("Magneta Token", "MAG", 18, 0);

    const Router = await ethers.getContractFactory("MockLpReceiverRouter");
    router = await Router.deploy(await weth.getAddress());

    const lpAddr = await router.lp();
    lp = await ethers.getContractAt("MockReceiverLP", lpAddr);

    const Receiver = await ethers.getContractFactory("MagnetaXChainLpReceiver");
    receiver = await Receiver.connect(owner).deploy(
      await router.getAddress(),
      await weth.getAddress()
    );

    // Fund the router with `token` so swapExactETHForTokens can pay out.
    await token.mint(await router.getAddress(), ethers.parseEther("1000000"));
  });

  describe("constructor", () => {
    it("stores router + wnative", async () => {
      expect(await receiver.router()).to.equal(await router.getAddress());
      expect(await receiver.wnative()).to.equal(await weth.getAddress());
    });

    it("reverts on zero router/wnative", async () => {
      const Receiver = await ethers.getContractFactory("MagnetaXChainLpReceiver");
      await expect(
        Receiver.deploy(ethers.ZeroAddress, await weth.getAddress())
      ).to.be.revertedWithCustomError(receiver, "ZeroAddress");
      await expect(
        Receiver.deploy(await router.getAddress(), ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(receiver, "ZeroAddress");
    });

    it("reverts when wnative != router.WETH()", async () => {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const other = await MockERC20.deploy("Other", "OTH", 18, 0);
      const Receiver = await ethers.getContractFactory("MagnetaXChainLpReceiver");
      await expect(
        Receiver.deploy(await router.getAddress(), await other.getAddress())
      ).to.be.revertedWith("router/WETH mismatch");
    });
  });

  describe("addLiquidityNative — happy path", () => {
    it("swaps half, adds liquidity, mints LP to `to`", async () => {
      const tokenAddr = await token.getAddress();
      const value = ONE; // 1 native

      await expect(
        receiver.connect(executor).addLiquidityNative(
          tokenAddr, user.address, 0, 0, 0, ethers.MaxUint256, { value }
        )
      ).to.emit(receiver, "LpAdded");

      // 1:1 swap on half (0.5) → 0.5 token; addLiquidity consumes all → LP to user.
      expect(await lp.balanceOf(user.address)).to.be.gt(0n);
      // Receiver keeps nothing.
      expect(await ethers.provider.getBalance(await receiver.getAddress())).to.equal(0n);
      expect(await token.balanceOf(await receiver.getAddress())).to.equal(0n);
    });

    it("LP goes to `to`, not to the caller (executor)", async () => {
      await receiver.connect(executor).addLiquidityNative(
        await token.getAddress(), user.address, 0, 0, 0, ethers.MaxUint256, { value: ONE }
      );
      expect(await lp.balanceOf(user.address)).to.be.gt(0n);
      expect(await lp.balanceOf(executor.address)).to.equal(0n);
    });

    it("returns (amountToken, amountNative, liquidity)", async () => {
      const res = await receiver.connect(executor).addLiquidityNative.staticCall(
        await token.getAddress(), user.address, 0, 0, 0, ethers.MaxUint256, { value: ONE }
      );
      expect(res[0]).to.be.gt(0n); // amountToken
      expect(res[1]).to.be.gt(0n); // amountNative
      expect(res[2]).to.be.gt(0n); // liquidity
    });
  });

  describe("input validation", () => {
    it("reverts on zero msg.value", async () => {
      await expect(
        receiver.connect(executor).addLiquidityNative(
          await token.getAddress(), user.address, 0, 0, 0, ethers.MaxUint256, { value: 0 }
        )
      ).to.be.revertedWithCustomError(receiver, "ZeroValue");
    });

    it("reverts on zero `to`", async () => {
      await expect(
        receiver.connect(executor).addLiquidityNative(
          await token.getAddress(), ethers.ZeroAddress, 0, 0, 0, ethers.MaxUint256, { value: ONE }
        )
      ).to.be.revertedWithCustomError(receiver, "ZeroAddress");
    });

    it("reverts when token is the native sentinel (zero)", async () => {
      await expect(
        receiver.connect(executor).addLiquidityNative(
          ethers.ZeroAddress, user.address, 0, 0, 0, ethers.MaxUint256, { value: ONE }
        )
      ).to.be.revertedWithCustomError(receiver, "TokenIsNative");
    });

    it("reverts when token is an EOA (not a contract)", async () => {
      await expect(
        receiver.connect(executor).addLiquidityNative(
          stranger.address, user.address, 0, 0, 0, ethers.MaxUint256, { value: ONE }
        )
      ).to.be.revertedWithCustomError(receiver, "NotAContract");
    });
  });

  describe("slippage protection (caller-supplied mins)", () => {
    it("reverts when swap output < minTokenOut", async () => {
      // 1 native, half = 0.5 swapped 1:1 → 0.5 token. Demand 1 token out.
      await expect(
        receiver.connect(executor).addLiquidityNative(
          await token.getAddress(), user.address, ethers.parseEther("1"), 0, 0, ethers.MaxUint256, { value: ONE }
        )
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_OUTPUT");
    });

    it("reverts when addLiquidity token < minTokenLp", async () => {
      await router.setTokenConsumeBps(5_000); // consume only half the token
      await expect(
        receiver.connect(executor).addLiquidityNative(
          await token.getAddress(), user.address, 0, ethers.parseEther("0.4"), 0, ethers.MaxUint256, { value: ONE }
        )
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_TOKEN");
    });

    it("reverts when addLiquidity native < minNativeLp", async () => {
      await router.setEthConsumeBps(5_000); // consume only half the native
      await expect(
        receiver.connect(executor).addLiquidityNative(
          await token.getAddress(), user.address, 0, 0, ethers.parseEther("0.4"), ethers.MaxUint256, { value: ONE }
        )
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_ETH");
    });
  });

  describe("dust refund", () => {
    it("refunds leftover token to `to` when router under-consumes token", async () => {
      await router.setTokenConsumeBps(8_000); // 20% token left as dust
      const before = await token.balanceOf(user.address);
      await receiver.connect(executor).addLiquidityNative(
        await token.getAddress(), user.address, 0, 0, 0, ethers.MaxUint256, { value: ONE }
      );
      // 0.5 token swapped, 80% (0.4) into LP, 0.1 dust → user.
      expect(await token.balanceOf(user.address)).to.equal(before + ethers.parseEther("0.1"));
      expect(await token.balanceOf(await receiver.getAddress())).to.equal(0n);
    });

    it("refunds leftover native to `to` when router under-consumes native", async () => {
      await router.setEthConsumeBps(6_000); // 40% of the LP-half native refunded
      const before = await ethers.provider.getBalance(user.address);
      await receiver.connect(executor).addLiquidityNative(
        await token.getAddress(), user.address, 0, 0, 0, ethers.MaxUint256, { value: ONE }
      );
      // LP half = 0.5 native; 60% consumed → 0.2 refunded to user (user pays no gas, executor does).
      expect(await ethers.provider.getBalance(user.address)).to.equal(before + ethers.parseEther("0.2"));
      expect(await ethers.provider.getBalance(await receiver.getAddress())).to.equal(0n);
    });
  });

  describe("donation safety", () => {
    it("does not refund pre-existing native donations", async () => {
      // Grief: donate 5 native to the receiver beforehand.
      await stranger.sendTransaction({ to: await receiver.getAddress(), value: ethers.parseEther("5") });
      await router.setEthConsumeBps(6_000); // create a small native dust this tx

      const userBefore = await ethers.provider.getBalance(user.address);
      await receiver.connect(executor).addLiquidityNative(
        await token.getAddress(), user.address, 0, 0, 0, ethers.MaxUint256, { value: ONE }
      );

      // User receives only THIS tx's dust (0.2), not the 5-native donation.
      expect(await ethers.provider.getBalance(user.address)).to.equal(userBefore + ethers.parseEther("0.2"));
      // Donation remains stuck in the contract (rescuable by owner only).
      expect(await ethers.provider.getBalance(await receiver.getAddress())).to.equal(ethers.parseEther("5"));
    });

    it("does not pair pre-existing token donations into the LP or refund them", async () => {
      // Grief: donate token to the receiver beforehand.
      await token.mint(await receiver.getAddress(), ethers.parseEther("3"));
      await router.setTokenConsumeBps(8_000); // 0.1 token dust this tx

      const userBefore = await token.balanceOf(user.address);
      await receiver.connect(executor).addLiquidityNative(
        await token.getAddress(), user.address, 0, 0, 0, ethers.MaxUint256, { value: ONE }
      );

      // User gets only this tx's token dust (0.1); the 3-token donation stays put.
      expect(await token.balanceOf(user.address)).to.equal(userBefore + ethers.parseEther("0.1"));
      expect(await token.balanceOf(await receiver.getAddress())).to.equal(ethers.parseEther("3"));
    });
  });

  describe("owner rescue", () => {
    it("owner can rescue stuck native (e.g. a donation)", async () => {
      await stranger.sendTransaction({ to: await receiver.getAddress(), value: ethers.parseEther("2") });
      await expect(
        receiver.connect(owner).rescueNative(owner.address, ethers.parseEther("2"))
      ).to.emit(receiver, "Rescued").withArgs(ethers.ZeroAddress, owner.address, ethers.parseEther("2"));
      expect(await ethers.provider.getBalance(await receiver.getAddress())).to.equal(0n);
    });

    it("owner can rescue stuck ERC20", async () => {
      await token.mint(await receiver.getAddress(), ethers.parseEther("4"));
      await receiver.connect(owner).rescueERC20(await token.getAddress(), owner.address, ethers.parseEther("4"));
      expect(await token.balanceOf(owner.address)).to.equal(ethers.parseEther("4"));
    });

    it("non-owner cannot rescue", async () => {
      await stranger.sendTransaction({ to: await receiver.getAddress(), value: ONE });
      await expect(
        receiver.connect(stranger).rescueNative(stranger.address, ONE)
      ).to.be.revertedWith("Ownable: caller is not the owner");
      await expect(
        receiver.connect(stranger).rescueERC20(await token.getAddress(), stranger.address, 0)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("rescue reverts on zero token/recipient", async () => {
      await expect(
        receiver.connect(owner).rescueERC20(ethers.ZeroAddress, owner.address, 0)
      ).to.be.revertedWithCustomError(receiver, "ZeroAddress");
      await expect(
        receiver.connect(owner).rescueNative(ethers.ZeroAddress, 0)
      ).to.be.revertedWithCustomError(receiver, "ZeroAddress");
    });
  });

  describe("ownership (Ownable2Step)", () => {
    it("transfer is two-step", async () => {
      await receiver.connect(owner).transferOwnership(user.address);
      expect(await receiver.owner()).to.equal(owner.address);     // not yet
      expect(await receiver.pendingOwner()).to.equal(user.address);
      await receiver.connect(user).acceptOwnership();
      expect(await receiver.owner()).to.equal(user.address);
    });
  });
});
