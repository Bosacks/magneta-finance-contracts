import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("BexBerachainAdapter — Balancer V2 fork facade", function () {
  let adapter: any;
  let vault: any;
  let poolFactory: any;
  let weth: any;
  let token: any;
  let deployer: HardhatEthersSigner;
  let user: HardhatEthersSigner;
  let other: HardhatEthersSigner;

  // Test amounts
  const TOKEN_AMOUNT = ethers.parseEther("1000");
  const ETH_AMOUNT = ethers.parseEther("10");
  const DEADLINE_FUTURE = Math.floor(Date.now() / 1000) + 3600;
  const DEADLINE_PAST = Math.floor(Date.now() / 1000) - 3600;

  beforeEach(async function () {
    [deployer, user, other] = await ethers.getSigners();

    // ── Mocks ──
    const Vault = await ethers.getContractFactory("MockBexVault");
    vault = await Vault.deploy();
    await vault.waitForDeployment();

    const PoolFactory = await ethers.getContractFactory("MockBexWeightedPoolFactory");
    poolFactory = await PoolFactory.deploy(await vault.getAddress());
    await poolFactory.waitForDeployment();

    const WETH = await ethers.getContractFactory("MockWETH");
    weth = await WETH.deploy();
    await weth.waitForDeployment();

    const Token = await ethers.getContractFactory("MockERC20");
    token = await Token.deploy("Test", "TST", 18, ethers.parseEther("1000000"));
    await token.waitForDeployment();
    // Pass tokens to the user
    await token.transfer(user.address, ethers.parseEther("500000"));

    // ── Adapter ──
    const Adapter = await ethers.getContractFactory("BexBerachainAdapter");
    adapter = await Adapter.deploy(
      await vault.getAddress(),
      await poolFactory.getAddress(),
      await weth.getAddress(),
    );
    await adapter.waitForDeployment();
  });

  // ─── Constructor ──────────────────────────────────────────────────────

  describe("constructor", function () {
    it("rejects zero vault", async function () {
      const Adapter = await ethers.getContractFactory("BexBerachainAdapter");
      await expect(Adapter.deploy(
        ethers.ZeroAddress, await poolFactory.getAddress(), await weth.getAddress(),
      )).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });
    it("rejects zero pool factory", async function () {
      const Adapter = await ethers.getContractFactory("BexBerachainAdapter");
      await expect(Adapter.deploy(
        await vault.getAddress(), ethers.ZeroAddress, await weth.getAddress(),
      )).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });
    it("rejects zero WETH/WBERA", async function () {
      const Adapter = await ethers.getContractFactory("BexBerachainAdapter");
      await expect(Adapter.deploy(
        await vault.getAddress(), await poolFactory.getAddress(), ethers.ZeroAddress,
      )).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });
    it("sets immutables + owner", async function () {
      expect(await adapter.vault()).to.equal(await vault.getAddress());
      expect(await adapter.poolFactory()).to.equal(await poolFactory.getAddress());
      expect(await adapter.WETH()).to.equal(await weth.getAddress());
      expect(await adapter.owner()).to.equal(deployer.address);
      expect(await adapter.factory()).to.equal(await adapter.getAddress());
    });
  });

  // ─── addLiquidityETH ──────────────────────────────────────────────────

  describe("addLiquidityETH", function () {
    it("reverts on past deadline", async function () {
      await expect(
        adapter.connect(user).addLiquidityETH(
          await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_PAST,
          { value: ETH_AMOUNT },
        ),
      ).to.be.revertedWithCustomError(adapter, "DeadlinePassed");
    });

    it("reverts on zero token address", async function () {
      await expect(
        adapter.connect(user).addLiquidityETH(
          ethers.ZeroAddress, TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
          { value: ETH_AMOUNT },
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("reverts on zero recipient", async function () {
      await expect(
        adapter.connect(user).addLiquidityETH(
          await token.getAddress(), TOKEN_AMOUNT, 0, 0, ethers.ZeroAddress, DEADLINE_FUTURE,
          { value: ETH_AMOUNT },
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("reverts on zero amounts", async function () {
      await expect(
        adapter.connect(user).addLiquidityETH(
          await token.getAddress(), 0, 0, 0, user.address, DEADLINE_FUTURE,
          { value: ETH_AMOUNT },
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAmount");
      await expect(
        adapter.connect(user).addLiquidityETH(
          await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
          { value: 0 },
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAmount");
    });

    // Sentinelle MEDIUM SC06 mitigation: token-frontrun guard
    it("reverts when token has no code (Sentinelle token-frontrun mitigation)", async function () {
      const fakeToken = "0x000000000000000000000000000000000000dEaD";
      await expect(
        adapter.connect(user).addLiquidityETH(
          fakeToken, TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
          { value: ETH_AMOUNT },
        ),
      ).to.be.revertedWithCustomError(adapter, "TokenNotDeployed");
    });

    it("lazily creates pool + emits PairCreated on first add", async function () {
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      // Before: no pair registered
      expect(await adapter.getPair(await token.getAddress(), await weth.getAddress())).to.equal(ethers.ZeroAddress);

      const tx = await adapter.connect(user).addLiquidityETH(
        await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
        { value: ETH_AMOUNT },
      );
      await expect(tx).to.emit(adapter, "PairCreated");

      // After: pool registered in both orderings
      const pool = await adapter.getPair(await token.getAddress(), await weth.getAddress());
      expect(pool).to.not.equal(ethers.ZeroAddress);
      expect(await adapter.getPair(await weth.getAddress(), await token.getAddress())).to.equal(pool);
    });

    it("creates pool with sorted assets + 50/50 weights + 0.30% fee", async function () {
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      await adapter.connect(user).addLiquidityETH(
        await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
        { value: ETH_AMOUNT },
      );

      const [name, symbol, tokens, weights, fee, owner_, salt] = await poolFactory.getLastCreate();
      // Tokens sorted by address ASC
      const tokenAddr = await token.getAddress();
      const wethAddr = await weth.getAddress();
      const [t0, t1] = tokenAddr.toLowerCase() < wethAddr.toLowerCase() ? [tokenAddr, wethAddr] : [wethAddr, tokenAddr];
      expect(tokens[0].toLowerCase()).to.equal(t0.toLowerCase());
      expect(tokens[1].toLowerCase()).to.equal(t1.toLowerCase());
      // 50/50 weights
      expect(weights[0]).to.equal(ethers.parseEther("0.5"));
      expect(weights[1]).to.equal(ethers.parseEther("0.5"));
      // SWAP_FEE = 0.3% = 3e15
      expect(fee).to.equal(3000000000000000n);
      // Owner is the adapter
      expect(owner_).to.equal(await adapter.getAddress());
      // Salt is zero
      expect(salt).to.equal(ethers.ZeroHash);
    });

    it("emits LPAdded with correct args", async function () {
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      await expect(
        adapter.connect(user).addLiquidityETH(
          await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
          { value: ETH_AMOUNT },
        ),
      ).to.emit(adapter, "LPAdded");
    });

    it("mints BPT to recipient (not msg.sender)", async function () {
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      await adapter.connect(user).addLiquidityETH(
        await token.getAddress(), TOKEN_AMOUNT, 0, 0, other.address, DEADLINE_FUTURE,
        { value: ETH_AMOUNT },
      );

      const pool = await adapter.getPair(await token.getAddress(), await weth.getAddress());
      const Pool = await ethers.getContractAt("MockBexPool", pool);
      expect(await Pool.balanceOf(other.address)).to.equal(await vault.BPT_PER_JOIN());
      expect(await Pool.balanceOf(user.address)).to.equal(0n);
    });

    it("reuses existing pool on second add (no PairCreated)", async function () {
      // First add
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      await adapter.connect(user).addLiquidityETH(
        await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
        { value: ETH_AMOUNT },
      );
      const pool1 = await adapter.getPair(await token.getAddress(), await weth.getAddress());

      // Second add — same pool
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      const tx = await adapter.connect(user).addLiquidityETH(
        await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
        { value: ETH_AMOUNT },
      );
      await expect(tx).to.not.emit(adapter, "PairCreated");
      const pool2 = await adapter.getPair(await token.getAddress(), await weth.getAddress());
      expect(pool1).to.equal(pool2);
    });
  });

  // ─── removeLiquidity ──────────────────────────────────────────────────

  describe("removeLiquidity", function () {
    let pool: string;

    beforeEach(async function () {
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      await adapter.connect(user).addLiquidityETH(
        await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
        { value: ETH_AMOUNT },
      );
      pool = await adapter.getPair(await token.getAddress(), await weth.getAddress());
    });

    it("reverts on past deadline", async function () {
      await expect(
        adapter.connect(user).removeLiquidity(
          await token.getAddress(), await weth.getAddress(),
          1n, 0n, 0n, user.address, DEADLINE_PAST,
        ),
      ).to.be.revertedWithCustomError(adapter, "DeadlinePassed");
    });

    it("reverts on tokenB != WETH", async function () {
      await expect(
        adapter.connect(user).removeLiquidity(
          await token.getAddress(), other.address,
          1n, 0n, 0n, user.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWith("BexAdapter: tokenB must be WBERA (V1 scope)");
    });

    it("reverts on zero recipient", async function () {
      await expect(
        adapter.connect(user).removeLiquidity(
          await token.getAddress(), await weth.getAddress(),
          1n, 0n, 0n, ethers.ZeroAddress, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("reverts on zero liquidity", async function () {
      await expect(
        adapter.connect(user).removeLiquidity(
          await token.getAddress(), await weth.getAddress(),
          0n, 0n, 0n, user.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAmount");
    });

    it("reverts when pool doesn't exist", async function () {
      const ghostToken = await (await ethers.getContractFactory("MockERC20")).deploy("Ghost", "GHO", 18, 0n);
      await expect(
        adapter.connect(user).removeLiquidity(
          await ghostToken.getAddress(), await weth.getAddress(),
          1n, 0n, 0n, user.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWithCustomError(adapter, "PoolMissing");
    });

    it("burns BPT, returns token + native, emits LPRemoved", async function () {
      const Pool = await ethers.getContractAt("MockBexPool", pool);
      const bptBalance = await Pool.balanceOf(user.address);

      // Approve adapter to pull BPT
      await Pool.connect(user).approve(await adapter.getAddress(), bptBalance);

      const ethBefore = await ethers.provider.getBalance(user.address);
      const tokenBefore = await token.balanceOf(user.address);

      const tx = await adapter.connect(user).removeLiquidity(
        await token.getAddress(), await weth.getAddress(),
        bptBalance, 0n, 0n, user.address, DEADLINE_FUTURE,
      );
      const receipt = await tx.wait();
      const gasSpent = receipt.gasUsed * receipt.gasPrice;

      await expect(tx).to.emit(adapter, "LPRemoved");

      const ethAfter = await ethers.provider.getBalance(user.address);
      const tokenAfter = await token.balanceOf(user.address);
      const bptAfter = await Pool.balanceOf(user.address);

      expect(bptAfter).to.equal(0n);
      expect(tokenAfter - tokenBefore).to.be.gt(0n);    // received some tokens
      expect(ethAfter - ethBefore + gasSpent).to.be.gt(0n);  // received some native
    });
  });

  // ─── swapExactTokensForTokens ─────────────────────────────────────────

  describe("swapExactTokensForTokens", function () {
    let pool: string;
    const SWAP_AMOUNT = ethers.parseEther("100");

    beforeEach(async function () {
      // Seed pool via addLiquidityETH (only way to register a pair in our mock setup)
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      await adapter.connect(user).addLiquidityETH(
        await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
        { value: ETH_AMOUNT },
      );
      pool = await adapter.getPair(await token.getAddress(), await weth.getAddress());

      // Give the Vault some WETH so it can fulfil swap outputs
      await weth.deposit({ value: ethers.parseEther("200") });
      await weth.transfer(await vault.getAddress(), ethers.parseEther("200"));
    });

    it("reverts on past deadline", async function () {
      await expect(
        adapter.connect(user).swapExactTokensForTokens(
          SWAP_AMOUNT, 0n,
          [await token.getAddress(), await weth.getAddress()],
          user.address, DEADLINE_PAST,
        ),
      ).to.be.revertedWithCustomError(adapter, "DeadlinePassed");
    });

    it("reverts on multi-hop path", async function () {
      await expect(
        adapter.connect(user).swapExactTokensForTokens(
          SWAP_AMOUNT, 0n,
          [await token.getAddress(), await weth.getAddress(), await token.getAddress()],
          user.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWith("BexAdapter: multi-hop out of scope V1");
    });

    it("reverts on zero recipient", async function () {
      await expect(
        adapter.connect(user).swapExactTokensForTokens(
          SWAP_AMOUNT, 0n,
          [await token.getAddress(), await weth.getAddress()],
          ethers.ZeroAddress, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });

    it("reverts on zero amountIn", async function () {
      await expect(
        adapter.connect(user).swapExactTokensForTokens(
          0n, 0n,
          [await token.getAddress(), await weth.getAddress()],
          user.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAmount");
    });

    it("reverts on missing pool", async function () {
      const ghostToken = await (await ethers.getContractFactory("MockERC20")).deploy("Ghost", "GHO", 18, ethers.parseEther("10"));
      await ghostToken.approve(await adapter.getAddress(), 1n);
      await expect(
        adapter.connect(deployer).swapExactTokensForTokens(
          1n, 0n,
          [await ghostToken.getAddress(), await weth.getAddress()],
          deployer.address, DEADLINE_FUTURE,
        ),
      ).to.be.revertedWithCustomError(adapter, "PoolMissing");
    });

    it("swaps token→WETH and routes output to recipient", async function () {
      await token.connect(user).approve(await adapter.getAddress(), SWAP_AMOUNT);
      const wethBefore = await weth.balanceOf(other.address);

      const tx = await adapter.connect(user).swapExactTokensForTokens(
        SWAP_AMOUNT, 0n,
        [await token.getAddress(), await weth.getAddress()],
        other.address, DEADLINE_FUTURE,
      );
      await tx.wait();

      const wethAfter = await weth.balanceOf(other.address);
      expect(wethAfter - wethBefore).to.equal(SWAP_AMOUNT * 997n / 1000n);
    });
  });

  // ─── swapExactETHForTokens ────────────────────────────────────────────

  describe("swapExactETHForTokens", function () {
    let pool: string;

    beforeEach(async function () {
      await token.connect(user).approve(await adapter.getAddress(), TOKEN_AMOUNT);
      await adapter.connect(user).addLiquidityETH(
        await token.getAddress(), TOKEN_AMOUNT, 0, 0, user.address, DEADLINE_FUTURE,
        { value: ETH_AMOUNT },
      );
      pool = await adapter.getPair(await token.getAddress(), await weth.getAddress());

      // Give Vault some token to fulfil swap output
      await token.transfer(await vault.getAddress(), ethers.parseEther("10000"));
    });

    it("reverts on past deadline", async function () {
      await expect(
        adapter.connect(user).swapExactETHForTokens(
          0n,
          [await weth.getAddress(), await token.getAddress()],
          user.address, DEADLINE_PAST,
          { value: ethers.parseEther("1") },
        ),
      ).to.be.revertedWithCustomError(adapter, "DeadlinePassed");
    });

    it("reverts when path[0] != WETH", async function () {
      await expect(
        adapter.connect(user).swapExactETHForTokens(
          0n,
          [await token.getAddress(), await weth.getAddress()],
          user.address, DEADLINE_FUTURE,
          { value: ethers.parseEther("1") },
        ),
      ).to.be.revertedWith("BexAdapter: bad path");
    });

    it("reverts on zero msg.value", async function () {
      await expect(
        adapter.connect(user).swapExactETHForTokens(
          0n,
          [await weth.getAddress(), await token.getAddress()],
          user.address, DEADLINE_FUTURE,
          { value: 0n },
        ),
      ).to.be.revertedWithCustomError(adapter, "ZeroAmount");
    });

    it("wraps msg.value and swaps for tokens to recipient", async function () {
      const tokenBefore = await token.balanceOf(other.address);
      const swapAmount = ethers.parseEther("1");
      await adapter.connect(user).swapExactETHForTokens(
        0n,
        [await weth.getAddress(), await token.getAddress()],
        other.address, DEADLINE_FUTURE,
        { value: swapAmount },
      );
      const tokenAfter = await token.balanceOf(other.address);
      expect(tokenAfter - tokenBefore).to.equal(swapAmount * 997n / 1000n);
    });
  });

  // ─── setPair (owner-only) ─────────────────────────────────────────────

  describe("setPair", function () {
    it("reverts on non-owner call", async function () {
      await expect(
        adapter.connect(user).setPair(await token.getAddress(), await weth.getAddress(), other.address),
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
    it("reverts on zero addresses", async function () {
      await expect(adapter.setPair(ethers.ZeroAddress, await weth.getAddress(), other.address))
        .to.be.revertedWithCustomError(adapter, "ZeroAddress");
      await expect(adapter.setPair(await token.getAddress(), ethers.ZeroAddress, other.address))
        .to.be.revertedWithCustomError(adapter, "ZeroAddress");
      await expect(adapter.setPair(await token.getAddress(), await weth.getAddress(), ethers.ZeroAddress))
        .to.be.revertedWithCustomError(adapter, "ZeroAddress");
    });
    it("sets pair in both orderings", async function () {
      const fakePool = other.address;
      await adapter.setPair(await token.getAddress(), await weth.getAddress(), fakePool);
      expect(await adapter.getPair(await token.getAddress(), await weth.getAddress())).to.equal(fakePool);
      expect(await adapter.getPair(await weth.getAddress(), await token.getAddress())).to.equal(fakePool);
    });
  });

  // ─── receive() guard ──────────────────────────────────────────────────

  describe("receive()", function () {
    it("rejects native from non-WETH sender", async function () {
      await expect(
        user.sendTransaction({ to: await adapter.getAddress(), value: ethers.parseEther("0.1") }),
      ).to.be.revertedWith("BexAdapter: only WBERA refund");
    });
  });
});
