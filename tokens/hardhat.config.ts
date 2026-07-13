import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
// LayerZero DevTools — adds `lz:oapp:*` Hardhat tasks. The dep conflict
// with hardhat-ethers v2 (ethers v5) means hardhat compile crashes if
// this is enabled. The Sprint B 2-DVN script is standalone (see
// scripts/2dvn/), so the plugin isn't needed for our flows. Keep
// commented until SPRINT_B_2DVN.md option 1 (pnpm overrides) is applied.
// import "@layerzerolabs/toolbox-hardhat";
import * as dotenv from "dotenv";

dotenv.config();

const config: HardhatUserConfig = {
    solidity: {
        compilers: [
            // Default profile (small bytecode for OFT factory, fits 24KB limit)
            {
                version: "0.8.20",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1,
                    },
                    viaIR: true,
                    // Shanghai enables the PUSH0 opcode, saving ~1 byte per
                    // stack push (often hundreds total across a contract).
                    // All 20 Magneta-supported EVMs are post-Shanghai by 2026,
                    // so PUSH0 is safe everywhere. Critical for the OFT
                    // factories which sit at the Spurious Dragon limit.
                    evmVersion: "shanghai",
                },
            },
        ],
        overrides: {
            // Legacy contracts keep runs=200 for cheaper runtime gas — they
            // already fit the 24KB limit and the tradeoff makes sense for
            // hot-path code (transfers, swaps).
            "contracts/ERC20Token.sol":               { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
            "contracts/ERC20TokenAutoLiquidity.sol":  { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
            "contracts/Faucet.sol":                   { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
            "contracts/Multisender.sol":              { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
            "contracts/MagnetaTokenFactory.sol":      { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true } },
        },
    },
    paths: {
        sources: "./contracts",
        tests: "./test",
        cache: "./cache",
        artifacts: "./artifacts",
    },
    networks: (() => {
        const acc = process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [];
        const net = (url: string, chainId: number) => ({ url, accounts: acc, chainId });
        return {
            // FORK_BASE=1 → in-process fork of Base (chainId 8453) for deploy dry-runs.
            hardhat: process.env.FORK_BASE
                ? { chainId: 8453, allowUnlimitedContractSize: true, forking: { url: process.env.BASE_FORK_RPC || "https://mainnet.base.org" } }
                : { chainId: 1337, allowUnlimitedContractSize: true },
            // Testnets
            baseSepolia:     net(process.env.BASE_SEPOLIA_RPC_URL     || "https://sepolia.base.org", 84532),
            optimismSepolia: net(process.env.OPTIMISM_SEPOLIA_RPC_URL || "https://sepolia.optimism.io", 11155420),
            arbitrumSepolia: net(process.env.ARBITRUM_SEPOLIA_RPC_URL || "https://sepolia-rollup.arbitrum.io/rpc", 421614),
            polygonAmoy:     net(process.env.POLYGON_AMOY_RPC_URL     || "https://rpc-amoy.polygon.technology", 80002),
            lineaSepolia:    net(process.env.LINEA_SEPOLIA_RPC_URL    || "https://rpc.sepolia.linea.build", 59141),
            ethereumSepolia: net(process.env.ETHEREUM_SEPOLIA_RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com", 11155111),
            // Mainnets — Cluster A (standard LZ endpoint)
            ethereum:        net(process.env.ETHEREUM_MAINNET_RPC_URL || "https://ethereum-rpc.publicnode.com", 1),
            optimism:        net(process.env.OPTIMISM_MAINNET_RPC_URL || "https://mainnet.optimism.io", 10),
            bsc:             net(process.env.BSC_MAINNET_RPC_URL      || "https://bsc-dataseed.binance.org", 56),
            gnosis:          net(process.env.GNOSIS_MAINNET_RPC_URL   || "https://rpc.gnosischain.com", 100),
            polygon:         net(process.env.POLYGON_MAINNET_RPC_URL  || "https://polygon-rpc.com", 137),
            sei:             net(process.env.SEI_MAINNET_RPC_URL      || "https://sei-evm-rpc.publicnode.com", 1329),
            mantle:          net(process.env.MANTLE_MAINNET_RPC_URL   || "https://rpc.mantle.xyz", 5000),
            base:            net(process.env.BASE_MAINNET_RPC_URL     || "https://mainnet.base.org", 8453),
            celo:            net(process.env.CELO_MAINNET_RPC_URL     || "https://forno.celo.org", 42220),
            arbitrum:        net(process.env.ARBITRUM_MAINNET_RPC_URL || "https://arb1.arbitrum.io/rpc", 42161),
            avalanche:       net(process.env.AVALANCHE_MAINNET_RPC_URL|| "https://api.avax.network/ext/bc/C/rpc", 43114),
            linea:           net(process.env.LINEA_MAINNET_RPC_URL    || "https://rpc.linea.build", 59144),
            flare:           net(process.env.FLARE_MAINNET_RPC_URL    || "https://flare-api.flare.network/ext/C/rpc", 14),
            // Cluster B endpoint
            unichain:        net(process.env.UNICHAIN_MAINNET_RPC_URL || "https://mainnet.unichain.org", 130),
            sonic:           net(process.env.SONIC_MAINNET_RPC_URL    || "https://rpc.soniclabs.com", 146),
            berachain:       net(process.env.BERACHAIN_MAINNET_RPC_URL|| "https://rpc.berachain.com", 80094),
            katana:          net(process.env.KATANA_MAINNET_RPC_URL   || "https://rpc.katana.network", 747474),
            monad:           net(process.env.MONAD_MAINNET_RPC_URL    || "https://rpc.monad.xyz", 143),
            plasma:          net(process.env.PLASMA_MAINNET_RPC_URL   || "https://rpc.plasma.to", 9745),
            // Unique endpoint
            abstract:        net(process.env.ABSTRACT_MAINNET_RPC_URL || "https://api.mainnet.abs.xyz", 2741),
            // No LZ V2 — Sprint 3 SKIPS (Cronos)
            cronos:          net(process.env.CRONOS_MAINNET_RPC_URL   || "https://evm.cronos.org", 25),
        };
    })(),
    etherscan: {
        apiKey: process.env.BASESCAN_API_KEY || "",
        customChains: [
            {
                network: "baseSepolia",
                chainId: 84532,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=84532",
                    browserURL: "https://sepolia.basescan.org",
                },
            },
            {
                network: "optimismSepolia",
                chainId: 11155420,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=11155420",
                    browserURL: "https://sepolia-optimism.etherscan.io",
                },
            },
            {
                network: "arbitrumSepolia",
                chainId: 421614,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=421614",
                    browserURL: "https://sepolia.arbiscan.io",
                },
            },
            {
                network: "base",
                chainId: 8453,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=8453",
                    browserURL: "https://basescan.org",
                },
            },
            {
                network: "arbitrum",
                chainId: 42161,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=42161",
                    browserURL: "https://arbiscan.io",
                },
            },
            {
                network: "polygon",
                chainId: 137,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=137",
                    browserURL: "https://polygonscan.com",
                },
            },
            {
                network: "lineaSepolia",
                chainId: 59141,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=59141",
                    browserURL: "https://sepolia.lineascan.build",
                },
            },
        ],
    },
};

export default config;
