/**
 * Full testnet deployment of the Magneta DeFi + Cross-Chain stack.
 *
 * Deploys in order:
 *   1. Core DeFi (Pool, Swap, Lending, Factory, Bundler)
 *   2. Mock tokens (USDC, WETH, test tokens)
 *   3. Cross-chain (Gateway, BridgeOApp)
 *   4. Gateway modules (LP, Swap, TokenOps, TaxClaim)
 *   5. On-chain configuration
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy-testnet.ts --network baseSepolia
 *   pnpm hardhat run scripts/deploy-testnet.ts --network arbitrumSepolia
 *
 * Writes the result to deployments/<network>.json.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

// ─── LayerZero V2 Testnet Endpoint (same on all EVM testnets) ────────
const LZ_ENDPOINT = "0x6EDCE65403992e310A62460808c4b910D972f10f";

// ─── Per-chain testnet config ────────────────────────────────────────
interface ChainConfig {
  lzEid: number;
  weth: string;        // native WETH wrapper
  cctpDomain: number;  // mock — no real CCTP on testnets
}

const CHAIN_CONFIG: Record<number, ChainConfig> = {
  // Base Sepolia
  84532: {
    lzEid: 40245,
    weth: "0x4200000000000000000000000000000000000006",
    cctpDomain: 6,
  },
  // Arbitrum Sepolia
  421614: {
    lzEid: 40231,
    weth: "0x980B62Da83eFf3D4576C647993b0c1D7faf17c73", // Arb Sepolia WETH
    cctpDomain: 3,
  },
  // Hardhat (local)
  31337: {
    lzEid: 40245,
    weth: "0x0000000000000000000000000000000000000000", // will deploy mock
    cctpDomain: 0,
  },
};

interface DeployResult {
  network: string;
  chainId: string;
  deployer: string;
  timestamp: string;
  lzEndpoint: string;
  chainConfig: ChainConfig;
  contracts: Record<string, string>;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n═══════════════════════════════════════════════════`);
  console.log(`  Magneta Finance — Full Testnet Deployment`);
  console.log(`═══════════════════════════════════════════════════`);
  console.log(`Deployer  : ${deployer.address}`);
  console.log(`Network   : ${network.name} (chainId ${chainId})`);
  console.log(`Balance   : ${ethers.formatEther(balance)} ETH\n`);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No config for chainId ${chainId}`);
  if (balance === 0n) throw new Error("Deployer has 0 balance");

  const contracts: Record<string, string> = {};
  let step = 0;
  const total = 17;

  const log = (label: string, addr: string) => {
    step++;
    console.log(`  ${step}/${total}  ${label}: ${addr}`);
  };

  // ═══════════════════════════ MOCK TOKENS ═════════════════════════════
  console.log("\n── Mock Tokens ──");

  const MockERC20 = await ethers.getContractFactory("MockERC20");

  const mockUsdc = await MockERC20.deploy("Mock USDC", "USDC", 6, ethers.parseUnits("1000000", 6));
  await mockUsdc.waitForDeployment();
  contracts.MockUSDC = await mockUsdc.getAddress();
  log("MockUSDC", contracts.MockUSDC);

  const mockTokenX = await MockERC20.deploy("Test Token Alpha", "ALPHA", 18, ethers.parseEther("10000000"));
  await mockTokenX.waitForDeployment();
  contracts.MockTokenX = await mockTokenX.getAddress();
  log("MockTokenX (ALPHA)", contracts.MockTokenX);

  const mockTokenY = await MockERC20.deploy("Test Token Beta", "BETA", 18, ethers.parseEther("10000000"));
  await mockTokenY.waitForDeployment();
  contracts.MockTokenY = await mockTokenY.getAddress();
  log("MockTokenY (BETA)", contracts.MockTokenY);

  // ═══════════════════════════ CORE DEFI ═══════════════════════════════
  console.log("\n── Core DeFi ──");

  const Pool = await ethers.getContractFactory("MagnetaPool");
  const pool = await Pool.deploy(deployer.address);
  await pool.waitForDeployment();
  contracts.MagnetaPool = await pool.getAddress();
  log("MagnetaPool", contracts.MagnetaPool);

  const Swap = await ethers.getContractFactory("MagnetaSwap");
  const swap = await Swap.deploy(deployer.address, contracts.MagnetaPool);
  await swap.waitForDeployment();
  contracts.MagnetaSwap = await swap.getAddress();
  log("MagnetaSwap", contracts.MagnetaSwap);

  const Lending = await ethers.getContractFactory("MagnetaLending");
  const lending = await Lending.deploy();
  await lending.waitForDeployment();
  contracts.MagnetaLending = await lending.getAddress();
  log("MagnetaLending", contracts.MagnetaLending);

  const Factory = await ethers.getContractFactory("MagnetaFactory");
  const factory = await Factory.deploy(contracts.MagnetaPool, deployer.address);
  await factory.waitForDeployment();
  contracts.MagnetaFactory = await factory.getAddress();
  log("MagnetaFactory", contracts.MagnetaFactory);

  const Bundler = await ethers.getContractFactory("MagnetaBundler");
  const bundler = await Bundler.deploy(contracts.MagnetaSwap);
  await bundler.waitForDeployment();
  contracts.MagnetaBundler = await bundler.getAddress();
  log("MagnetaBundler", contracts.MagnetaBundler);

  // ═══════════════════════ CROSS-CHAIN INFRA ══════════════════════════
  console.log("\n── Cross-Chain ──");

  let lzEndpoint: string;
  if (chainId === 31337) {
    const MockEndpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
    const mockEp = await MockEndpoint.deploy(cfg.lzEid);
    await mockEp.waitForDeployment();
    lzEndpoint = await mockEp.getAddress();
    console.log(`  (hardhat) MockLayerZeroEndpoint: ${lzEndpoint}`);
  } else {
    lzEndpoint = ethers.getAddress(LZ_ENDPOINT);
  }

  const Gateway = await ethers.getContractFactory("MagnetaGateway");
  const gateway = await Gateway.deploy(lzEndpoint, deployer.address, deployer.address);
  await gateway.waitForDeployment();
  contracts.MagnetaGateway = await gateway.getAddress();
  log("MagnetaGateway", contracts.MagnetaGateway);

  const BridgeOApp = await ethers.getContractFactory("MagnetaBridgeOApp");
  const bridge = await BridgeOApp.deploy(lzEndpoint, deployer.address, deployer.address, cfg.lzEid);
  await bridge.waitForDeployment();
  contracts.MagnetaBridgeOApp = await bridge.getAddress();
  log("MagnetaBridgeOApp", contracts.MagnetaBridgeOApp);

  // ═══════════════════════ GATEWAY MODULES ════════════════════════════
  console.log("\n── Gateway Modules ──");

  // MockV2Router for LP operations on testnet (no real Uniswap V2 on Sepolia)
  const MockV2 = await ethers.getContractFactory("MockV2Router");
  const mockRouter = await MockV2.deploy(cfg.weth);
  await mockRouter.waitForDeployment();
  contracts.MockV2Router = await mockRouter.getAddress();
  log("MockV2Router", contracts.MockV2Router);

  const LPMod = await ethers.getContractFactory("LPModule");
  const lpModule = await LPMod.deploy(
    contracts.MagnetaGateway, contracts.MockV2Router, contracts.MockUSDC, contracts.MagnetaSwap
  );
  await lpModule.waitForDeployment();
  contracts.LPModule = await lpModule.getAddress();
  log("LPModule", contracts.LPModule);

  const SwapMod = await ethers.getContractFactory("SwapModule");
  const swapModule = await SwapMod.deploy(contracts.MagnetaGateway, contracts.MockV2Router, contracts.MockUSDC);
  await swapModule.waitForDeployment();
  contracts.SwapModule = await swapModule.getAddress();
  log("SwapModule", contracts.SwapModule);

  const TokenOpsMod = await ethers.getContractFactory("TokenOpsModule");
  const tokenOpsModule = await TokenOpsMod.deploy(contracts.MagnetaGateway, contracts.MockUSDC);
  await tokenOpsModule.waitForDeployment();
  contracts.TokenOpsModule = await tokenOpsModule.getAddress();
  log("TokenOpsModule", contracts.TokenOpsModule);

  const TaxClaimMod = await ethers.getContractFactory("TaxClaimModule");
  const taxClaimModule = await TaxClaimMod.deploy(contracts.MagnetaGateway, contracts.MockV2Router, contracts.MockUSDC);
  await taxClaimModule.waitForDeployment();
  contracts.TaxClaimModule = await taxClaimModule.getAddress();
  log("TaxClaimModule", contracts.TaxClaimModule);

  // ═══════════════════════ ON-CHAIN CONFIG ════════════════════════════
  console.log("\n── Configuration ──");

  // Register all 13 OpType → module mappings
  const moduleMap: [number, string][] = [
    [0,  contracts.LPModule],       // CREATE_LP
    [1,  contracts.LPModule],       // REMOVE_LP
    [2,  contracts.LPModule],       // BURN_LP
    [3,  contracts.LPModule],       // CREATE_LP_AND_BUY
    [4,  contracts.TokenOpsModule], // MINT
    [5,  contracts.TokenOpsModule], // UPDATE_METADATA
    [6,  contracts.TokenOpsModule], // FREEZE_ACCOUNT
    [7,  contracts.TokenOpsModule], // UNFREEZE_ACCOUNT
    [8,  contracts.TokenOpsModule], // AUTO_FREEZE
    [9,  contracts.TokenOpsModule], // REVOKE_PERMISSION
    [10, contracts.TaxClaimModule], // CLAIM_TAX_FEES
    [11, contracts.SwapModule],     // SWAP_LOCAL
    [12, contracts.SwapModule],     // SWAP_OUT
  ];

  for (const [op, mod] of moduleMap) {
    const tx = await gateway.setModule(op, mod);
    await tx.wait();
  }
  console.log("  ✓ 13 modules registered on Gateway");

  // Set USDC on gateway
  const setUsdcTx = await gateway.setUsdc(contracts.MockUSDC);
  await setUsdcTx.wait();
  console.log(`  ✓ Gateway USDC set: ${contracts.MockUSDC}`);

  // MagnetaSwap: LPModule fee-exempt
  const setExemptTx = await swap.setFeeExempt(contracts.LPModule, true);
  await setExemptTx.wait();
  console.log(`  ✓ MagnetaSwap: LPModule fee-exempt`);

  // MagnetaSwap: whitelist mock tokens
  const tokensToWhitelist = [
    contracts.MockUSDC,
    contracts.MockTokenX,
    contracts.MockTokenY,
  ];
  const whitelistTx = await swap.whitelistTokenBatch(tokensToWhitelist, true);
  await whitelistTx.wait();
  console.log(`  ✓ MagnetaSwap: ${tokensToWhitelist.length} tokens whitelisted`);

  // ═══════════════════════ SEED LIQUIDITY ═════════════════════════════
  console.log("\n── Seed Liquidity ──");

  const alpha = await ethers.getContractAt("MockERC20", contracts.MockTokenX);
  const usdc = await ethers.getContractAt("MockERC20", contracts.MockUSDC);

  // Approve pool with max allowance
  const MAX = ethers.MaxUint256;
  await (await alpha.approve(contracts.MagnetaPool, MAX)).wait();
  await (await usdc.approve(contracts.MagnetaPool, MAX)).wait();

  // Create pool with 0.3% fee tier
  const createPoolTx = await pool.createPool(contracts.MockTokenX, contracts.MockUSDC, 30);
  await createPoolTx.wait();
  const poolId = await pool.getPool(contracts.MockTokenX, contracts.MockUSDC, 30);
  console.log(`  ✓ Pool ALPHA/USDC created (poolId: ${poolId})`);

  // Determine token ordering in pool (token0 < token1 by address)
  const alphaAddr = contracts.MockTokenX.toLowerCase();
  const usdcAddr = contracts.MockUSDC.toLowerCase();
  const alphaIsToken0 = alphaAddr < usdcAddr;

  const amount0 = alphaIsToken0 ? ethers.parseEther("1000") : ethers.parseUnits("1000", 6);
  const amount1 = alphaIsToken0 ? ethers.parseUnits("1000", 6) : ethers.parseEther("1000");
  const min0 = alphaIsToken0 ? ethers.parseEther("900") : ethers.parseUnits("900", 6);
  const min1 = alphaIsToken0 ? ethers.parseUnits("900", 6) : ethers.parseEther("900");

  const addLiqTx = await pool.addLiquidity(poolId, amount0, amount1, min0, min1, deployer.address);
  await addLiqTx.wait();
  console.log(`  ✓ Liquidity added: 1000 ALPHA + 1000 USDC (token0=${alphaIsToken0 ? "ALPHA" : "USDC"})`);

  // ═══════════════════════ WRITE DEPLOYMENT ═══════════════════════════

  const result: DeployResult = {
    network: network.name,
    chainId: chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    lzEndpoint,
    chainConfig: cfg,
    contracts,
  };

  const outPath = path.join(__dirname, "..", "deployments", `${network.name}.json`);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n");

  console.log(`\n═══════════════════════════════════════════════════`);
  console.log(`  Deployment complete — ${network.name}`);
  console.log(`═══════════════════════════════════════════════════`);
  for (const [name, addr] of Object.entries(contracts)) {
    console.log(`  ${name}: ${addr}`);
  }

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`\nGas spent: ${ethers.formatEther(spent)} ETH`);
  console.log(`Remaining: ${ethers.formatEther(balance - spent)} ETH`);

  console.log("\n── Next Steps ──");
  console.log("1. Run on the other testnet, then configPeers.ts for cross-chain");
  console.log("2. Test token creation via the tokens frontend");
  console.log("3. Test swap: MagnetaSwap.swap(ALPHA → USDC)");
  console.log("4. Test pool operations: addLiquidity / removeLiquidity");
  console.log(`═══════════════════════════════════════════════════\n`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
