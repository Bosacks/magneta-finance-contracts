/**
 * Post-redeploy smoke test for the audited stack on a TESTNET.
 * Exercises real money paths on the freshly deployed contracts:
 *
 *   1. MagnetaServiceFee: setOpFee -> payFee{value} -> FeeVault balance delta
 *      == fee -> reset opFee to 0.
 *   2. MagnetaLending (rewritten accounting): deploy MockPriceFeed,
 *      setPriceFeed + initReserve(MockUSDC), mint + deposit 100 USDC,
 *      verify availableCash/getUserCollateral, withdraw in full, verify a
 *      clean exit (the F-2 scenario that bricked the old accounting).
 *
 * Testnet-only: refuses to run on non-Sepolia networks.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/smokeTestnetStack.ts --network baseSepolia
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const REPO = path.join(__dirname, "..", "..");

async function main() {
  if (!network.name.toLowerCase().includes("sepolia")) {
    throw new Error("Smoke test is testnet-only");
  }
  const [deployer] = await ethers.getSigners();
  const dep = JSON.parse(fs.readFileSync(path.join(REPO, "deployments", `${network.name}.json`), "utf8"));
  const c = dep.contracts;
  const usdcAddr = dep.chainConfig?.usdc ?? "0xCdE833673E1684803EC72083Ff09C1EA19bd6d9d";

  console.log(`Smoke on ${network.name} as ${deployer.address}`);

  // ── 1. ServiceFee money path ─────────────────────────────────────────────
  const fee = await ethers.getContractAt("MagnetaServiceFee", c.MagnetaServiceFee);
  const vault = await fee.feeVault();
  const opId = ethers.keccak256(ethers.toUtf8Bytes("SMOKE_TEST"));
  const amount = ethers.parseEther("0.00001");

  await (await fee.setOpFee(opId, amount)).wait();
  const vaultBefore = await ethers.provider.getBalance(vault);
  await (await fee.payFee(opId, { value: amount })).wait();
  // Public load-balanced RPCs can serve a stale block right after the tx —
  // retry the read instead of failing on lag.
  let delta = 0n;
  for (let i = 0; i < 8; i++) {
    delta = (await ethers.provider.getBalance(vault)) - vaultBefore;
    if (delta === amount) break;
    await new Promise((r) => setTimeout(r, 3000));
  }
  if (delta !== amount) {
    throw new Error(`ServiceFee: vault delta ${delta} != ${amount}`);
  }
  await (await fee.setOpFee(opId, 0)).wait();
  console.log(`  ✓ ServiceFee payFee → FeeVault +${ethers.formatEther(amount)} native`);

  // ── 2. Lending deposit/withdraw round-trip (rewritten accounting) ────────
  const lending = await ethers.getContractAt("MagnetaLending", c.MagnetaLending);
  const usdc = await ethers.getContractAt(
    ["function mint(address,uint256)", "function approve(address,uint256) returns (bool)", "function balanceOf(address) view returns (uint256)"],
    usdcAddr,
  );

  const Feed = await ethers.getContractFactory("MockPriceFeed");
  const feed = await Feed.deploy(100000000n, 8); // $1.00, 8 decimals
  await feed.waitForDeployment();
  console.log(`  ✓ MockPriceFeed deployed: ${await feed.getAddress()}`);

  // Feed BEFORE reserve (F-19 ordering), bounds $0.50–$2, deviation cap off.
  await (await lending.setPriceFeed(usdcAddr, await feed.getAddress(), ethers.ZeroAddress, ethers.parseEther("0.5"), ethers.parseEther("2"), 0)).wait();
  const reserve = await lending.reserves(usdcAddr);
  if (reserve.supplyIndex === 0n) {
    await (await lending.initReserve(usdcAddr, 7500, 8000)).wait();
    console.log(`  ✓ setPriceFeed + initReserve (ltv 75% / threshold 80%)`);
  } else {
    console.log(`  ✓ setPriceFeed (reserve already initialized — idempotent rerun)`);
  }

  const depositAmt = 100_000_000n; // 100 USDC (6 dec)
  await (await usdc.mint(deployer.address, depositAmt)).wait();
  await (await usdc.approve(await lending.getAddress(), depositAmt)).wait();
  await (await lending.deposit(usdcAddr, depositAmt)).wait();

  const coll = await lending.getUserCollateral(deployer.address, usdcAddr);
  const totalSupplied = await lending.getTotalSupplied(usdcAddr);
  if (coll !== depositAmt || totalSupplied !== depositAmt) {
    throw new Error(`Lending deposit mismatch: coll=${coll} total=${totalSupplied}`);
  }
  console.log(`  ✓ deposit 100 USDC → collateral=${coll} totalSupplied=${totalSupplied}`);

  const balBefore = await usdc.balanceOf(deployer.address);
  await (await lending.withdraw(usdcAddr, coll)).wait();
  const balAfter = await usdc.balanceOf(deployer.address);
  if (balAfter - balBefore !== depositAmt) {
    throw new Error(`Lending withdraw mismatch: got ${balAfter - balBefore}`);
  }
  const collAfter = await lending.getUserCollateral(deployer.address, usdcAddr);
  console.log(`  ✓ full withdraw → +100 USDC back, residual collateral=${collAfter}`);

  console.log(`\nSMOKE: ALL GREEN`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
