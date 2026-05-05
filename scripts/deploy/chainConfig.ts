/**
 * Shared per-chain deployment config.
 *
 * Consumed by:
 *   - scripts/deploy/deployAll.ts     (runs the deploy)
 *   - scripts/deploy/preflight.ts     (validates before deploy)
 *   - scripts/deploy/configPeers.ts   (wires peers post-deploy)
 *   - scripts/deploy/configCctp.ts    (wires CCTP post-deploy)
 *
 * Fields marked nullable (| null) cause the deploy pipeline to skip
 * dependent contracts with a clear log instead of bombing. Fill them
 * in as you verify real addresses on each chain.
 */

// ─── Magneta wallet addresses ─────────────────────────────────────────
export const FEE_VAULT      = "0x68109132Ecf7540A0A983e1Aaa7DebC469d9d68b";
export const PAUSE_GUARDIAN = "0x479ED5228DCcef6CD05C98A5fe81aCF08F2f5998";

// ─── LayerZero V2 endpoints (clustered by CREATE2 salt) ──────────────
// Source: https://metadata.layerzero-api.com/v1/metadata/deployments
// Most EVMs share one address; Unichain/Sonic/Berachain/Katana/Plasma
// share another; Abstract + Hyperliquid each have their own.
export const LZ_ENDPOINT_STANDARD    = "0x1a44076050125825900e736c501f859c50fE728c";
export const LZ_ENDPOINT_CLUSTER_B   = "0x6F475642a6e85809B1c36Fa62763669b1b48DD5B";
export const LZ_ENDPOINT_ABSTRACT    = "0x5c6cfF4b7C49805F8295Ff73C204ac83f3bC4AE7";
// Hyperliquid + Cronos EVM share this endpoint address (different EIDs).
export const LZ_ENDPOINT_HL_CRONOS   = "0x3A73033C0b1407574C76BdBAc67f126f6b4a9AA9";
/** @deprecated alias kept for older imports — use LZ_ENDPOINT_HL_CRONOS. */
export const LZ_ENDPOINT_HYPERLIQUID = LZ_ENDPOINT_HL_CRONOS;

export interface ChainConfig {
  lzEndpoint: string | null;   // null → skip Gateway + BridgeOApp entirely
  lzEid: number | null;         // must be set if lzEndpoint is set
  cctpDomain: number | null;    // null → CCTP routing not available
  usdc: string | null;          // null → skip TokenOps/TaxClaim/Swap-USDC config
  defaultRouter: string | null; // null → skip LPModule + SwapModule + TaxClaimModule
  router: "uniV2" | "solidly" | "v3" | "orderbook" | null;
}

