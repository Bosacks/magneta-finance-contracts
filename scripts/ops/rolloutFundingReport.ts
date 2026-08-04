/**
 * What the FULL rollout costs, per chain.
 *
 * Supersedes waveFundingReport.ts, which priced only the Gateway wave. The
 * scope grew as Phase 1 found things:
 *
 *   - the Gateway wave (5 contracts) — the original scope
 *   - MagnetaCurveFactory — carries the report-21 CRITICAL fix AND the creator
 *     fee split; it is NOT part of the wave (redeployGatewayWave.ts lists it as
 *     SEPARATE), which is why Base is finished and still runs a vulnerable one
 *   - the graduation AMM (UniswapV2Factory + MagnetaV2Router02) so graduations
 *     stop handing every post-graduation swap fee to BaseSwap/QuickSwap
 *   - MagnetaStakingFactory — the deployed one credits the requested stake
 *     instead of the received one, and lets a creator promise rewards funded by
 *     a stranger's donation. "Stake to Earn" is live in the DEX today.
 *
 * Sizes are MEASURED, from the deployed bytecode on Base Sepolia and from
 * forge --sizes. Code deposit alone is 200 gas/byte, which is what an earlier
 * 5.5M-per-wave estimate missed by a factor of two.
 */
import { createPublicClient, http } from "viem";

/** Measured runtime sizes, in bytes. */
const SIZES = {
  gatewayWave:        50_976, // Gateway + LP + Swap + TaxClaim + TokenOps
  curveFactory:       21_148, // measured on Base Sepolia 2026-08-03
  v2Factory:          13_859, // embeds the pair creation code
  v2Router:           17_944,
  stakingFactory:      7_615, // measured from the factory deployed on Base
};

/** Deposit + a constructor/init allowance, matching the 12M figure the Gateway
 *  wave actually came in at for 50,976 bytes. */
const gasFor = (bytes: number) => Math.round(bytes * 200 * 1.18);

const COMPONENTS = [
  { key: "gatewayWave",    label: "vague Gateway (5 contrats)" },
  { key: "curveFactory",   label: "CurveFactory (CRITICAL + créateur)" },
  { key: "v2Factory",      label: "AMM de graduation — factory" },
  { key: "v2Router",       label: "AMM de graduation — routeur" },
  { key: "stakingFactory", label: "StakingFactory (2 correctifs)" },
] as const;

const TOTAL_GAS = COMPONENTS.reduce((a, c) => a + gasFor(SIZES[c.key]), 0);
const TARGET_MARGIN = 2;
const ROLLUP_SURCHARGE = 2;

type Chain = { id: number; rpc: string; symbol: string; rollup?: boolean };
const CHAINS: Record<string, Chain> = {
  base:      { id: 8453,  rpc: "https://base-rpc.publicnode.com",         symbol: "ETH",  rollup: true },
  arbitrum:  { id: 42161, rpc: "https://arbitrum-one-rpc.publicnode.com", symbol: "ETH",  rollup: true },
  optimism:  { id: 10,    rpc: "https://optimism-rpc.publicnode.com",     symbol: "ETH",  rollup: true },
  linea:     { id: 59144, rpc: "https://linea-rpc.publicnode.com",        symbol: "ETH",  rollup: true },
  unichain:  { id: 130,   rpc: "https://unichain-rpc.publicnode.com",     symbol: "ETH",  rollup: true },
  katana:    { id: 747474, rpc: "https://rpc.katana.network",             symbol: "ETH",  rollup: true },
  abstract:  { id: 2741,  rpc: "https://api.mainnet.abs.xyz",             symbol: "ETH",  rollup: true },
  mantle:    { id: 5000,  rpc: "https://mantle-rpc.publicnode.com",       symbol: "MNT",  rollup: true },
  polygon:   { id: 137,   rpc: "https://polygon-bor-rpc.publicnode.com",  symbol: "POL"  },
  bsc:       { id: 56,    rpc: "https://bsc-rpc.publicnode.com",          symbol: "BNB"  },
  avalanche: { id: 43114, rpc: "https://avalanche-c-chain-rpc.publicnode.com", symbol: "AVAX" },
  gnosis:    { id: 100,   rpc: "https://gnosis-rpc.publicnode.com",       symbol: "xDAI" },
  celo:      { id: 42220, rpc: "https://celo-rpc.publicnode.com",         symbol: "CELO" },
  cronos:    { id: 25,    rpc: "https://cronos-evm-rpc.publicnode.com",   symbol: "CRO"  },
  sei:       { id: 1329,  rpc: "https://sei-evm-rpc.publicnode.com",      symbol: "SEI"  },
  sonic:     { id: 146,   rpc: "https://sonic-rpc.publicnode.com",        symbol: "S"    },
  berachain: { id: 80094, rpc: "https://rpc.berachain.com",               symbol: "BERA" },
  flare:     { id: 14,    rpc: "https://flare-api.flare.network/ext/C/rpc", symbol: "FLR" },
  monad:     { id: 143,   rpc: "https://rpc.monad.xyz",                   symbol: "MON"  },
  plasma:    { id: 9745,  rpc: "https://rpc.plasma.to",                   symbol: "XPL"  },
};

