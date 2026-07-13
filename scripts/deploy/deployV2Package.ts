/**
 * Deploy the V2 contract package: PromotionPayment + MagnetaProxy V2 + MagnetaBundler V2.
 *
 * Why a single script:
 *   - All three ship together in the V2 rollout
 *   - One ownership transfer + one Safe batch = fewer manual steps
 *   - Addresses go into deployments/<network>.json under suffixed keys so we
 *     never overwrite V1 addresses (which may still hold residual funds /
 *     allowances that need to be drained or migrated separately)
 *
 * What it does:
 *   1. Reads feeVault, safe, defaultRouter from deployments/<network>.json
 *   2. Deploys PromotionPayment(feeRecipient = feeVault)
 *   3. Deploys MagnetaProxy(feeRecipient = feeVault)         — V2 bytecode (with executeSwapToETH)
 *   4. Deploys MagnetaBundler(router = defaultRouter, feeRecipient = feeVault) — V2 bytecode
 *   5. transferOwnership(safe) on each of the three (Ownable2Step → safe must acceptOwnership)
 *   6. Writes addresses to deployments/<network>.json as:
 *        contracts.PromotionPayment, contracts.MagnetaProxyV2, contracts.MagnetaBundlerV2
 *   7. Emits a Safe batch JSON at scripts/safe/<network>-acceptV2Package-batch.json that the
 *      Safe owner can load in Transaction Builder to acceptOwnership on all three at once,
 *      plus initialize PromotionPayment prices.
 *
 * Required entries in deployments/<network>.json:
 *   - feeVault         (string, EVM address)
 *   - safe             (string, EVM address)
 *   - chainConfig.defaultRouter  (string, V2 router address for the chain)
 *   - chainId          (string or number)
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployV2Package.ts --network polygon
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

const REPO_ROOT  = path.join(__dirname, "..", "..");
const DEPLOY_DIR = path.join(REPO_ROOT, "deployments");
const SAFE_DIR   = path.join(REPO_ROOT, "scripts", "safe");

// Initial promotion prices in wei (native). Owner can adjust via setPrice later.
// Codes 1..6 mirror the frontend's PromoteToken UI (1h..6h). Per-chain values
// from magneta-finance-tokens/lib/constants/promotionFees.ts (PROMOTION_FEES).
// If a chainId is missing here we fall back to UNIVERSAL_FALLBACK_PRICES (cheap
// EVM L2 default; owner can re-tune after deploy via setPricesBatch Safe batch).
type PriceTuple = Array<[number, string]>;  // [durationCode, nativeAmount]

const UNIVERSAL_FALLBACK_PRICES: PriceTuple = [
  [1, "0.01"], [2, "0.02"], [3, "0.03"], [4, "0.04"], [5, "0.05"], [6, "0.06"],
];

const PROMOTION_PRICES_BY_CHAIN: Record<number, PriceTuple> = {
  // Mainnets ─ source: lib/constants/promotionFees.ts in tokens repo
  137:    [[1,"200"],  [2,"400"],  [3,"600"],  [4,"800"],  [5,"1000"], [6,"1200"]],  // Polygon (already set via earlier Safe batch)
  56:     [[1,"0.04"], [2,"0.08"], [3,"0.12"], [4,"0.16"], [5,"0.2"],  [6,"0.24"]],  // BSC
  8453:   UNIVERSAL_FALLBACK_PRICES,                                                  // Base (ETH-class)
  42161:  UNIVERSAL_FALLBACK_PRICES,                                                  // Arbitrum (ETH-class)
  10:     UNIVERSAL_FALLBACK_PRICES,                                                  // Optimism (ETH-class)
  59144:  UNIVERSAL_FALLBACK_PRICES,                                                  // Linea (ETH-class)
  130:    UNIVERSAL_FALLBACK_PRICES,                                                  // Unichain (ETH-class)
  747474: UNIVERSAL_FALLBACK_PRICES,                                                  // Katana (ETH-class)
  2741:   UNIVERSAL_FALLBACK_PRICES,                                                  // Abstract (ETH-class)
  43114:  [[1,"2"],    [2,"4"],    [3,"6"],    [4,"8"],    [5,"10"],   [6,"12"]],    // Avalanche (AVAX)
  100:    [[1,"40"],   [2,"80"],   [3,"120"],  [4,"160"],  [5,"200"],  [6,"240"]],   // Gnosis (xDAI)
  5000:   [[1,"27"],   [2,"54"],   [3,"81"],   [4,"108"],  [5,"135"],  [6,"162"]],   // Mantle (MNT)
  42220:  [[1,"160"],  [2,"320"],  [3,"480"],  [4,"640"],  [5,"800"],  [6,"960"]],   // Celo (CELO)
  1329:   [[1,"200"],  [2,"400"],  [3,"600"],  [4,"800"],  [5,"1000"], [6,"1200"]],  // Sei (SEI)
  9745:   [[1,"140"],  [2,"280"],  [3,"420"],  [4,"560"],  [5,"700"],  [6,"840"]],   // Plasma (XPL)
  80094:  [[1,"22"],   [2,"44"],   [3,"66"],   [4,"88"],   [5,"110"],  [6,"132"]],   // Berachain (BERA)
  146:    [[1,"240"],  [2,"480"],  [3,"720"],  [4,"960"],  [5,"1200"], [6,"1440"]],  // Sonic (S)
  14:     [[1,"3400"], [2,"6800"], [3,"10200"],[4,"13600"],[5,"17000"],[6,"20400"]], // Flare (FLR)
  143:    [[1,"760"],  [2,"1520"], [3,"2280"], [4,"3040"], [5,"3800"], [6,"4550"]],  // Monad (MON)
  25:     [[1,"100"],  [2,"200"],  [3,"300"],  [4,"400"],  [5,"500"],  [6,"600"]],   // Cronos (CRO) — not in PROMOTION_FEES, calibrated to $0.10/CRO * 1000 = $100 for 1h
};

function getPromotionPrices(chainId: number): PriceTuple {
  return PROMOTION_PRICES_BY_CHAIN[chainId] ?? UNIVERSAL_FALLBACK_PRICES;
}

async function main() {
  const net = network.name;
  const depPath = path.join(DEPLOY_DIR, `${net}.json`);
  if (!fs.existsSync(depPath)) {
    throw new Error(`No deployments file at ${depPath}`);
  }
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));

  const feeVault: string = dep.feeVault;
  const safe:     string | undefined = dep.safe ?? dep.gnosisSafe;
  const router:   string | undefined = dep.chainConfig?.defaultRouter;
  const chainId:  string = String(dep.chainId);

  if (!feeVault || !ethers.isAddress(feeVault)) throw new Error(`feeVault missing in ${depPath}`);
  if (!chainId)                                  throw new Error(`chainId missing in ${depPath}`);
  const hasRouter = !!(router && ethers.isAddress(router));
  if (!hasRouter) {
    console.warn(`[${net}] No defaultRouter — MagnetaBundler will be SKIPPED. Promotion + Proxy will still deploy.`);
  }
  if (!safe || !ethers.isAddress(safe)) {
    console.warn(`[${net}] No 'safe' / 'gnosisSafe' in deployment JSON — ownership will remain with deployer`);
  }

  const [deployer] = await ethers.getSigners();
  console.log(`\n=== V2 Package Deploy on ${net} ===`);
  console.log(`Deployer:  ${deployer.address}`);
  console.log(`FeeVault:  ${feeVault}`);
  console.log(`Router:    ${router}`);
  console.log(`Safe:      ${safe ?? "(none)"}`);
  console.log(`ChainId:   ${chainId}`);
  console.log("");

  // ─── 1. PromotionPayment ───────────────────────────────────────────
  console.log("[1/3] Deploying PromotionPayment…");
  const PromoFactory = await ethers.getContractFactory("PromotionPayment");
  const promo = await PromoFactory.deploy(feeVault);
  await promo.waitForDeployment();
  const promoAddr = await promo.getAddress();
  console.log(`      → ${promoAddr}`);

  // Skip on-deploy price-setting — we let the Safe batch handle it together
  // with acceptOwnership in a single multi-tx. This way the prices and the
  // ownership transition land atomically from the Safe's perspective, and
  // re-running the script after a Safe price change won't overwrite the
  // current values with stale defaults.
  const chainIdNum = Number(chainId);
  const pricesForChain = getPromotionPrices(chainIdNum);
  console.log(`      Prices will be set via Safe batch: ${pricesForChain.map(([c,p]) => `${c}h=${p}`).join(", ")}`);

  // ─── 2. MagnetaProxy V2 ────────────────────────────────────────────
  console.log("[2/3] Deploying MagnetaProxy V2 (with executeSwapToETH)…");
  const ProxyFactory = await ethers.getContractFactory("MagnetaProxy");
  const proxy = await ProxyFactory.deploy(feeVault);
  await proxy.waitForDeployment();
  const proxyAddr = await proxy.getAddress();
  console.log(`      → ${proxyAddr}`);

  // ─── 3. MagnetaBundler V2 (skip when no V2 router available) ──────
  let bundler: any = null;
  let bundlerAddr: string | null = null;
  if (hasRouter) {
    console.log("[3/3] Deploying MagnetaBundler V2 (payable bundleSell + sellAndBundleBuy)…");
    const BundlerFactory = await ethers.getContractFactory("MagnetaBundler");
    bundler = await BundlerFactory.deploy(router, feeVault);
    await bundler.waitForDeployment();
    bundlerAddr = await bundler.getAddress();
    console.log(`      → ${bundlerAddr}`);
  } else {
    console.log("[3/3] Skipping MagnetaBundler V2 — no V2 router on this chain.");
  }

  // ─── Transfer ownership ────────────────────────────────────────────
  // PromotionPayment + MagnetaProxy use Ownable2Step → Safe must acceptOwnership.
  // MagnetaBundler uses single-step Ownable → ownership transfers immediately.
  // Wait each tx individually with a fresh nonce to avoid races on flaky RPCs.
  if (safe && ethers.isAddress(safe)) {
    console.log(`\nTransferring ownership to Safe ${safe}…`);
    const targets: Array<[string, any, boolean]> = [
      ["PromotionPayment", promo, true],
      ["MagnetaProxy",     proxy, true],
    ];
    if (bundler) targets.push(["MagnetaBundler", bundler, false]);
    for (const [name, c, twoStep] of targets) {
      const tx = await c.transferOwnership(safe);
      await tx.wait();
      console.log(`      ${name}: ${twoStep ? "pending acceptance" : "ownership transferred"} (tx: ${tx.hash})`);
    }
  }

  // ─── Write to deployments JSON ─────────────────────────────────────
  if (!dep.contracts) dep.contracts = {};
  dep.contracts.PromotionPayment   = promoAddr;
  dep.contracts.MagnetaProxyV2     = proxyAddr;
  if (bundlerAddr) dep.contracts.MagnetaBundlerV2 = bundlerAddr;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`\nWrote V2 addresses to ${depPath}`);

  // ─── Generate Safe batch ───────────────────────────────────────────
  if (safe && ethers.isAddress(safe)) {
    if (!fs.existsSync(SAFE_DIR)) fs.mkdirSync(SAFE_DIR, { recursive: true });
    const batchPath = path.join(SAFE_DIR, `${net}-acceptV2Package-batch.json`);
    const batch = {
      version: "1.0",
      chainId,
      createdAt: Date.now(),
      meta: {
        name: `Magneta — Accept V2 Package ownership (${net})`,
        description: `Finalize the Ownable2Step transfer for PromotionPayment (${promoAddr}) and MagnetaProxy V2 (${proxyAddr})${bundlerAddr ? `, plus single-step MagnetaBundler V2 (${bundlerAddr})` : " (MagnetaBundler skipped — no V2 router on this chain)"}. Deployed by ${deployer.address}.`,
        txBuilderVersion: "1.18.0",
        createdFromSafeAddress: safe,
        createdFromOwnerAddress: "",
        checksum: "0x0000000000000000000000000000000000000000000000000000000000000000",
      },
      // Only Ownable2Step contracts need acceptOwnership.
      // MagnetaBundler uses single-step Ownable and is already owned by Safe.
      // setPricesBatch lands in the same multi-tx so the contract goes from
      // "zero prices, deployer-owned" to "Safe-owned, configured" atomically.
      transactions: [
        {
          to: promoAddr,
          value: "0",
          data: null,
          contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
          contractInputsValues: {},
        },
        {
          to: proxyAddr,
          value: "0",
          data: null,
          contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
          contractInputsValues: {},
        },
        {
          to: promoAddr,
          value: "0",
          data: null,
          contractMethod: {
            inputs: [
              { internalType: "uint8[]",   name: "codes",  type: "uint8[]" },
              { internalType: "uint256[]", name: "prices", type: "uint256[]" },
            ],
            name: "setPricesBatch",
            payable: false,
          },
          contractInputsValues: {
            codes:  JSON.stringify(pricesForChain.map(([c]) => c)),
            prices: JSON.stringify(pricesForChain.map(([, p]) => ethers.parseEther(p).toString())),
          },
        },
      ],
    };
    fs.writeFileSync(batchPath, JSON.stringify(batch, null, 2) + "\n");
    console.log(`Wrote Safe batch → ${batchPath}`);
  }

  // ─── Recap ─────────────────────────────────────────────────────────
  console.log("\n=== Deployment complete ===");
  console.log(`PromotionPayment:  ${promoAddr}`);
  console.log(`MagnetaProxy V2:   ${proxyAddr}`);
  console.log(`MagnetaBundler V2: ${bundlerAddr ?? "(skipped — no V2 router)"}`);
  console.log("");
  console.log("Next steps:");
  console.log(`  1. Safe owner loads scripts/safe/${net}-acceptV2Package-batch.json in Transaction Builder, signs, executes.`);
  console.log(`  2. Update frontend mappings:`);
  console.log(`     - magneta-finance-dex     PROXY_BY_CHAIN_ID[${chainId}] = "${proxyAddr}"`);
  if (bundlerAddr) {
    console.log(`     - magneta-finance-tokens  MAGNETA_BUNDLER_ADDRESS[${chainId}] = "${bundlerAddr}"`);
  } else {
    console.log(`     - magneta-finance-tokens  MAGNETA_BUNDLER_ADDRESS[${chainId}] = (no entry — bundler not deployed)`);
  }
  console.log(`     - magneta-finance-tokens  PROMOTION_PAYMENT_ADDRESS[${chainId}] = "${promoAddr}"`);
  console.log(`  3. Rebuild + push DEX and Tokens; restart services.`);
  console.log(`  4. Validate end-to-end: a USDC→POL swap, a USDC→POL bundle sell, a Promote Token payment.`);
  console.log(`  5. Each tx should add the expected fee to FeeVault ${feeVault}.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
