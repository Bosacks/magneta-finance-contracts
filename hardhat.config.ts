import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";
import * as dotenv from "dotenv";
import path from "path";

dotenv.config({ path: path.resolve(__dirname, ".env") });

const PK = process.env.DEPLOYER_PRIVATE_KEY;
const accounts = PK ? [PK] : [];

// Shorthand: build a chain entry with defaults.
const net = (url: string, chainId: number, extra: object = {}) => ({
  url,
  accounts,
  chainId,
  ...extra,
});

// Etherscan V2 multichain: single API key for every supported chain.
// Routescan: API-key-free (pass any non-empty dummy string below).
const ETHERSCAN_KEY = process.env.BASESCAN_API_KEY || "";
const ROUTESCAN_KEY = "routescan-no-key-required";
// Cronos is NOT on Etherscan V2; its explorer (explorer.cronos.org) exposes an
// Etherscan-compatible API at cronos.org/explorer/api with its own key.
const CRONOSCAN_KEY = process.env.CRONOSCAN_API_KEY || "";

const ETHERSCAN_V2 = (chainId: number, browserURL: string) => ({
  apiURL: `https://api.etherscan.io/v2/api?chainid=${chainId}`,
  browserURL,
});

const ROUTESCAN = (chainId: number, browserURL: string) => ({
  apiURL: `https://api.routescan.io/v2/network/mainnet/evm/${chainId}/etherscan/api`,
  browserURL,
});

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: {
          optimizer: { enabled: true, runs: 200 },
          viaIR: true,
        },
      },
      {
        version: "0.6.6",
        settings: {
          optimizer: { enabled: true, runs: 200 },
        },
      },
      {
        version: "0.5.16",
        settings: {
          optimizer: { enabled: true, runs: 999999 },
        },
      },
    ],
    overrides: {
      "@uniswap/v2-core/contracts/UniswapV2Factory.sol": {
        version: "0.5.16",
        settings: { optimizer: { enabled: true, runs: 999999 } },
      },
      "@uniswap/v2-core/contracts/UniswapV2Pair.sol": {
        version: "0.5.16",
        settings: { optimizer: { enabled: true, runs: 999999 } },
      },
      "@uniswap/v2-core/contracts/UniswapV2ERC20.sol": {
        version: "0.5.16",
        settings: { optimizer: { enabled: true, runs: 999999 } },
      },
      "@uniswap/v2-periphery/contracts/UniswapV2Router02.sol": {
        version: "0.6.6",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      "@uniswap/v2-periphery/contracts/test/WETH9.sol": {
        version: "0.6.6",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
    },
  },
  networks: {
    hardhat: { chainId: 31337 },

    // ─── Testnets ──────────────────────────────────────────────────
    baseSepolia: net(process.env.BASE_TESTNET_RPC_URL || "https://sepolia.base.org", 84532, {
      gasPrice: 10000000,
    }),
    optimismSepolia: net(process.env.OPTIMISM_SEPOLIA_RPC_URL || "https://sepolia.optimism.io", 11155420),
    arbitrumSepolia: net(process.env.ARBITRUM_SEPOLIA_RPC_URL || "https://sepolia-rollup.arbitrum.io/rpc", 421614),
    polygonAmoy: net(process.env.POLYGON_AMOY_RPC_URL || "https://rpc-amoy.polygon.technology", 80002),
    celoSepolia: net(process.env.CELO_SEPOLIA_RPC_URL || "https://forno.celo-sepolia.celo-testnet.org", 11142220),
    lineaSepolia: net(process.env.LINEA_SEPOLIA_RPC_URL || "https://rpc.sepolia.linea.build", 59141),

    // ─── Mainnets: Etherscan V2 verify ─────────────────────────────
    ethereum: net(process.env.ETHEREUM_MAINNET_RPC_URL || "https://ethereum-rpc.publicnode.com", 1),
    optimism: net(process.env.OPTIMISM_MAINNET_RPC_URL || "https://mainnet.optimism.io", 10),
    bsc: net(process.env.BSC_MAINNET_RPC_URL || "https://bsc-dataseed.binance.org", 56),
    gnosis: net(process.env.GNOSIS_MAINNET_RPC_URL || "https://rpc.gnosischain.com", 100),
    unichain: net(process.env.UNICHAIN_MAINNET_RPC_URL || "https://mainnet.unichain.org", 130),
    polygon: net(process.env.POLYGON_MAINNET_RPC_URL || "https://polygon-rpc.com", 137),
    monad: net(process.env.MONAD_MAINNET_RPC_URL || "https://rpc.monad.xyz", 143),
    sonic: net(process.env.SONIC_MAINNET_RPC_URL || "https://rpc.soniclabs.com", 146),
    sei: net(process.env.SEI_MAINNET_RPC_URL || "https://evm-rpc.sei-apis.com", 1329),
    mantle: net(process.env.MANTLE_MAINNET_RPC_URL || "https://rpc.mantle.xyz", 5000),
    base: net(process.env.BASE_MAINNET_RPC_URL || "https://mainnet.base.org", 8453),
    celo: net(process.env.CELO_MAINNET_RPC_URL || "https://forno.celo.org", 42220),
    arbitrum: net(process.env.ARBITRUM_MAINNET_RPC_URL || "https://arb1.arbitrum.io/rpc", 42161),
    avalanche: net(process.env.AVALANCHE_MAINNET_RPC_URL || "https://api.avax.network/ext/bc/C/rpc", 43114),
    linea: net(process.env.LINEA_MAINNET_RPC_URL || "https://rpc.linea.build", 59144),
    berachain: net(process.env.BERACHAIN_MAINNET_RPC_URL || "https://rpc.berachain.com", 80094),
    cronos: net(process.env.CRONOS_MAINNET_RPC_URL || "https://evm.cronos.org", 25),

    // ─── Mainnets: Routescan verify ────────────────────────────────
    flare: net(process.env.FLARE_MAINNET_RPC_URL || "https://flare-api.flare.network/ext/C/rpc", 14),
    pulsechain: net(process.env.PULSECHAIN_MAINNET_RPC_URL || "https://rpc.pulsechain.com", 369),
    dexalot: net(process.env.DEXALOT_MAINNET_RPC_URL || "https://subnets.avax.network/dexalot/mainnet/rpc", 432204),
    katana: net(process.env.KATANA_MAINNET_RPC_URL || "https://rpc.katana.network", 747474),
    plasma: net(process.env.PLASMA_MAINNET_RPC_URL || "https://rpc.plasma.to", 9745),

    // ─── Mainnets: unique verify URLs ──────────────────────────────
    // Abstract: zkSync-stack — uses block-explorer.abs.xyz (custom)
    abstract: net(process.env.ABSTRACT_MAINNET_RPC_URL || "https://api.mainnet.abs.xyz", 2741),
    // Hyperliquid EVM — HyperEVM has its own explorer at hyperevmscan.io
    hyperliquid: net(process.env.HYPERLIQUID_MAINNET_RPC_URL || "https://api.hyperliquid.xyz/evm", 999),
  },

  etherscan: {
    // Per-network API keys. Etherscan V2 chains all use the same key (aliased below);
    // Routescan chains take a dummy string (no auth required); Abstract + Hyperliquid
    // have their own verifiers that need separate keys — override via env if set.
    apiKey: {
      // Etherscan V2 (single key)
      mainnet: ETHERSCAN_KEY,
      optimism: ETHERSCAN_KEY,
      bsc: ETHERSCAN_KEY,
      gnosis: ETHERSCAN_KEY,
      unichain: ETHERSCAN_KEY,
      polygon: ETHERSCAN_KEY,
      monad: ETHERSCAN_KEY,
      sonic: ETHERSCAN_KEY,
      sei: ETHERSCAN_KEY,
      mantle: ETHERSCAN_KEY,
      base: ETHERSCAN_KEY,
      celo: ETHERSCAN_KEY,
      arbitrum: ETHERSCAN_KEY,
      avalanche: ETHERSCAN_KEY,
      linea: ETHERSCAN_KEY,
      berachain: ETHERSCAN_KEY,
      cronos: CRONOSCAN_KEY,
      baseSepolia: ETHERSCAN_KEY,
      optimismSepolia: ETHERSCAN_KEY,
      arbitrumSepolia: ETHERSCAN_KEY,
      polygonAmoy: ETHERSCAN_KEY,
      lineaSepolia: ETHERSCAN_KEY,
      // Routescan (no key required)
      flare: ROUTESCAN_KEY,
      pulsechain: ROUTESCAN_KEY,
      dexalot: ROUTESCAN_KEY,
      katana: ROUTESCAN_KEY,
      plasma: ROUTESCAN_KEY,
      // Unique verifiers
      abstract: process.env.ABSTRACT_VERIFY_KEY || "",
      hyperliquid: process.env.HYPERLIQUID_VERIFY_KEY || "",
    },
    customChains: [
      // Etherscan V2 multichain — all mainnets
      { network: "mainnet",     chainId: 1,      urls: ETHERSCAN_V2(1,      "https://etherscan.io") },
      { network: "optimism",    chainId: 10,     urls: ETHERSCAN_V2(10,     "https://optimistic.etherscan.io") },
      { network: "bsc",         chainId: 56,     urls: ETHERSCAN_V2(56,     "https://bscscan.com") },
      { network: "gnosis",      chainId: 100,    urls: ETHERSCAN_V2(100,    "https://gnosisscan.io") },
      { network: "unichain",    chainId: 130,    urls: ETHERSCAN_V2(130,    "https://uniscan.xyz") },
      { network: "polygon",     chainId: 137,    urls: ETHERSCAN_V2(137,    "https://polygonscan.com") },
      { network: "monad",       chainId: 143,    urls: ETHERSCAN_V2(143,    "https://monadscan.com") },
      { network: "sonic",       chainId: 146,    urls: ETHERSCAN_V2(146,    "https://sonicscan.org") },
      { network: "sei",         chainId: 1329,   urls: ETHERSCAN_V2(1329,   "https://seitrace.com") },
      { network: "mantle",      chainId: 5000,   urls: ETHERSCAN_V2(5000,   "https://mantlescan.xyz") },
      { network: "base",        chainId: 8453,   urls: ETHERSCAN_V2(8453,   "https://basescan.org") },
      { network: "celo",        chainId: 42220,  urls: ETHERSCAN_V2(42220,  "https://celoscan.io") },
      { network: "arbitrum",    chainId: 42161,  urls: ETHERSCAN_V2(42161,  "https://arbiscan.io") },
      { network: "avalanche",   chainId: 43114,  urls: ETHERSCAN_V2(43114,  "https://snowtrace.io") },
      { network: "linea",       chainId: 59144,  urls: ETHERSCAN_V2(59144,  "https://lineascan.build") },
      { network: "berachain",   chainId: 80094,  urls: ETHERSCAN_V2(80094,  "https://berascan.com") },
      { network: "cronos",      chainId: 25,     urls: { apiURL: "https://cronos.org/explorer/api", browserURL: "https://explorer.cronos.org" } },

      // Etherscan V2 — testnets
      { network: "baseSepolia",      chainId: 84532,    urls: ETHERSCAN_V2(84532,    "https://sepolia.basescan.org") },
      { network: "optimismSepolia",  chainId: 11155420, urls: ETHERSCAN_V2(11155420, "https://sepolia-optimism.etherscan.io") },
      { network: "arbitrumSepolia",  chainId: 421614,   urls: ETHERSCAN_V2(421614,   "https://sepolia.arbiscan.io") },
      { network: "polygonAmoy",      chainId: 80002,    urls: ETHERSCAN_V2(80002,    "https://amoy.polygonscan.com") },
      { network: "lineaSepolia",     chainId: 59141,    urls: ETHERSCAN_V2(59141,    "https://sepolia.lineascan.build") },

      // Routescan
      { network: "flare",      chainId: 14,     urls: ROUTESCAN(14,     "https://flarescan.com") },
      { network: "pulsechain", chainId: 369,    urls: ROUTESCAN(369,    "https://scan.pulsechain.com") },
      { network: "dexalot",    chainId: 432204, urls: ROUTESCAN(432204, "https://subnets.avax.network/dexalot") },
      { network: "katana",     chainId: 747474, urls: ROUTESCAN(747474, "https://katanascan.com") },
      { network: "plasma",     chainId: 9745,   urls: ROUTESCAN(9745,   "https://plasmascan.to") },

      // Unique verifiers
      {
        network: "abstract",
        chainId: 2741,
        urls: {
          apiURL: "https://api.abscan.org/api",
          browserURL: "https://abscan.org",
        },
      },
      {
        network: "hyperliquid",
        chainId: 999,
        urls: {
          apiURL: "https://www.hyperevmscan.io/api",
          browserURL: "https://www.hyperevmscan.io",
        },
      },
    ],
  },
  sourcify: { enabled: true },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  typechain: {
    outDir: "./typechain-types",
    target: "ethers-v6",
  },
};

export default config;
