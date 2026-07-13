/**
 * Generic recovery for a partial V2 deploy: when deployV2Package.ts deployed
 * the 3 contracts but crashed during transferOwnership (typically a nonce-
 * desync or rate-limit RPC failure).
 *
 * Usage:
 *   PROMO=0x... PROXY=0x... BUNDLER=0x... \
 *     pnpm hardhat run scripts/deploy/recoverV2Partial.ts --network <chain>
 *
 *   (BUNDLER is optional — pass only if the chain has a V2 router.)
 *
 * Does:
 *   1. Reads safe from deployments/<chain>.json
 *   2. transferOwnership(safe) on each contract (skips if already pending/transferred)
 *   3. Writes addresses to deployments/<chain>.json
 *   4. Generates scripts/safe/<chain>-acceptV2Package-batch.json (2 accept + 1 setPricesBatch)
 *
 * The price map is duplicated from deployV2Package.ts to keep this self-contained.
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

const REPO_ROOT  = path.join(__dirname, "..", "..");
const DEPLOY_DIR = path.join(REPO_ROOT, "deployments");
const SAFE_DIR   = path.join(REPO_ROOT, "scripts", "safe");

type PriceTuple = Array<[number, string]>;

const UNIVERSAL_FALLBACK_PRICES: PriceTuple = [
  [1,"0.01"],[2,"0.02"],[3,"0.03"],[4,"0.04"],[5,"0.05"],[6,"0.06"],
];

const PROMOTION_PRICES_BY_CHAIN: Record<number, PriceTuple> = {
  137:    [[1,"200"],[2,"400"],[3,"600"],[4,"800"],[5,"1000"],[6,"1200"]],
  56:     [[1,"0.04"],[2,"0.08"],[3,"0.12"],[4,"0.16"],[5,"0.2"],[6,"0.24"]],
  8453:   UNIVERSAL_FALLBACK_PRICES,
  42161:  UNIVERSAL_FALLBACK_PRICES,
  10:     UNIVERSAL_FALLBACK_PRICES,
  59144:  UNIVERSAL_FALLBACK_PRICES,
  130:    UNIVERSAL_FALLBACK_PRICES,
  747474: UNIVERSAL_FALLBACK_PRICES,
  2741:   UNIVERSAL_FALLBACK_PRICES,
  43114:  [[1,"2"],[2,"4"],[3,"6"],[4,"8"],[5,"10"],[6,"12"]],
  100:    [[1,"40"],[2,"80"],[3,"120"],[4,"160"],[5,"200"],[6,"240"]],
  5000:   [[1,"27"],[2,"54"],[3,"81"],[4,"108"],[5,"135"],[6,"162"]],
  42220:  [[1,"160"],[2,"320"],[3,"480"],[4,"640"],[5,"800"],[6,"960"]],
  1329:   [[1,"200"],[2,"400"],[3,"600"],[4,"800"],[5,"1000"],[6,"1200"]],
  9745:   [[1,"140"],[2,"280"],[3,"420"],[4,"560"],[5,"700"],[6,"840"]],
  80094:  [[1,"22"],[2,"44"],[3,"66"],[4,"88"],[5,"110"],[6,"132"]],
  146:    [[1,"240"],[2,"480"],[3,"720"],[4,"960"],[5,"1200"],[6,"1440"]],
  14:     [[1,"3400"],[2,"6800"],[3,"10200"],[4,"13600"],[5,"17000"],[6,"20400"]],
  143:    [[1,"760"],[2,"1520"],[3,"2280"],[4,"3040"],[5,"3800"],[6,"4550"]],
  25:     [[1,"100"],[2,"200"],[3,"300"],[4,"400"],[5,"500"],[6,"600"]],
};

async function main() {
  const PROMO = process.env.PROMO;
  const PROXY = process.env.PROXY;
  const BUNDLER = process.env.BUNDLER || null;
  if (!PROMO || !PROXY) {
    console.error("Required env: PROMO, PROXY (BUNDLER optional)");
    process.exit(1);
  }

  const net = network.name;
  const depPath = path.join(DEPLOY_DIR, `${net}.json`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  const safe: string = dep.safe ?? dep.gnosisSafe;
  if (!safe || !ethers.isAddress(safe)) throw new Error(`safe missing in ${depPath}`);
  const chainId = String(dep.chainId);
  const chainIdNum = Number(chainId);

  const [deployer] = await ethers.getSigners();
  console.log(`Recovery on ${net} — Deployer ${deployer.address}, Safe ${safe}\n`);

  async function transferIfNeeded(name: string, addr: string, contractName: string, twoStep: boolean): Promise<void> {
    const c = await ethers.getContractAt(contractName, addr);
    const currentOwner: string = await c.owner();
    if (currentOwner.toLowerCase() !== deployer.address.toLowerCase()) {
      console.log(`  ${name}: skip (owner = ${currentOwner})`);
      return;
    }
    if (twoStep) {
      const pending: string = await c.pendingOwner();
      if (pending.toLowerCase() === safe.toLowerCase()) {
        console.log(`  ${name}: skip (pendingOwner already = Safe)`);
        return;
      }
    }
    const tx = await c.transferOwnership(safe);
    await tx.wait();
    console.log(`  ${name}: transferOwnership submitted (tx: ${tx.hash})`);
  }

  console.log("[1] transferOwnership on PromotionPayment…");
  await transferIfNeeded("PromotionPayment", PROMO, "PromotionPayment", true);
  console.log("[2] transferOwnership on MagnetaProxy V2…");
  await transferIfNeeded("MagnetaProxy",    PROXY, "MagnetaProxy",     true);
  if (BUNDLER) {
    console.log("[3] transferOwnership on MagnetaBundler V2…");
    await transferIfNeeded("MagnetaBundler", BUNDLER, "MagnetaBundler", false);
  } else {
    console.log("[3] No BUNDLER provided — skipping.");
  }

  if (!dep.contracts) dep.contracts = {};
  dep.contracts.PromotionPayment  = PROMO;
  dep.contracts.MagnetaProxyV2    = PROXY;
  if (BUNDLER) dep.contracts.MagnetaBundlerV2 = BUNDLER;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`\nWrote V2 addresses to ${depPath}`);

  const prices = PROMOTION_PRICES_BY_CHAIN[chainIdNum] ?? UNIVERSAL_FALLBACK_PRICES;
  const pricesWei = prices.map(([, p]) => ethers.parseEther(p).toString());

  if (!fs.existsSync(SAFE_DIR)) fs.mkdirSync(SAFE_DIR, { recursive: true });
  const batchPath = path.join(SAFE_DIR, `${net}-acceptV2Package-batch.json`);
  const batch = {
    version: "1.0",
    chainId,
    createdAt: Date.now(),
    meta: {
      name: `Magneta — Accept V2 Package ownership (${net})`,
      description: `Finalize the Ownable2Step transfer for PromotionPayment (${PROMO}) and MagnetaProxy V2 (${PROXY})${BUNDLER ? `, plus single-step MagnetaBundler V2 (${BUNDLER})` : " (MagnetaBundler skipped)"}. Recovered after partial deploy.`,
      txBuilderVersion: "1.18.0",
      createdFromSafeAddress: safe,
      createdFromOwnerAddress: "",
      checksum: "0x0000000000000000000000000000000000000000000000000000000000000000",
    },
    transactions: [
      { to: PROMO, value: "0", data: null,
        contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
        contractInputsValues: {} },
      { to: PROXY, value: "0", data: null,
        contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
        contractInputsValues: {} },
      { to: PROMO, value: "0", data: null,
        contractMethod: {
          inputs: [
            { internalType: "uint8[]",   name: "codes",  type: "uint8[]" },
            { internalType: "uint256[]", name: "prices", type: "uint256[]" },
          ],
          name: "setPricesBatch",
          payable: false,
        },
        contractInputsValues: {
          codes:  JSON.stringify(prices.map(([c]) => c)),
          prices: JSON.stringify(pricesWei),
        },
      },
    ],
  };
  fs.writeFileSync(batchPath, JSON.stringify(batch, null, 2) + "\n");
  console.log(`Wrote Safe batch → ${batchPath}`);

  console.log("\n=== Recovery complete ===");
  console.log(`PromotionPayment:  ${PROMO}`);
  console.log(`MagnetaProxy V2:   ${PROXY}`);
  console.log(`MagnetaBundler V2: ${BUNDLER ?? "(none)"}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
