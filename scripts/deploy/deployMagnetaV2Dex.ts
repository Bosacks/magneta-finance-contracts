/**
 * Generic UniV2-stack deployment for any chain.
 *
 * Why: lets curve token graduations land in Magneta-owned pools (instead of
 * QuickSwap / BaseSwap / etc.). LP fees + the 0.05% protocol fee accrue to
 * the Magneta FeeVault perpetually, rather than leaking to third-party DEXes.
 *
 * On every chain we re-use the chain's canonical wrapped-native (WPOL on
 * Polygon, WETH on Base, WBNB on BSC, etc.) so we don't pollute the user's
 * wallet with a Magneta-only WETH. Plasma is the exception (it has its own
 * deployment script that creates a Magneta WETH9 because the chain had none).
 *
 * After deploy:
 *   1. Safe owner accepts ownership of the factory's feeToSetter (via setFeeToSetter)
 *   2. Safe calls factory.setFeeTo(FeeVault) — enables the 0.05% protocol fee
 *      (UniV2 mechanism: 1/6 of LP growth minted to feeTo, equivalent to 0.05%
 *      of every swap's 0.3% LP fee → 0.25% to LPs, 0.05% to Magneta)
 *   3. Safe calls MagnetaCurveFactory.setRouter(new MagnetaV2Router02 address)
 *      so future curve tokens graduate into Magneta pools
 *
 * Required entries in deployments/<network>.json:
 *   - feeVault             (string, EVM address)
 *   - safe / gnosisSafe    (string, EVM address)
 *   - chainConfig.wnative  (string, the canonical wrapped-native address on this chain)
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployMagnetaV2Dex.ts --network polygon
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

const REPO_ROOT  = path.join(__dirname, "..", "..");
const DEPLOY_DIR = path.join(REPO_ROOT, "deployments");
const SAFE_DIR   = path.join(REPO_ROOT, "scripts", "safe");

// Canonical wrapped-native per chain. Used when chainConfig.wnative is absent
// in the deployment JSON. Source: chain's official docs / etherscan.
const WNATIVE_BY_CHAIN_ID: Record<number, string> = {
  137:    "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270", // WPOL Polygon
  8453:   "0x4200000000000000000000000000000000000006", // WETH Base
  84532:  "0x4200000000000000000000000000000000000006", // WETH Base Sepolia (canonical OP Stack)
  42161:  "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", // WETH Arbitrum
  10:     "0x4200000000000000000000000000000000000006", // WETH Optimism
  56:     "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // WBNB BSC
  43114:  "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", // WAVAX Avalanche
  100:    "0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d", // WXDAI Gnosis
  5000:   "0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8", // WMNT Mantle
  42220:  "0x471EcE3750Da237f93B8E339c536989b8978a438", // CELO (native ERC20 on Celo, used as wnative)
  146:    "0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38", // wS Sonic (S wrapped)
  130:    "0x4200000000000000000000000000000000000006", // WETH Unichain
  747474: "0xEE7D8BCFb72bC1880D0Cf19822eB0A2e6577aB62", // WETH Katana
  59144:  "0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f", // WETH Linea
  14:     "0x1D80c49BbBCd1C0911346656B529DF9E5c2F783d", // WFLR Flare
  1329:   "0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7", // WSEI Sei
  143:    "0x3bd359C1a8b3F4D7D8aD09Bc2A03A0e1310f5433A", // WMON Monad
  9745:   "0xF4A2890fA65Add269829Bd6E4517BC84E473315c", // WXPL Plasma (Magneta-deployed WETH9)
  25:     "0x5C7F8A570d578ED84E63fdFA7b1eE72dEae1AE23", // WCRO Cronos
  2741:   "0x0000000000000000000000000000000000000000", // Abstract — no V2 DEX, skip
  80094:  "0x0000000000000000000000000000000000000000", // Berachain — no V2 DEX, skip
};

async function main() {
  const net = network.name;
  const depPath = path.join(DEPLOY_DIR, `${net}.json`);
  if (!fs.existsSync(depPath)) throw new Error(`No deployments file at ${depPath}`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));

  const feeVault: string = dep.feeVault;
  const safe:     string | undefined = dep.safe ?? dep.gnosisSafe;
  const chainId:  number = Number(dep.chainId);
  const wnative:  string = dep.chainConfig?.wnative ?? WNATIVE_BY_CHAIN_ID[chainId];

  if (!feeVault || !ethers.isAddress(feeVault)) throw new Error(`feeVault missing in ${depPath}`);
  if (!wnative || !ethers.isAddress(wnative) || wnative === ethers.ZeroAddress) {
    throw new Error(`wnative missing or zero for chain ${chainId} — chain not supported by Magneta V2 DEX`);
  }
  if (!safe || !ethers.isAddress(safe)) {
    console.warn(`[${net}] No 'safe' / 'gnosisSafe' in deployment JSON — ownership stays with deployer`);
  }

  const [deployer] = await ethers.getSigners();
  console.log(`\n=== Magneta V2 DEX Deploy on ${net} ===`);
  console.log(`Deployer:  ${deployer.address}`);
  console.log(`FeeVault:  ${feeVault}`);
  console.log(`Safe:      ${safe ?? "(none)"}`);
  console.log(`ChainId:   ${chainId}`);
  console.log(`WNative:   ${wnative}`);
  console.log("");

  // ─── 1. UniswapV2Factory (canonical, feeToSetter = deployer) ──────────
  console.log("[1/2] Deploying UniswapV2Factory…");
  const Factory = await ethers.getContractFactory("UniswapV2Factory");
  const factory = await Factory.deploy(deployer.address);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log(`      → ${factoryAddr}`);

  // ─── 2. MagnetaV2Router02 (UniV2 fork with our patched init code hash) ─
  console.log("[2/2] Deploying MagnetaV2Router02…");
  const Router = await ethers.getContractFactory("MagnetaV2Router02");
  const router = await Router.deploy(factoryAddr, wnative);
  await router.waitForDeployment();
  const routerAddr = await router.getAddress();
  console.log(`      → ${routerAddr}`);

  // ─── 3. Configure factory (deployer is still feeToSetter) ──────────────
  console.log("\nConfiguring factory…");
  // 3a. Set feeTo = FeeVault (enables the 0.05% protocol fee)
  const setFeeToTx = await (factory as any).setFeeTo(feeVault);
  await setFeeToTx.wait();
  console.log(`      setFeeTo(${feeVault}) (tx: ${setFeeToTx.hash})`);
  // 3b. Transfer feeToSetter to Safe so future protocol-fee changes go through quorum
  if (safe && ethers.isAddress(safe)) {
    const setSetterTx = await (factory as any).setFeeToSetter(safe);
    await setSetterTx.wait();
    console.log(`      setFeeToSetter(${safe}) (tx: ${setSetterTx.hash})`);
  }

  // ─── Persist addresses ────────────────────────────────────────────────
  if (!dep.contracts) dep.contracts = {};
  dep.contracts.MagnetaV2Factory  = factoryAddr;
  dep.contracts.MagnetaV2Router02 = routerAddr;
  if (!dep.chainConfig) dep.chainConfig = {};
  if (!dep.chainConfig.wnative) dep.chainConfig.wnative = wnative;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`\nWrote V2 DEX addresses to ${depPath}`);

  // ─── Generate Safe batch (setRouter on CurveFactory) ──────────────────
  const curveFactory = dep.contracts?.MagnetaCurveFactory;
  if (safe && ethers.isAddress(safe) && curveFactory && ethers.isAddress(curveFactory)) {
    if (!fs.existsSync(SAFE_DIR)) fs.mkdirSync(SAFE_DIR, { recursive: true });
    const batchPath = path.join(SAFE_DIR, `${net}-setCurveRouter-batch.json`);
    const batch = {
      version: "1.0",
      chainId: String(chainId),
      createdAt: Date.now(),
      meta: {
        name: `Magneta — Set curve router to Magneta V2 (${net})`,
        description: `Switch MagnetaCurveFactory (${curveFactory}) router to the freshly deployed MagnetaV2Router02 (${routerAddr}). After this, NEW curve tokens created via the launchpad will graduate into Magneta-owned pools (Factory ${factoryAddr}), with 0.05% protocol fee to FeeVault on every swap.`,
        txBuilderVersion: "1.18.0",
        createdFromSafeAddress: safe,
        createdFromOwnerAddress: "",
        checksum: "0x0000000000000000000000000000000000000000000000000000000000000000",
      },
      transactions: [
        {
          to: curveFactory,
          value: "0",
          data: null,
          contractMethod: {
            inputs: [{ internalType: "address", name: "_router", type: "address" }],
            name: "setRouter",
            payable: false,
          },
          contractInputsValues: { _router: routerAddr },
        },
      ],
    };
    fs.writeFileSync(batchPath, JSON.stringify(batch, null, 2) + "\n");
    console.log(`Wrote Safe batch → ${batchPath}`);
  } else {
    console.warn(`[${net}] Skipped Safe batch generation — missing safe or MagnetaCurveFactory in deployment JSON`);
  }

  console.log("\n=== Deployment complete ===");
  console.log(`UniswapV2Factory: ${factoryAddr}`);
  console.log(`MagnetaV2Router02: ${routerAddr}`);
  console.log(`feeTo configured: ${feeVault}`);
  console.log("");
  console.log("Next steps:");
  console.log(`  1. Safe loads scripts/safe/${net}-setCurveRouter-batch.json → executes setRouter on MagnetaCurveFactory`);
  console.log(`  2. From this point: NEW curve tokens created via Free Launchpad graduate into Magneta-owned pools`);
  console.log(`  3. Existing curve tokens (already deployed) keep their old router — unchanged`);
}

main().catch((e) => { console.error(e); process.exit(1); });
