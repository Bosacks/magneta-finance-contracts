import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaPool } from "../typechain-types";
import { MockERC20 } from "../typechain-types";

describe("MagnetaPool", function () {
  let magnetaPool: MagnetaPool;
  let token0: MockERC20;
  let token1: MockERC20;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;

  beforeEach(async function () {
    [owner, user] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    token0 = await MockERC20Factory.deploy("Token0", "TKN0", 18, ethers.parseEther("1000000"));
    token1 = await MockERC20Factory.deploy("Token1", "TKN1", 18, ethers.parseEther("1000000"));

    // Deploy MagnetaPool
    const MagnetaPoolFactory = await ethers.getContractFactory("MagnetaPool");
    magnetaPool = await MagnetaPoolFactory.deploy(owner.address);

    // Transfer tokens to user
    await token0.transfer(user.address, ethers.parseEther("10000"));
    await token1.transfer(user.address, ethers.parseEther("10000"));

    // Enable pool features for testing
    await magnetaPool.setLiquidityAdditionEnabled(true);
    await magnetaPool.setPoolCreationEnabled(true);
  });

  describe("Pool Creation", function () {
    it("Should create a new pool", async function () {
      const token0Addr = await token0.getAddress();
      const token1Addr = await token1.getAddress();

      const tx = await magnetaPool.createPool(
        token0Addr,
        token1Addr,
        30 // 0.3% fee
      );

      // Contract sorts tokens: token0 < token1
      const [sortedToken0, sortedToken1] = token0Addr.toLowerCase() < token1Addr.toLowerCase()
        ? [token0Addr, token1Addr]
        : [token1Addr, token0Addr];

      await expect(tx)
        .to.emit(magnetaPool, "PoolCreated")
        .withArgs(1, sortedToken0, sortedToken1, 30);

      const pool = await magnetaPool.pools(1);
      expect(pool.fee).to.equal(30);
      expect(pool.exists).to.be.true;
    });

    it("Should revert if tokens are identical", async function () {
      await expect(
        magnetaPool.createPool(await token0.getAddress(), await token0.getAddress(), 30)
      ).to.be.revertedWith("MagnetaPool: identical tokens");
    });

    it("Should revert if fee tier is invalid", async function () {
      await expect(
        magnetaPool.createPool(await token0.getAddress(), await token1.getAddress(), 50)
      ).to.be.revertedWith("MagnetaPool: invalid fee tier");
    });

    it("Should revert if pool already exists", async function () {
      await magnetaPool.createPool(await token0.getAddress(), await token1.getAddress(), 30);
      await expect(
        magnetaPool.createPool(await token0.getAddress(), await token1.getAddress(), 30)
      ).to.be.revertedWith("MagnetaPool: pool already exists");
    });
  });

  describe("Adding Liquidity", function () {
    beforeEach(async function () {
      await magnetaPool.createPool(await token0.getAddress(), await token1.getAddress(), 30);
    });

    it("Should add liquidity to a pool", async function () {
      const amount0 = ethers.parseEther("100");
      const amount1 = ethers.parseEther("200");

      await token0.connect(user).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
      await token1.connect(user).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));

      const tx = await magnetaPool
        .connect(user)
        .addLiquidity(1, amount0, amount1, 0, 0, user.address);

      await expect(tx)
        .to.emit(magnetaPool, "LiquidityAdded")
        .withArgs(1, 1, user.address, amount0, amount1, (value: any) => value > 0n);

      const position = await magnetaPool.positions(1);
      expect(position.poolId).to.equal(1);
      expect(position.liquidity).to.be.gt(0);
    });

    it("Should revert if pool does not exist", async function () {
      await expect(
        magnetaPool
          .connect(user)
          .addLiquidity(999, ethers.parseEther("100"), ethers.parseEther("200"), 0, 0, user.address)
      ).to.be.revertedWith("MagnetaPool: pool does not exist");
    });
  });

  describe("Removing Liquidity", function () {
    let tokenId: bigint;

    beforeEach(async function () {
      await magnetaPool.createPool(await token0.getAddress(), await token1.getAddress(), 30);

      const amount0 = ethers.parseEther("100");
      const amount1 = ethers.parseEther("200");

      await token0.connect(user).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
      await token1.connect(user).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));

      const tx = await magnetaPool
        .connect(user)
        .addLiquidity(1, amount0, amount1, 0, 0, user.address);

      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log: any) => log.topics[0] === magnetaPool.interface.getEvent("LiquidityAdded").topicHash
      );
      tokenId = 1n; // First position
    });

    it("Should remove liquidity from a position", async function () {
      const position = await magnetaPool.positions(tokenId);
      const liquidityToRemove = position.liquidity / 2n;

      const tx = await magnetaPool
        .connect(user)
        .removeLiquidity(tokenId, liquidityToRemove, 0, 0, user.address);

      await expect(tx).to.emit(magnetaPool, "LiquidityRemoved");
    });

    it("Should revert if not position owner", async function () {
      const position = await magnetaPool.positions(tokenId);
      const liquidityToRemove = position.liquidity / 2n;

      await expect(
        magnetaPool
          .connect(owner)
          .removeLiquidity(tokenId, liquidityToRemove, 0, 0, owner.address)
      ).to.be.revertedWith("MagnetaPool: not position owner or approved");
    });
  });

  describe("Hardening: MP-1 / MP-2 / MP-4", function () {
    const token0Amt = () => ethers.parseEther("100");
    const token1Amt = () => ethers.parseEther("200");

    async function bootPool() {
      await magnetaPool.createPool(await token0.getAddress(), await token1.getAddress(), 30);
      await token0.connect(user).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
      await token1.connect(user).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
    }

    describe("MP-1: MINIMUM_LIQUIDITY phantom share locks pool from re-init", function () {
      it("exposes MINIMUM_LIQUIDITY = 1000", async function () {
        expect(await magnetaPool.MINIMUM_LIQUIDITY()).to.equal(1000n);
      });

      it("rejects initial deposits whose sqrt(amt0*amt1) <= MINIMUM_LIQUIDITY", async function () {
        await bootPool();
        // sqrt(10 * 10) = 10, less than 1000.
        await expect(
          magnetaPool.connect(user).addLiquidity(1, 10n, 10n, 0, 0, user.address)
        ).to.be.revertedWith("MagnetaPool: insufficient initial liquidity");
      });

      it("first LP receives totalLiquidity - MINIMUM_LIQUIDITY; pool stays > 0 after full withdraw", async function () {
        await bootPool();
        await magnetaPool.connect(user).addLiquidity(1, token0Amt(), token1Amt(), 0, 0, user.address);

        const position = await magnetaPool.positions(1);
        const pool = await magnetaPool.pools(1);

        // pool.liquidity = position.liquidity + MINIMUM_LIQUIDITY
        expect(pool.liquidity).to.equal(position.liquidity + 1000n);

        // Full withdraw of caller's share leaves the phantom 1000 behind.
        await magnetaPool.connect(user).removeLiquidity(1, position.liquidity, 0, 0, user.address);
        const poolAfter = await magnetaPool.pools(1);
        expect(poolAfter.liquidity).to.equal(1000n);
      });

      it("post-drain re-deposit hits the existing-pool branch (cannot re-init at arbitrary ratio)", async function () {
        await bootPool();
        await magnetaPool.connect(user).addLiquidity(1, token0Amt(), token1Amt(), 0, 0, user.address);

        const position = await magnetaPool.positions(1);
        await magnetaPool.connect(user).removeLiquidity(1, position.liquidity, 0, 0, user.address);

        // pool.reserve0 and reserve1 retain a tiny dust amount; pool.liquidity = 1000.
        const poolAfterDrain = await magnetaPool.pools(1);
        expect(poolAfterDrain.liquidity).to.equal(1000n);

        // Attacker tries to deposit (1, 1) wei (would re-init at extreme ratio
        // if first-deposit branch were taken). Should hit the existing-pool
        // branch and revert because reserves are too dust-small to compute
        // a non-zero LP share for such a small deposit.
        await expect(
          magnetaPool.connect(user).addLiquidity(1, 1n, 1n, 0, 0, user.address)
        ).to.be.revertedWith("MagnetaPool: insufficient liquidity");
      });
    });

    describe("MP-2: swap rejects zero recipient", function () {
      it("reverts when to == address(0)", async function () {
        await bootPool();
        await magnetaPool.connect(user).addLiquidity(1, token0Amt(), token1Amt(), 0, 0, user.address);

        // Use block.timestamp + 1h, not wall clock (hardhat advances block time independently)
        const latest = await ethers.provider.getBlock("latest");
        const deadline = latest!.timestamp + 3600;
        await expect(
          magnetaPool.connect(user).swap(
            1,
            await token0.getAddress(),
            ethers.parseEther("1"),
            0,
            ethers.ZeroAddress,
            deadline
          )
        ).to.be.revertedWith("MagnetaPool: invalid recipient");
      });
    });

    describe("MP-4: removeLiquidity / collectFees honor ERC721 approval", function () {
      it("an approved operator can call removeLiquidity without holding the NFT", async function () {
        await bootPool();
        await magnetaPool.connect(user).addLiquidity(1, token0Amt(), token1Amt(), 0, 0, user.address);

        // user approves owner for tokenId 1
        await magnetaPool.connect(user).approve(owner.address, 1);

        const position = await magnetaPool.positions(1);
        const half = position.liquidity / 2n;

        await expect(
          magnetaPool.connect(owner).removeLiquidity(1, half, 0, 0, owner.address)
        ).to.emit(magnetaPool, "LiquidityRemoved");
      });

      it("a setApprovalForAll operator can also call removeLiquidity", async function () {
        await bootPool();
        await magnetaPool.connect(user).addLiquidity(1, token0Amt(), token1Amt(), 0, 0, user.address);

        await magnetaPool.connect(user).setApprovalForAll(owner.address, true);

        const position = await magnetaPool.positions(1);
        await expect(
          magnetaPool.connect(owner).removeLiquidity(1, position.liquidity, 0, 0, owner.address)
        ).to.emit(magnetaPool, "LiquidityRemoved");
      });

      it("collectFees follows the same approval rule", async function () {
        await bootPool();
        await magnetaPool.connect(user).addLiquidity(1, token0Amt(), token1Amt(), 0, 0, user.address);

        // Approved operator can call collectFees (returns zeros since no fees accrue, but doesn't revert)
        await magnetaPool.connect(user).approve(owner.address, 1);
        await expect(
          magnetaPool.connect(owner).collectFees(1, owner.address)
        ).to.not.be.reverted;
      });

      it("unrelated user is still rejected", async function () {
        await bootPool();
        await magnetaPool.connect(user).addLiquidity(1, token0Amt(), token1Amt(), 0, 0, user.address);

        await expect(
          magnetaPool.connect(owner).removeLiquidity(1, 1n, 0, 0, owner.address)
        ).to.be.revertedWith("MagnetaPool: not position owner or approved");
      });
    });
  });
});

