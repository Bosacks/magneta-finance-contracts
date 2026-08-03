/**
 * What each chain still needs before its Gateway wave can run.
 *
 * Written 2026-08-03. Funding was found chain-by-chain during the Base wave,
 * which meant discovering a shortfall with five contracts half-deployed. This
 * prices every remaining wave up front instead.
 *
 * The 12M gas figure is MEASURED, not assumed: the five contracts Base already
 * carries total 50,976 bytes of runtime code, and EVM code deposit alone costs
 * 200 gas per byte — 10.2M before a single constructor runs. An earlier 5.5M
 * estimate was roughly half the truth, which is exactly the kind of error that
 * strands a wave with three of five contracts deployed.
 *
 * On rollups the L1 data fee is charged outside eth_gasPrice, so those chains
 * carry an extra multiplier. Prices come from LI.FI, the aggregator we fund
 * through, so the USD column matches what a top-up will actually cost.
 */
import { createPublicClient, http } from "viem";

const WAVE_GAS = 12_000_000n;
/** Coverage we want in hand before starting a wave. */
const TARGET_MARGIN = 3;
/** Rollups post calldata to L1; eth_gasPrice alone understates a big deploy. */
const ROLLUP_SURCHARGE = 2;

type Chain = { id: number; rpc: string; symbol: string; rollup?: boolean; done?: boolean };

const CHAINS: Record<string, Chain> = {
  base:      { id: 8453,  rpc: "https://base-rpc.publicnode.com",         symbol: "ETH",  rollup: true, done: true },
  arbitrum:  { id: 42161, rpc: "https://arbitrum-one-rpc.publicnode.com", symbol: "ETH",  rollup: true },
  optimism:  { id: 10,    rpc: "https://optimism-rpc.publicnode.com",     symbol: "ETH",  rollup: true },
  linea:     { id: 59144, rpc: "https://linea-rpc.publicnode.com",        symbol: "ETH",  rollup: true },
  unichain:  { id: 130,   rpc: "https://unichain-rpc.publicnode.com",     symbol: "ETH",  rollup: true },
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
  katana:    { id: 747474, rpc: "https://rpc.katana.network",             symbol: "ETH",  rollup: true },
  abstract:  { id: 2741,  rpc: "https://api.mainnet.abs.xyz",             symbol: "ETH",  rollup: true },
  monad:     { id: 143,   rpc: "https://rpc.monad.xyz",                   symbol: "MON"  },
  plasma:    { id: 9745,  rpc: "https://rpc.plasma.to",                   symbol: "XPL"  },
};

const DEPLOYER = "0x620684F822da9adF36F41e3554791D889947e25E" as const;
const NATIVE = "0x0000000000000000000000000000000000000000";

async function priceUSD(chainId: number): Promise<number | null> {
  try {
    const r = await fetch(`https://li.quest/v1/token?chain=${chainId}&token=${NATIVE}`);
    const j = await r.json();
    const p = Number(j?.priceUSD);
    return Number.isFinite(p) && p > 0 ? p : null;
  } catch {
    return null;
  }
}

async function main() {
  const rows: any[] = [];

  await Promise.all(
    Object.entries(CHAINS).map(async ([name, c]) => {
      const client = createPublicClient({ transport: http(c.rpc, { timeout: 20_000 }) });
      try {
        const [bal, gas, px] = await Promise.all([
          client.getBalance({ address: DEPLOYER }),
          client.getGasPrice(),
          priceUSD(c.id),
        ]);
        const cost = WAVE_GAS * gas * BigInt(c.rollup ? ROLLUP_SURCHARGE : 1);
        const need = cost * BigInt(TARGET_MARGIN);
        const short = need > bal ? need - bal : 0n;
        rows.push({ name, ...c, bal, cost, short, px });
      } catch {
        rows.push({ name, ...c, unreadable: true });
      }
    }),
  );

  const f = (v: bigint) => Number(v) / 1e18;
  const order = (r: any) => (r.unreadable ? 2 : r.short > 0n ? 0 : 1);
  const shortNum = (r: any) => (r.unreadable ? 0 : Number(r.short));
  rows.sort((a, b) => order(a) - order(b) || shortNum(b) - shortNum(a));

  console.log(
    `\ncoût d'une vague = ${Number(WAVE_GAS) / 1e6}M gas` +
      ` (×${ROLLUP_SURCHARGE} sur rollup pour les frais L1), objectif ${TARGET_MARGIN}× en caisse\n`,
  );
  console.log("chaîne       solde              vague          manque             ~USD");
  console.log("-".repeat(74));

  let totalUSD = 0;
  let treasuryUSD = 0;
  for (const r of rows) {
    if (r.unreadable) {
      console.log(`${r.name.padEnd(12)} RPC illisible — à vérifier à la main`);
      continue;
    }
    if (r.done) {
      if (r.px) treasuryUSD += f(r.bal) * r.px;
      console.log(`${r.name.padEnd(12)} ${f(r.bal).toFixed(6).padEnd(18)} ${f(r.cost).toFixed(6).padEnd(14)} — (déjà faite)`);
      continue;
    }
    const usd = r.px ? f(r.short) * r.px : null;
    if (usd) totalUSD += usd;
    if (r.px) treasuryUSD += f(r.bal) * r.px;
    const shortTxt = r.short > 0n ? `${f(r.short).toFixed(6)} ${r.symbol}` : "—";
    console.log(
      `${r.name.padEnd(12)} ${f(r.bal).toFixed(6).padEnd(18)} ${f(r.cost).toFixed(6).padEnd(14)} ` +
        `${shortTxt.padEnd(18)} ${usd ? "$" + usd.toFixed(2) : ""}`,
    );
  }
  console.log("-".repeat(74));
  console.log(`manque total sur les chaînes en déficit  : ~$${totalUSD.toFixed(2)}`);
  console.log(`trésorerie du déployeur, toutes chaînes  : ~$${treasuryUSD.toFixed(2)}`);
  // A shortfall covered only by draining a funded chain is not covered: the
  // dollar moved out simply re-opens the same hole one chain over.
  console.log(
    treasuryUSD > totalUSD * 2
      ? "\n=> redistribution interne envisageable.\n"
      : "\n=> apport EXTERNE nécessaire : déplacer les fonds ne ferait que creuser le trou ailleurs.\n",
  );
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
