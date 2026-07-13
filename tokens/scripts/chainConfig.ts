/**
 * Chain configuration mirror for OFT factory deployment (Sprint 3).
 *
 * Mirrors `magneta-finance-contracts/scripts/deploy/chainConfig.ts` for the
 * subset of fields needed to deploy `MagnetaOFTStandardFactory` and
 * `MagnetaOFTAutoLiquidityFactory`:
 *   - `treasury`: receives create fees + 2% AutoLiquidity tax (= FeeVault)
 *   - `lzEndpoint`: LayerZero V2 endpoint (per-chain)
 *
 * Source of truth: contracts repo `chainConfig.ts`. If this drifts, refactor
 * to a shared workspace package — but for now, mirror to avoid the cross-repo
 * import gymnastics during the deploy script.
 */

export const FEE_VAULT = "0x68109132Ecf7540A0A983e1Aaa7DebC469d9d68b";

// On Testsites/testnets we don't have a real FeeVault yet — route create-fees
// to the deployer EOA so withdraw() works end-to-end for validation flows.
// Update if a testnet FeeVault is ever deployed.
export const FEE_VAULT_TESTNET = "0x620684F822da9adF36F41e3554791D889947e25E";

// LayerZero V2 endpoints (clustered by CREATE2 salt — see contracts repo
// chainConfig.ts for the canonical list).
const LZ_ENDPOINT_STANDARD    = "0x1a44076050125825900e736c501f859c50fE728c";
const LZ_ENDPOINT_CLUSTER_B   = "0x6F475642a6e85809B1c36Fa62763669b1b48DD5B";
const LZ_ENDPOINT_ABSTRACT    = "0x5c6cfF4b7C49805F8295Ff73C204ac83f3bC4AE7";
// LZ V2 testnet (Sepolia-side) — single endpoint shared by Base/OP/Arb/Linea/Eth Sepolia.
const LZ_ENDPOINT_TESTNET     = "0x6EDCE65403992e310A62460808c4b910D972f10f";

export interface ChainConfig {
  lzEndpoint: string | null;   // null → skip OFT deploy (e.g. Cronos)
  treasury:   string;
}

/** Chains where OFT factories CAN be deployed (LZ V2 supported). */
export const CHAIN_CONFIG: Record<number, ChainConfig> = {
  // Standard endpoint cluster (Cluster A)
  1:      { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Ethereum
  42161:  { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Arbitrum
  137:    { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Polygon
  8453:   { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Base
  56:     { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // BSC
  10:     { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Optimism
  43114:  { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Avalanche
  59144:  { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Linea
  5000:   { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Mantle
  100:    { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Gnosis
  42220:  { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Celo
  14:     { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Flare
  1329:   { lzEndpoint: LZ_ENDPOINT_STANDARD,    treasury: FEE_VAULT }, // Sei

  // Cluster B endpoint
  130:    { lzEndpoint: LZ_ENDPOINT_CLUSTER_B,   treasury: FEE_VAULT }, // Unichain
  146:    { lzEndpoint: LZ_ENDPOINT_CLUSTER_B,   treasury: FEE_VAULT }, // Sonic
  80094:  { lzEndpoint: LZ_ENDPOINT_CLUSTER_B,   treasury: FEE_VAULT }, // Berachain
  747474: { lzEndpoint: LZ_ENDPOINT_CLUSTER_B,   treasury: FEE_VAULT }, // Katana
  143:    { lzEndpoint: LZ_ENDPOINT_CLUSTER_B,   treasury: FEE_VAULT }, // Monad
  9745:   { lzEndpoint: LZ_ENDPOINT_CLUSTER_B,   treasury: FEE_VAULT }, // Plasma

  // Unique endpoints
  2741:   { lzEndpoint: LZ_ENDPOINT_ABSTRACT,    treasury: FEE_VAULT }, // Abstract

  // No LZ V2 — Sprint 3 SKIPS these chains (Cronos handled via Sprint 5 Relayer)
  25:     { lzEndpoint: null,                    treasury: FEE_VAULT }, // Cronos

  // ─── Testnets (Sepolia-side LZ V2 endpoint) ──────────────────────────────
  // Treasury defaults to the Testsites deployer EOA so withdraw() works
  // end-to-end without needing a separate FeeVault deploy on testnet.
  84532:    { lzEndpoint: LZ_ENDPOINT_TESTNET,   treasury: FEE_VAULT_TESTNET }, // Base Sepolia
  59141:    { lzEndpoint: LZ_ENDPOINT_TESTNET,   treasury: FEE_VAULT_TESTNET }, // Linea Sepolia
  11155111: { lzEndpoint: LZ_ENDPOINT_TESTNET,   treasury: FEE_VAULT_TESTNET }, // Ethereum Sepolia
  11155420: { lzEndpoint: LZ_ENDPOINT_TESTNET,   treasury: FEE_VAULT_TESTNET }, // OP Sepolia
  421614:   { lzEndpoint: LZ_ENDPOINT_TESTNET,   treasury: FEE_VAULT_TESTNET }, // Arbitrum Sepolia
};
