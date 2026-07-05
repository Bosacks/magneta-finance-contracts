import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// MoeRouterAdapter is a stateless transient-custody UniV2 facade: pull
// tokens/native in -> approve router -> call Merchant Moe (wNative/addLiquidityNative/
// swapExactNativeForTokens/swapExactTokensForNative naming) -> refund dust -> reset
// allowance to zero. This suite backs it with MockUniV2NativeRouter, which
// implements the Native-named entrypoints against a shared, configurable mock AMM.
describe("MoeRouterAdapter", function () {
  let adapter: any;
  let router: any;
  let weth: any;
  let tokenA: any;
  let tokenB: any;
  let deployer: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let other: HardhatEthersSigner;

  const AMOUNT = ethers.parseEther("1000");
  const NATIVE_AMOUNT = ethers.parseEther("10");
  let DEADLINE_FUTURE: number;
  let DEADLINE_PAST: number;

  beforeEach(async function () {
    [deployer, user, other] = await ethers.getSigners();
    const nowBlock = await ethers.provider.getBlock("latest");
    const now = nowBlock!.timestamp;
    DEADLINE_FUTURE = now + 3600;
    DEADLINE_PAST = now - 3600;

    const WETH = await ethers.getContractFactory("MockWETH");
    weth = await WETH.deploy();
    await weth.waitForDeployment();

    const Router = await ethers.getContractFactory("MockUniV2NativeRouter");
    router = await Router.deploy(await weth.getAddress());
    await router.waitForDeployment();

    const Token = await ethers.getContractFactory("MockERC20");
    tokenA = await Token.deploy("Token A", "TKA", 18, ethers.parseEther("1000000"));
    await tokenA.waitForDeployment();
    tokenB = await Token.deploy("Token B", "TKB", 18, ethers.parseEther("1000000"));
    await tokenB.waitForDeployment();

    await tokenA.transfer(user.address, ethers.parseEther("100000"));
    await tokenB.transfer(user.address, ethers.parseEther("100000"));

    // Fund the router so token->native swaps can pay out, and give it some
    // of tokenB so token->token swaps have output liquidity.
    await deployer.sendTransaction({ to: await router.getAddress(), value: ethers.parseEther("50") });
    await tokenB.transfer(await router.getAddress(), ethers.parseEther("100000"));

    const Adapter = await ethers.getContractFactory("MoeRouterAdapter");
    adapter = await Adapter.deploy(await router.getAddress());
    await adapter.waitForDeployment();
  });

  // ─── constructor ────────────────────────────────────────────────────────

  describe("constructor", function () {
    it("reverts on zero router", async function () {
      const Adapter = await ethers.getContractFactory("MoeRouterAdapter");
      await expect(Adapter.deploy(ethers.ZeroAddress)).to.be.revertedWith("MoeAdapter: zero router");
    });

    it("reverts if router.factory() returns zero", async function () {
      await router.setZeroFactory(true);
      const Adapter = await ethers.getContractFactory("MoeRouterAdapter");
      await expect(Adapter.deploy(await router.getAddress())).to.be.revertedWith("MoeAdapter: bad router");
    });

    it("reverts if router.wNative() returns zero", async function () {
      const Router = await ethers.getContractFactory("MockUniV2NativeRouter");
      const badRouter = await Router.deploy(ethers.ZeroAddress);
      await badRouter.waitForDeployment();
      const Adapter = await ethers.getContractFactory("MoeRouterAdapter");
      await expect(Adapter.deploy(await badRouter.getAddress())).to.be.revertedWith("MoeAdapter: bad router");
    });

    it("wires immutables from the router", async function () {
      expect(await adapter.moe()).to.equal(await router.getAddress());
      expect(await adapter.factory()).to.equal(await router.getAddress()); // mock: factory() == router itself
      expect(await adapter.WETH()).to.equal(await weth.getAddress());
    });
  });

  // ─── swapExactTokensForTokens ───────────────────────────────────────────

  describe("swapExactTokensForTokens", function () {
    const SWAP_AMOUNT = ethers.parseEther("100");

    it("pulls input, delivers output to recipient, adapter ends stateless", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      const userBefore = await tokenA.balanceOf(user.address);
      const outBefore = await tokenB.balanceOf(other.address);

      await adapter.connect(user).swapExactTokensForTokens(
        SWAP_AMOUNT, 0n,
        [await tokenA.getAddress(), await tokenB.getAddress()],
        other.address, DEADLINE_FUTURE,
      );

      expect(userBefore - (await tokenA.balanceOf(user.address))).to.equal(SWAP_AMOUNT);
      expect((await tokenB.balanceOf(other.address)) - outBefore).to.equal(SWAP_AMOUNT); // 1:1 mock rate

      // Stateless invariant: adapter holds zero of both tokens and zero native.
      expect(await tokenA.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await tokenB.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await ethers.provider.getBalance(await adapter.getAddress())).to.equal(0n);
    });

    it("resets router allowance to zero after the swap", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      await adapter.connect(user).swapExactTokensForTokens(
        SWAP_AMOUNT, 0n,
        [await tokenA.getAddress(), await tokenB.getAddress()],
        other.address, DEADLINE_FUTURE,
      );
      expect(await tokenA.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
    });

    it("reverts when router returns less than amountOutMin (slippage)", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      await expect(
        adapter.connect(user).swapExactTokensForTokens(
          SWAP_AMOUNT, SWAP_AMOUNT + 1n, // demand more than the 1:1 mock rate delivers
          [await tokenA.getAddress(), await tokenB.getAddress()],
          other.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    });

    it("reverts without allowance from the user", async function () {
      await expect(
        adapter.connect(user).swapExactTokensForTokens(
          SWAP_AMOUNT, 0n,
          [await tokenA.getAddress(), await tokenB.getAddress()],
          other.address, DEADLINE_FUTURE,
        ),
      ).to.be.reverted;
    });
  });

  // ─── swapExactETHForTokens (native in) ──────────────────────────────────

  describe("swapExactETHForTokens", function () {
    it("forwards msg.value and delivers output to recipient", async function () {
      const value = ethers.parseEther("1");
      const outBefore = await tokenB.balanceOf(other.address);

      await adapter.connect(user).swapExactETHForTokens(
        0n,
        [await weth.getAddress(), await tokenB.getAddress()],
        other.address, DEADLINE_FUTURE,
        { value },
      );

      expect((await tokenB.balanceOf(other.address)) - outBefore).to.equal(value);
      expect(await ethers.provider.getBalance(await adapter.getAddress())).to.equal(0n);
    });

    it("reverts when router returns less than amountOutMin (slippage)", async function () {
      const value = ethers.parseEther("1");
      await expect(
        adapter.connect(user).swapExactETHForTokens(
          value + 1n,
          [await weth.getAddress(), await tokenB.getAddress()],
          other.address, DEADLINE_FUTURE,
          { value },
        ),
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    });
  });

  // ─── swapExactTokensForETH (native out) ─────────────────────────────────

  describe("swapExactTokensForETH", function () {
    const SWAP_AMOUNT = ethers.parseEther("50");

    it("pulls input, delivers native to recipient, adapter ends stateless", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      const nativeBefore = await ethers.provider.getBalance(other.address);

      await adapter.connect(user).swapExactTokensForETH(
        SWAP_AMOUNT, 0n,
        [await tokenA.getAddress(), await weth.getAddress()],
        other.address, DEADLINE_FUTURE,
      );

      expect((await ethers.provider.getBalance(other.address)) - nativeBefore).to.equal(SWAP_AMOUNT);
      expect(await tokenA.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await ethers.provider.getBalance(await adapter.getAddress())).to.equal(0n);
    });

    it("resets router allowance to zero after the swap", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      await adapter.connect(user).swapExactTokensForETH(
        SWAP_AMOUNT, 0n,
        [await tokenA.getAddress(), await weth.getAddress()],
        other.address, DEADLINE_FUTURE,
      );
      expect(await tokenA.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
    });

    it("reverts when router returns less than amountOutMin (slippage)", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      await expect(
        adapter.connect(user).swapExactTokensForETH(
          SWAP_AMOUNT, SWAP_AMOUNT + 1n,
          [await tokenA.getAddress(), await weth.getAddress()],
          other.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    });
  });

  // ─── addLiquidity (token/token) ──────────────────────────────────────────

  describe("addLiquidity", function () {
    it("pulls both tokens, mints LP to `to`, refunds unused desired amounts, resets allowances", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), AMOUNT);
      await tokenB.connect(user).approve(await adapter.getAddress(), AMOUNT);

      await adapter.connect(user).addLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        AMOUNT, AMOUNT, 0n, 0n, other.address, DEADLINE_FUTURE,
      );

      expect(await tokenA.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
      expect(await tokenB.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
      expect(await tokenA.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await tokenB.balanceOf(await adapter.getAddress())).to.equal(0n);

      const pairAddr = await router.getPair(await tokenA.getAddress(), await tokenB.getAddress());
      const pair = await ethers.getContractAt("MockLPToken", pairAddr);
      expect(await pair.balanceOf(other.address)).to.equal(AMOUNT + AMOUNT);
    });
  });

  // ─── addLiquidityETH — dust/refund behaviour ────────────────────────────

  describe("addLiquidityETH", function () {
    it("full-fill: consumes exactly msg.value, no refund, adapter ends stateless", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), AMOUNT);
      const before = await ethers.provider.getBalance(user.address);

      const tx = await adapter.connect(user).addLiquidityETH(
        await tokenA.getAddress(), AMOUNT, 0n, 0n, user.address, DEADLINE_FUTURE,
        { value: NATIVE_AMOUNT },
      );
      const receipt = await tx.wait();
      const gas = receipt!.gasUsed * receipt!.gasPrice;
      const after = await ethers.provider.getBalance(user.address);

      // Entire NATIVE_AMOUNT spent, only gas leaves the user's balance beyond that.
      expect(before - after - gas).to.equal(NATIVE_AMOUNT);
      expect(await tokenA.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await ethers.provider.getBalance(await adapter.getAddress())).to.equal(0n);
      expect(await tokenA.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
    });

    it("partial-fill: refunds unused native dust to the caller (not `to`)", async function () {
      await router.setNativeCap(ethers.parseEther("1")); // router only "uses" 1 of the 10 native sent
      await tokenA.connect(user).approve(await adapter.getAddress(), AMOUNT);

      const before = await ethers.provider.getBalance(user.address);
      const tx = await adapter.connect(user).addLiquidityETH(
        await tokenA.getAddress(), AMOUNT, 0n, 0n, other.address, DEADLINE_FUTURE,
        { value: NATIVE_AMOUNT },
      );
      const receipt = await tx.wait();
      const gas = receipt!.gasUsed * receipt!.gasPrice;
      const after = await ethers.provider.getBalance(user.address);

      // User only net-spends the 1 native actually used; 9 native refunded.
      expect(before - after - gas).to.equal(ethers.parseEther("1"));
      expect(await ethers.provider.getBalance(await adapter.getAddress())).to.equal(0n);
    });

    it("reverts on past deadline", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), AMOUNT);
      await expect(
        adapter.connect(user).addLiquidityETH(
          await tokenA.getAddress(), AMOUNT, 0n, 0n, user.address, DEADLINE_PAST,
          { value: NATIVE_AMOUNT },
        ),
      ).to.be.revertedWith("MockRouter: expired");
    });
  });

  // ─── removeLiquidity ─────────────────────────────────────────────────────

  describe("removeLiquidity", function () {
    it("reverts when no pair exists", async function () {
      await expect(
        adapter.connect(user).removeLiquidity(
          await tokenA.getAddress(), await tokenB.getAddress(),
          1n, 0n, 0n, user.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWith("no pair");
    });

    it("burns LP, returns underlying tokens, resets allowance", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), AMOUNT);
      await tokenB.connect(user).approve(await adapter.getAddress(), AMOUNT);
      await adapter.connect(user).addLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        AMOUNT, AMOUNT, 0n, 0n, user.address, DEADLINE_FUTURE,
      );

      const pairAddr = await router.getPair(await tokenA.getAddress(), await tokenB.getAddress());
      const pair = await ethers.getContractAt("MockLPToken", pairAddr);
      const liquidity = await pair.balanceOf(user.address);
      await pair.connect(user).approve(await adapter.getAddress(), liquidity);

      await adapter.connect(user).removeLiquidity(
        await tokenA.getAddress(), await tokenB.getAddress(),
        liquidity, 0n, 0n, other.address, DEADLINE_FUTURE,
      );

      expect(await pair.balanceOf(user.address)).to.equal(0n);
      expect(await pair.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
      expect(await tokenA.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await tokenB.balanceOf(await adapter.getAddress())).to.equal(0n);
    });
  });

  // ─── receive() ───────────────────────────────────────────────────────────

  describe("receive()", function () {
    it("accepts plain native transfers (used for router dust refunds)", async function () {
      await expect(
        user.sendTransaction({ to: await adapter.getAddress(), value: ethers.parseEther("0.1") }),
      ).to.not.be.reverted;
    });
  });
});