const DEPLOYER = "0x620684F822da9adF36F41e3554791D889947e25E" as const;

async function priceUSD(chainId: number): Promise<number | null> {
  try {
    const j = await (await fetch(
      `https://li.quest/v1/token?chain=${chainId}&token=0x0000000000000000000000000000000000000000`,
    )).json();
    const p = Number(j?.priceUSD);
    return Number.isFinite(p) && p > 0 ? p : null;
  } catch { return null; }
}

async function main() {
  console.log("\ncoût par composant, sur des tailles MESURÉES :");
  for (const c of COMPONENTS) {
    console.log(`  ${c.label.padEnd(38)} ${(SIZES[c.key] as number).toLocaleString().padStart(7)} o  →  ${(gasFor(SIZES[c.key]) / 1e6).toFixed(2)}M gas`);
  }
  console.log(`  ${"TOTAL par chaîne".padEnd(38)} ${" ".repeat(9)}  →  ${(TOTAL_GAS / 1e6).toFixed(2)}M gas\n`);

  const rows: any[] = [];
  await Promise.all(Object.entries(CHAINS).map(async ([name, c]) => {
    const client = createPublicClient({ transport: http(c.rpc, { timeout: 20_000 }) });
    try {
      const [bal, gas, px] = await Promise.all([
        client.getBalance({ address: DEPLOYER }),
        client.getGasPrice(),
        priceUSD(c.id),
      ]);
      const cost = BigInt(TOTAL_GAS) * gas * BigInt(c.rollup ? ROLLUP_SURCHARGE : 1);
      const need = cost * BigInt(TARGET_MARGIN);
      rows.push({ name, ...c, bal, cost, short: need > bal ? need - bal : 0n, px });
    } catch { rows.push({ name, ...c, unreadable: true }); }
  }));

  const f = (v: bigint) => Number(v) / 1e18;
  rows.sort((a, b) => (a.unreadable ? 1 : 0) - (b.unreadable ? 1 : 0) || Number(b.short ?? 0n) - Number(a.short ?? 0n));

  console.log("chaîne       solde            déploiement      manque            ~USD");
  console.log("-".repeat(72));
  let shortUSD = 0, treasuryUSD = 0, costUSD = 0;
  for (const r of rows) {
    if (r.unreadable) { console.log(`${r.name.padEnd(12)} RPC illisible`); continue; }
    if (r.px) { treasuryUSD += f(r.bal) * r.px; costUSD += f(r.cost) * r.px; }
    const usd = r.px ? f(r.short) * r.px : null;
    if (usd) shortUSD += usd;
    console.log(
      `${r.name.padEnd(12)} ${f(r.bal).toFixed(6).padEnd(16)} ${f(r.cost).toFixed(6).padEnd(16)} ` +
        `${(r.short > 0n ? `${f(r.short).toFixed(6)} ${r.symbol}` : "—").padEnd(17)} ${usd ? "$" + usd.toFixed(2) : ""}`,
    );
  }
  console.log("-".repeat(72));
  console.log(`déploiement complet, toutes chaînes : ~$${costUSD.toFixed(2)}`);
  console.log(`manque au-dessus de l'objectif ${TARGET_MARGIN}× : ~$${shortUSD.toFixed(2)}`);
  console.log(`trésorerie actuelle du déployeur    : ~$${treasuryUSD.toFixed(2)}\n`);
}

main().catch((e) => { console.error(e.message); process.exit(1); });