export const CHAIN_CONFIG: Record<number, ChainConfig> = {
  // Hardhat (local testing only — uses mock addresses)
  31337: {
    lzEndpoint: null, // MockLayerZeroEndpoint deployed at runtime instead
    lzEid: 40245,
    cctpDomain: 0,
    usdc: "0x0000000000000000000000000000000000000001",
    defaultRouter: "0x0000000000000000000000000000000000000002",
    router: "uniV2",
  },
  // ─── Already deployed ─────────────────────────────────────────────
  42161: {
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30110,
    cctpDomain: 3,
    usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    defaultRouter: "0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506", // SushiSwap V2
    router: "uniV2",
  },
  // ─── Standard-endpoint EVMs (Cluster A) ───────────────────────────
  25: { // Cronos EVM
    // Verified live on-chain (same address as Hyperliquid, distinct EID).
    // Source: metadata.layerzero-api.com → cronosevm-mainnet
    lzEndpoint: LZ_ENDPOINT_HL_CRONOS,
    lzEid: 30359,
    cctpDomain: null,
    usdc: "0xc21223249CA28397B4B6541dfFaEcC539BfF0c59",
    defaultRouter: "0x145863Eb42Cf62847A6Ca784e6416C1682b1b2Ae", // VVS Finance V2
    router: "uniV2",
  },
  8453: { // Base
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30184,
    cctpDomain: 6,
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    defaultRouter: "0x327Df1E6de05895d2ab08513aaDD9313Fe505d86", // BaseSwap V2
    router: "uniV2",
  },
  137: { // Polygon
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30109,
    cctpDomain: 7,
    usdc: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
    defaultRouter: "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff", // QuickSwap V2
    router: "uniV2",
  },
  56: { // BSC
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30102,
    cctpDomain: null, // Circle CCTP not deployed on BSC yet
    usdc: "0xB04906e95AB5D797aDA81508115611fee694c2b3", // Wormhole-bridged USDC (6 decimals; Binance-Peg USDC is 18 decimals → incompatible)
    defaultRouter: "0x10ED43C718714eb63d5aA57B78B54704E256024E", // PancakeSwap V2 Router (UniV2-compatible interface, WETH()=WBNB, no adapter needed)
    router: "uniV2",
  },
  42220: { // Celo
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30125,
    cctpDomain: null,
    usdc: "0xcebA9300f2b948710d2653dD7B07f33A8B32118C", // Circle native USDC on Celo
    defaultRouter: "0xF4A2890fA65Add269829Bd6E4517BC84E473315c", // UbeswapCeloAdapter (UniV2 facade over Ubeswap; CELO-as-ERC20, deployed 2026-04-24)
    router: "uniV2",
  },
  14: { // Flare
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30295,
    cctpDomain: null,
    usdc: "0xFbDa5F676cB37624f28265A144A48B0d6e87d3b6", // USDC.e (Stargate bridged) — verified on-chain 2026-04-23
    defaultRouter: "0x0ECAA0096be73528Def68248e53B7C4C0CF923e8", // SparkDEX
    router: "uniV2",
  },
  5000: { // Mantle
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30181,
    cctpDomain: null,
    usdc: "0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9", // USDC.e (verified on-chain 2026-04-23)
    defaultRouter: "0xF4A2890fA65Add269829Bd6E4517BC84E473315c", // MoeRouterAdapter (UniV2 ↔ Merchant Moe V1 wrapper, deployed 2026-04-23)
    router: "uniV2",
  },
  1329: { // Sei
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30280,
    cctpDomain: null, // CCTP V2 live on Sei but domain id TBD; leave null until confirmed
    usdc: "0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392", // Circle native USDC (Mar 2026 migration from USDC.n)
    defaultRouter: "0xb73a41A378Ca508256326B026aC6283a64e177E8", // DragonSwapSeiAdapter (UniV2 facade over DragonSwap; WSEI=0xE30feDd1...e95e8C7, Factory=0x179D9a55...575df4)
    router: "uniV2",
  },
  432204: { // Dexalot
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30118,
    cctpDomain: null,
    usdc: null,
    defaultRouter: null, // orderbook — no AMM router
    router: "orderbook",
  },
  10: { // Optimism
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30111,
    cctpDomain: 2,
    usdc: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", // Circle native USDC
    defaultRouter: "0x2ABf469074dc0b54d793850807E6eb5Faf2625b1", // SushiSwap V2 Router (verified on-chain 2026-04-24, factory=0xFbc1298...303C, WETH=0x4200...0006)
    router: "uniV2",
  },
  100: { // Gnosis
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30145,
    cctpDomain: null,
    usdc: "0xDDAfbb505ad214D7b80b1f830fcCc89B60fb7A83", // USDC from Gnosis bridge — verify
    defaultRouter: "0xE43e60736b1cb4a75ad25240E2f9a62Bff65c0C0", // Swapr (V2-compat)
    router: "uniV2",
  },
  59144: { // Linea
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30183,
    cctpDomain: 11, // CCTP V2
    usdc: "0x176211869cA2b568f2A7D4EE941E073a821EE1ff", // Circle native USDC (6 decimals)
    defaultRouter: "0x8cFe327CEc66d1C090Dd72bd0FF11d690C33a2Eb", // PancakeSwap V2 Router (UniV2-strict, factory=0x02a84c1b...749e, WETH=0xe5d7c2a4...f34f)
    router: "uniV2",
  },
  1: { // Ethereum
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30101,
    cctpDomain: 0,
    usdc: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    defaultRouter: "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", // Uniswap V2 Router
    router: "uniV2",
  },
  43114: { // Avalanche
    lzEndpoint: LZ_ENDPOINT_STANDARD,
    lzEid: 30106,
    cctpDomain: 1,
    usdc: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    defaultRouter: "0xF4A2890fA65Add269829Bd6E4517BC84E473315c", // TraderJoeAvaxAdapter (facade over TraderJoe V1 0x60aE...33d4)
    router: "uniV2",
  },
  // ─── Cluster B endpoint ───────────────────────────────────────────
  130: { // Unichain (OP-Stack L2)
    lzEndpoint: LZ_ENDPOINT_CLUSTER_B,
    lzEid: 30320,
    cctpDomain: 10,
    usdc: "0x078D782b760474a361dDA0AF3839290b0EF57AD6", // Circle native USDC (verified on-chain 2026-04-24)
    defaultRouter: "0x284F11109359a7e1306C3e447ef14D38400063FF", // Uniswap V2 Router02 (verified on-chain 2026-04-24)
    router: "uniV2",
  },
  146: { // Sonic
    lzEndpoint: LZ_ENDPOINT_CLUSTER_B,
    lzEid: 30332,
    cctpDomain: 13, // CCTP V2
    usdc: "0x29219dd400f2Bf60E5a23d13Be72B486D4038894", // USDC.e (verified on-chain 2026-04-23)
    defaultRouter: "0x1D368773735ee1E678950B7A97bcA2CafB330CDc", // Shadow Router V2-compat (verified 2026-04-23, factory=0x2dA2...74c8, WETH=wS)
    router: "uniV2",
  },
  80094: { // Berachain
    lzEndpoint: LZ_ENDPOINT_CLUSTER_B,
    lzEid: 30362,
    cctpDomain: null,
    usdc: "0x549943e04f40284185054145c6E4e9568C1D3241", // Stargate-bridged USDC.e (6 decimals, verified on-chain 2026-04-26)
    defaultRouter: null, // BEX (Balancer V2 fork) and Kodiak V3 are not UniV2-compat. Skip LP/Swap/TaxClaim modules until V2 adapter or a strict V2 fork emerges. Frontend can integrate Ooga Booga aggregator separately.
    router: null,
  },
  747474: { // Katana (OP-Stack + ZK validity proofs, DeFi-focused L2)
    lzEndpoint: LZ_ENDPOINT_CLUSTER_B,
    lzEid: 30375,
    cctpDomain: null,
    usdc: "0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36", // vbUSDC (vault-bridged USDC, 6 decimals — verified on-chain 2026-04-24)
    defaultRouter: "0x69cC349932ae18ED406eeB917d79b9b3033fB68E", // SushiSwap V2 Router (verified on-chain 2026-04-24, factory=0x72D111b4...6Acd9, WETH=0xEE7D8BCF...7aB62)
    router: "uniV2",
  },
  143: { // Monad (parallel execution L1, native MON)
    lzEndpoint: LZ_ENDPOINT_CLUSTER_B,
    lzEid: 30390,
    cctpDomain: null, // CCTP not yet on Monad mainnet
    usdc: "0x754704Bc059F8C67012fEd69BC8A327a5aafb603", // Circle native USDC (verified on-chain 2026-04-25)
    defaultRouter: "0x4b2ab38dbf28d31d467aa8993f6c2585981d6804", // Uniswap V2 Router02 official (Factory=0x182a9271...10f59, WMON=0x3bd359C1...5433A)
    router: "uniV2",
  },
  9745: { // Plasma (stablecoin-focused L1, native XPL)
    lzEndpoint: LZ_ENDPOINT_CLUSTER_B,
    lzEid: 30383,
    cctpDomain: null, // CCTP not supported on Plasma
    // USDT0 (native Plasma stable; no USDC at deploy time 2026-04-24)
    usdc: "0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb",
    // MagnetaV2Router02 (our own UniV2 fork — no third-party V2 DEX on Plasma)
    // WXPL=0xF4A2890fA65Add269829Bd6E4517BC84E473315c Factory=0xDc6BFf741D5a94c26002268b0228212C71F9C726
    defaultRouter: "0xDa43c95Fb2ccf6bDE904Ece558eDeA6B506641B9",
    router: "magnetaV2",
  },
  // ─── Unique endpoints ─────────────────────────────────────────────
  2741: { // Abstract
    lzEndpoint: LZ_ENDPOINT_ABSTRACT,
    lzEid: 30324,
    cctpDomain: null,
    usdc: "0x84A71ccD554Cc1b02749b35d22F684CC8ec987e1", // Stargate-bridged USDC.e (6 decimals, verified on-chain 2026-04-26)
    defaultRouter: null, // No UniV2-strict DEX on Abstract (Reservoir/Moonshot/Kuru = orderbook or specialized). Skip LP/Swap/TaxClaim like Berachain.
    router: null,
  },
  999: { // Hyperliquid EVM
    lzEndpoint: LZ_ENDPOINT_HYPERLIQUID,
    lzEid: 30367,
    cctpDomain: null,
    usdc: null,     // no native USDC on HyperEVM (USDC sits on HyperCore L1)
    defaultRouter: null, // no traditional AMM — perps-focused ecosystem
    router: null,
  },
  // ─── No LZ V2 support ─────────────────────────────────────────────
  369: { // PulseChain
    lzEndpoint: null, // not in LayerZero metadata — no cross-chain deploy
    lzEid: null,
    cctpDomain: null,
    usdc: null, // no canonical USDC
    defaultRouter: "0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02", // PulseX V2
    router: "uniV2",
  },
};
