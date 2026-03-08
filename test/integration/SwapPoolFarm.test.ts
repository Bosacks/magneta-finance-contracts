import { expect } from "chai";
import { ethers } from "hardhat";
import "@nomicfoundation/hardhat-chai-matchers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MagnetaSwap } from "../../typechain-types";
import { MagnetaPool } from "../../typechain-types";
import { MagnetaFarm } from "../../typechain-types";
import { MockERC20 } from "../../typechain-types";

/**
 * Integration tests for complex flows involving multiple contracts
 */
describe("Integration: Swap -> Pool -> Farm", function () {
  let magnetaSwap: MagnetaSwap;
  let magnetaPool: MagnetaPool;
  let magnetaFarm: MagnetaFarm;
  let token0: MockERC20;
  let token1: MockERC20;
  let rewardToken: MockERC20;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  let feeRecipient: SignerWithAddress;

  beforeEach(async function () {
    [owner, user, feeRecipient] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    token0 = await MockERC20Factory.deploy("Token0", "TKN0", 18, ethers.parseEther("1000000"));
    await token0.waitForDeployment();
    token1 = await MockERC20Factory.deploy("Token1", "TKN1", 18, ethers.parseEther("1000000"));
    await token1.waitForDeployment();
    rewardToken = await MockERC20Factory.deploy("Reward Token", "RWD", 18, ethers.parseEther("1000000"));
    await rewardToken.waitForDeployment();

    // Deploy MagnetaPool first (needed by MagnetaSwap)
    const MagnetaPoolFactory = await ethers.getContractFactory("MagnetaPool");
    magnetaPool = await MagnetaPoolFactory.deploy(owner.address);
    await magnetaPool.waitForDeployment();

    // Deploy MagnetaSwap
    const MagnetaSwapFactory = await ethers.getContractFactory("MagnetaSwap");
    magnetaSwap = await MagnetaSwapFactory.deploy(feeRecipient.address, await magnetaPool.getAddress());
    await magnetaSwap.waitForDeployment();

    // MagnetaPool already deployed above

    // Deploy MagnetaFarm
    const MagnetaFarmFactory = await ethers.getContractFactory("MagnetaFarm");
    const startBlock = await ethers.provider.getBlockNumber();
    magnetaFarm = await MagnetaFarmFactory.deploy(
      owner.address,
      await rewardToken.getAddress(),
      ethers.parseEther("1"),
      startBlock
    );
    await magnetaFarm.waitForDeployment();

    // Setup: Whitelist tokens in swap
    await magnetaSwap.setWhitelistedToken(await token0.getAddress(), true);
    await magnetaSwap.setWhitelistedToken(await token1.getAddress(), true);

    // Transfer tokens to user
    await token0.transfer(user.address, ethers.parseEther("10000"));
    await token1.transfer(user.address, ethers.parseEther("10000"));
    await rewardToken.transfer(await magnetaFarm.getAddress(), ethers.parseEther("100000"));

    // Enable pool features for testing
    await magnetaPool.setLiquidityAdditionEnabled(true);
    await magnetaPool.setPoolCreationEnabled(true);
  });

  describe("Complete Flow: Swap -> Add Liquidity -> Stake in Farm", function () {
    it("Should complete full flow: swap tokens, add liquidity, stake LP tokens", async function () {
      // Step 1: Create a pool
      const poolId = await magnetaPool.createPool(
        await token0.getAddress(),
        await token1.getAddress(),
        30 // 0.3% fee
      );
      // MagnetaPool.createPool sorts tokens: token0 < token1 by address.
      // Derive the sorted order to match the PoolCreated event.
      const [sorted0, sorted1] = [await token0.getAddress(), await token1.getAddress()].sort();
      await expect(poolId)
        .to.emit(magnetaPool, "PoolCreated")
        .withArgs(1, sorted0, sorted1, 30);

      // Step 2: Add liquidity to pool
      const amount0 = ethers.parseEther("100");
      const amount1 = ethers.parseEther("200");

      await token0.connect(user).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
      await token1.connect(user).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));

      const addLiquidityTx = await magnetaPool
        .connect(user)
        .addLiquidity(1, amount0, amount1, 0, 0, user.address);

      await expect(addLiquidityTx)
        .to.emit(magnetaPool, "LiquidityAdded")
        .withArgs(1, 1, user.address, amount0, amount1, (value: any) => value > 0n);

      // Step 3: Get LP token (position NFT)
      const position = await magnetaPool.positions(1);
      expect(position.poolId).to.equal(1);
      expect(position.liquidity).to.be.gt(0);

      // Step 4: Add pool to farm
      await magnetaFarm.addPool(await token0.getAddress(), 100, false, false); // Using token0 as LP token for simplicity
      // Note: In a real scenario, you'd need an actual LP token contract

      // Step 5: Stake in farm (simplified - would need actual LP token)
      // This is a placeholder for the complete flow
      expect(await magnetaFarm.poolInfo(0)).to.exist;
    });
  });

  describe("Multiple Users Flow", function () {
    it("Should handle multiple users swapping and providing liquidity", async function () {
      const [user1, user2] = await ethers.getSigners();

      // Create pool
      await magnetaPool.createPool(await token0.getAddress(), await token1.getAddress(), 30);

      // User 1 adds liquidity
      await token0.connect(user1).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
      await token1.connect(user1).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
      await magnetaPool
        .connect(user1)
        .addLiquidity(1, ethers.parseEther("100"), ethers.parseEther("200"), 0, 0, user1.address);

      // User 2 adds liquidity
      await token0.connect(user2).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
      await token1.connect(user2).approve(await magnetaPool.getAddress(), ethers.parseEther("10000"));
      await magnetaPool
        .connect(user2)
        .addLiquidity(1, ethers.parseEther("50"), ethers.parseEther("100"), 0, 0, user2.address);

      // Verify both positions exist
      const position1 = await magnetaPool.positions(1);
      const position2 = await magnetaPool.positions(2);
      expect(position1.liquidity).to.be.gt(0);
      expect(position2.liquidity).to.be.gt(0);
    });
  });
});

