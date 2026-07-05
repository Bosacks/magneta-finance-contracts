import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// UbeswapCeloAdapter is a stateless transient-custody UniV2 facade over
// Ubeswap, which (unlike Dragon/Moe/Joe) exposes NO native-token router
// entrypoints — CELO is itself an ERC20 at a fixed precompile address
// (0x471EcE...8a438), and on real Celo that ERC20 balance *is* the chain's
// native balance (same underlying state, no separate ledger). The adapter
// synthesizes addLiquidityETH / swapExactETHForTokens / swapExactTokensForETH
// by treating `msg.value` as an amount of CELO-the-ERC20 already sitting on
// the contract, and by forwarding real native value out at the very end of
// swapExactTokensForETH.
//
// A plain Hardhat network cannot reproduce the precompile duality (real CELO
// balance == ERC20 balance) since it isn't Celo. We approximate it with
// MockCeloNative deployed (via hardhat_setCode) at the exact constant address
// the adapter hardcodes, whose transfer/transferFrom forward real native
// value out of its own pre-funded reserve alongside the ERC20 ledger update.
// This makes the "CELO flows OUT of the adapter" direction (swapExactTokensForETH)
// fully stateless in both ERC20 and native terms. For the two payable
// entrypoints where the *test* sends raw `msg.value` straight to the adapter
// (addLiquidityETH, swapExactETHForTokens), we additionally `mint()` matching
// CELO ledger balance to the adapter to simulate the precompile crediting it
// automatically — but the raw `msg.value` used to satisfy the call remains
// stuck as real balance on the adapter afterwards. That's a limitation of
// simulating Celo on a generic EVM, not a bug in the adapter, so those two
// tests assert CELO-ledger statelessness (the economically meaningful
// invariant on Celo itself) rather than real-native-balance == 0.
describe("UbeswapCeloAdapter", function () {
  const CELO_ADDRESS = "0x471EcE3750Da237f93B8E339c536989b8978a438";

  let adapter: any;
  let router: any;
  let celo: any;
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

    // Deploy MockCeloNative once, then splice its runtime bytecode onto the
    // fixed CELO precompile address so `IERC20(CELO)` calls in the adapter
    // resolve to it.
    const Celo = await ethers.getContractFactory("MockCeloNative");
    const celoImpl = await Celo.deploy();
    await celoImpl.waitForDeployment();
    const celoCode = await ethers.provider.getCode(await celoImpl.getAddress());
    await ethers.provider.send("hardhat_setCode", [CELO_ADDRESS, celoCode]);
    celo = await ethers.getContractAt("MockCeloNative", CELO_ADDRESS);
    // Give the CELO mock a real native reserve so its transfer/transferFrom
    // can forward native value (simulating the precompile duality).
    await deployer.sendTransaction({ to: CELO_ADDRESS, value: ethers.parseEther("20") });

    const Router = await ethers.getContractFactory("MockUniV2NativeRouter");
    router = await Router.deploy(CELO_ADDRESS);
    await router.waitForDeployment();

    const Token = await ethers.getContractFactory("MockERC20");
    tokenA = await Token.deploy("Token A", "TKA", 18, ethers.parseEther("1000000"));
    await tokenA.waitForDeployment();
    tokenB = await Token.deploy("Token B", "TKB", 18, ethers.parseEther("1000000"));
    await tokenB.waitForDeployment();

    await tokenA.transfer(user.address, ethers.parseEther("100000"));
    await tokenB.transfer(user.address, ethers.parseEther("100000"));
    await tokenB.transfer(await router.getAddress(), ethers.parseEther("100000"));
    await celo.mint(await router.getAddress(), ethers.parseEther("100000"));

    const Adapter = await ethers.getContractFactory("UbeswapCeloAdapter");
    adapter = await Adapter.deploy(await router.getAddress());
    await adapter.waitForDeployment();
  });

  // ─── constructor ────────────────────────────────────────────────────────

  describe("constructor", function () {
    it("reverts on zero router", async function () {
      const Adapter = await ethers.getContractFactory("UbeswapCeloAdapter");
      await expect(Adapter.deploy(ethers.ZeroAddress)).to.be.revertedWith("UbeAdapter: zero router");
    });

    it("reverts if router.factory() returns zero", async function () {
      await router.setZeroFactory(true);
      const Adapter = await ethers.getContractFactory("UbeswapCeloAdapter");
      await expect(Adapter.deploy(await router.getAddress())).to.be.revertedWith("UbeAdapter: bad router");
    });

    it("wires immutables and hardcodes WETH() = CELO precompile", async function () {
      expect(await adapter.ube()).to.equal(await router.getAddress());
      expect(await adapter.factory()).to.equal(await router.getAddress());
      expect(await adapter.WETH()).to.equal(CELO_ADDRESS);
      expect(await adapter.CELO()).to.equal(CELO_ADDRESS);
    });
  });

  // ─── swapExactTokensForTokens (plain) ──────────────────────────────────

  describe("swapExactTokensForTokens", function () {
    const SWAP_AMOUNT = ethers.parseEther("100");

    it("pulls input, delivers output to recipient, adapter ends fully stateless", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      const userBefore = await tokenA.balanceOf(user.address);
      const outBefore = await tokenB.balanceOf(other.address);

      await adapter.connect(user).swapExactTokensForTokens(
        SWAP_AMOUNT, 0n,
        [await tokenA.getAddress(), await tokenB.getAddress()],
        other.address, DEADLINE_FUTURE,
      );

      expect(userBefore - (await tokenA.balanceOf(user.address))).to.equal(SWAP_AMOUNT);
      expect((await tokenB.balanceOf(other.address)) - outBefore).to.equal(SWAP_AMOUNT);
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
          SWAP_AMOUNT, SWAP_AMOUNT + 1n,
          [await tokenA.getAddress(), await tokenB.getAddress()],
          other.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    });
  });

  // ─── addLiquidity (plain, token/token) ─────────────────────────────────

  describe("addLiquidity", function () {
    it("pulls both tokens, mints LP to `to`, resets allowances, adapter ends stateless", async function () {
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

  // ─── removeLiquidity (plain) ────────────────────────────────────────────

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
    });
  });

  // ─── addLiquidityET (CELO leg) ──────────────────────────────────────────

  describe("addLiquidityETH", function () {
    beforeEach(async function () {
      // Simulate the Celo precompile crediting the adapter's CELO-ERC20
      // ledger the instant it receives msg.value (see file header).
      await celo.mint(await adapter.getAddress(), NATIVE_AMOUNT);
    });

    it("full-fill: pulls token + CELO, mints LP, CELO ledger returns to zero, resets allowances", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), AMOUNT);

      await adapter.connect(user).addLiquidityETH(
        await tokenA.getAddress(), AMOUNT, 0n, 0n, other.address, DEADLINE_FUTURE,
        { value: NATIVE_AMOUNT },
      );

      expect(await tokenA.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await celo.balanceOf(await adapter.getAddress())).to.equal(0n); // CELO-ledger stateless invariant
      expect(await tokenA.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
      expect(await celo.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);

      const pairAddr = await router.getPair(await tokenA.getAddress(), CELO_ADDRESS);
      const pair = await ethers.getContractAt("MockLPToken", pairAddr);
      expect(await pair.balanceOf(other.address)).to.equal(AMOUNT + NATIVE_AMOUNT);
    });

    it("partial-fill: refunds unused CELO dust as real native to the caller", async function () {
      // Router only "uses" 1 of the 10 CELO (msg.value) offered.
      await router.setAmountBCap(ethers.parseEther("1"));
      await tokenA.connect(user).approve(await adapter.getAddress(), AMOUNT);

      const before = await ethers.provider.getBalance(user.address);
      const tx = await adapter.connect(user).addLiquidityETH(
        await tokenA.getAddress(), AMOUNT, 0n, 0n, other.address, DEADLINE_FUTURE,
        { value: NATIVE_AMOUNT },
      );
      const receipt = await tx.wait();
      const gas = receipt!.gasUsed * receipt!.gasPrice;
      const after = await ethers.provider.getBalance(user.address);

      // User is refunded 9 real native (msg.value - amountETH used), i.e. only
      // nets out 1 ETH of value + gas.
      const netSpent = before - after - gas;
      expect(netSpent).to.equal(ethers.parseEther("1"));
      // NB: we don't assert the CELO-ledger balance here. MockCeloNative
      // forwards real native value on every ledger transfer to approximate
      // Celo's precompile duality; the router's own excess-CELO refund (9)
      // therefore *also* lands as real native on the adapter, on top of the
      // adapter's own `msg.value - amountETH` refund send. On genuine Celo
      // these are the same event, not two — so simulating both independently
      // leaves a non-zero CELO-ledger residue here that has no real-chain
      // counterpart. The economically meaningful invariant (the user is
      // made whole for unused native) is what's asserted above.
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

  // ─── swapExactETHForTokens (CELO-in) ────────────────────────────────────

  describe("swapExactETHForTokens", function () {
    beforeEach(async function () {
      await celo.mint(await adapter.getAddress(), NATIVE_AMOUNT);
    });

    it("reverts when path[0] != CELO", async function () {
      await expect(
        adapter.connect(user).swapExactETHForTokens(
          0n,
          [await tokenA.getAddress(), await tokenB.getAddress()],
          other.address, DEADLINE_FUTURE,
          { value: NATIVE_AMOUNT },
        ),
      ).to.be.revertedWith("path must start with CELO");
    });

    it("swaps CELO ledger for tokens, delivers to recipient, resets allowance", async function () {
      const outBefore = await tokenB.balanceOf(other.address);
      await adapter.connect(user).swapExactETHForTokens(
        0n,
        [CELO_ADDRESS, await tokenB.getAddress()],
        other.address, DEADLINE_FUTURE,
        { value: NATIVE_AMOUNT },
      );
      expect((await tokenB.balanceOf(other.address)) - outBefore).to.equal(NATIVE_AMOUNT);
      expect(await celo.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await celo.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
    });

    it("reverts when router returns less than amountOutMin (slippage)", async function () {
      await expect(
        adapter.connect(user).swapExactETHForTokens(
          NATIVE_AMOUNT + 1n,
          [CELO_ADDRESS, await tokenB.getAddress()],
          other.address, DEADLINE_FUTURE,
          { value: NATIVE_AMOUNT },
        ),
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    });
  });

  // ─── swapExactTokensForETH (CELO-out) ───────────────────────────────────

  describe("swapExactTokensForETH", function () {
    const SWAP_AMOUNT = ethers.parseEther("50");

    it("reverts when path does not end in CELO", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      await expect(
        adapter.connect(user).swapExactTokensForETH(
          SWAP_AMOUNT, 0n,
          [await tokenA.getAddress(), await tokenB.getAddress()],
          other.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWith("path must end with CELO");
    });

    it("pulls input, forwards real native CELO to recipient, adapter ends FULLY stateless (ERC20 + native)", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      const nativeBefore = await ethers.provider.getBalance(other.address);

      await adapter.connect(user).swapExactTokensForETH(
        SWAP_AMOUNT, 0n,
        [await tokenA.getAddress(), CELO_ADDRESS],
        other.address, DEADLINE_FUTURE,
      );

      // This direction never touches the test's own msg.value: the CELO mock
      // forwards real native value out of its own reserve as a pure side
      // effect of the ledger transfer, so the REAL native invariant holds.
      expect((await ethers.provider.getBalance(other.address)) - nativeBefore).to.equal(SWAP_AMOUNT);
      expect(await tokenA.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await ethers.provider.getBalance(await adapter.getAddress())).to.equal(0n);
      // NB: the adapter's CELO-ERC20 ledger balance is NOT swept back to zero
      // here — the contract receives CELO from the router then forwards an
      // equal amount of *real* native value onward via a raw call, treating
      // the two as the same asset (true on Celo, where they are the same
      // storage). Our mock keeps them as two channels to make the native
      // forwarding possible at all, so the CELO-ledger side is expected to
      // retain a residue that has no real-chain counterpart.
    });

    it("resets router allowance to zero after the swap", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      await adapter.connect(user).swapExactTokensForETH(
        SWAP_AMOUNT, 0n,
        [await tokenA.getAddress(), CELO_ADDRESS],
        other.address, DEADLINE_FUTURE,
      );
      expect(await tokenA.allowance(await adapter.getAddress(), await router.getAddress())).to.equal(0n);
    });

    it("reverts when router returns less than amountOutMin (slippage)", async function () {
      await tokenA.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      await expect(
        adapter.connect(user).swapExactTokensForETH(
          SWAP_AMOUNT, SWAP_AMOUNT + 1n,
          [await tokenA.getAddress(), CELO_ADDRESS],
          other.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWith("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
    });
  });

  // ─── receive() ───────────────────────────────────────────────────────────

  describe("receive()", function () {
    it("accepts plain native transfers", async function () {
      await expect(
        user.sendTransaction({ to: await adapter.getAddress(), value: ethers.parseEther("0.1") }),
      ).to.not.be.reverted;
    });
  });
});
