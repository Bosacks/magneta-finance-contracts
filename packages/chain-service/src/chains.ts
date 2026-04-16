import type { ChainInfo, ChainId } from './types';

/**
 * Registry of every Magneta-supported chain. Every entry is first-class — no
 * chain is marked as a "hub" or "default". The `gatewayLive` flag is the only
 * roll-out signal; the SDK surfaces all chains from day one so wallets on any
 * ecosystem hit the same API.
 *
 * Keep this list alphabetical by `name` to avoid rank perception.
 */
export const CHAINS: Record<string, ChainInfo> = {
  abstract: {
    id: 2741, kind: 'evm', name: 'Abstract', shortName: 'abstract',
    nativeSymbol: 'ETH', gatewayLive: false, explorer: 'https://abscan.org',
  },
  aptos: {
    id: 'aptos:mainnet', kind: 'aptos', name: 'Aptos', shortName: 'apt',
    nativeSymbol: 'APT', gatewayLive: false, explorer: 'https://explorer.aptoslabs.com',
  },
  arbitrum: {
    id: 42161, kind: 'evm', name: 'Arbitrum One', shortName: 'arb',
    nativeSymbol: 'ETH', gatewayLive: false, lzEid: 30110, cctpDomain: 3,
    defaultRouter: '0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506',
    usdc: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
    explorer: 'https://arbiscan.io',
  },
  avalanche: {
    id: 43114, kind: 'evm', name: 'Avalanche C-Chain', shortName: 'avax',
    nativeSymbol: 'AVAX', gatewayLive: false, lzEid: 30106, cctpDomain: 1,
    usdc: '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E',
    explorer: 'https://snowtrace.io',
  },
  base: {
    id: 8453, kind: 'evm', name: 'Base', shortName: 'base',
    nativeSymbol: 'ETH', gatewayLive: false, lzEid: 30184, cctpDomain: 6,
    defaultRouter: '0x29c754668288185794d0D80E5370A9941C47e202',
    usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
    explorer: 'https://basescan.org',
  },
  berachain: {
    id: 80094, kind: 'evm', name: 'Berachain', shortName: 'bera',
    nativeSymbol: 'BERA', gatewayLive: false, explorer: 'https://berascan.com',
  },
  bsc: {
    id: 56, kind: 'evm', name: 'BNB Smart Chain', shortName: 'bsc',
    nativeSymbol: 'BNB', gatewayLive: false, lzEid: 30102,
    usdc: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d',
    explorer: 'https://bscscan.com',
  },
  celo: {
    id: 42220, kind: 'evm', name: 'Celo', shortName: 'celo',
    nativeSymbol: 'CELO', gatewayLive: false, lzEid: 30125,
    explorer: 'https://celoscan.io',
  },
  dexalot: {
    id: 432204, kind: 'evm', name: 'Dexalot', shortName: 'dxlt',
    nativeSymbol: 'ALOT', gatewayLive: false, explorer: 'https://subnets.avax.network/dexalot',
  },
  ethereum: {
    id: 1, kind: 'evm', name: 'Ethereum', shortName: 'eth',
    nativeSymbol: 'ETH', gatewayLive: false, lzEid: 30101, cctpDomain: 0,
    usdc: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
    explorer: 'https://etherscan.io',
  },
  flare: {
    id: 14, kind: 'evm', name: 'Flare', shortName: 'flr',
    nativeSymbol: 'FLR', gatewayLive: false, explorer: 'https://flare-explorer.flare.network',
  },
  gnosis: {
    id: 100, kind: 'evm', name: 'Gnosis', shortName: 'gno',
    nativeSymbol: 'xDAI', gatewayLive: false, lzEid: 30145,
    explorer: 'https://gnosisscan.io',
  },
  katana: {
    id: 747474, kind: 'evm', name: 'Katana', shortName: 'ktn',
    nativeSymbol: 'ETH', gatewayLive: false, explorer: 'https://katanascan.com',
  },
  linea: {
    id: 59144, kind: 'evm', name: 'Linea', shortName: 'linea',
    nativeSymbol: 'ETH', gatewayLive: false, lzEid: 30183,
    explorer: 'https://lineascan.build',
  },
  mantle: {
    id: 5000, kind: 'evm', name: 'Mantle', shortName: 'mnt',
    nativeSymbol: 'MNT', gatewayLive: false, lzEid: 30181,
    explorer: 'https://mantlescan.xyz',
  },
  near: {
    id: 'near:mainnet', kind: 'near', name: 'Near', shortName: 'near',
    nativeSymbol: 'NEAR', gatewayLive: false, explorer: 'https://nearblocks.io',
  },
  optimism: {
    id: 10, kind: 'evm', name: 'Optimism', shortName: 'op',
    nativeSymbol: 'ETH', gatewayLive: false, lzEid: 30111, cctpDomain: 2,
    usdc: '0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85',
    explorer: 'https://optimistic.etherscan.io',
  },
  plasma: {
    id: 'plasma:mainnet', kind: 'evm', name: 'Plasma', shortName: 'plasma',
    nativeSymbol: 'ETH', gatewayLive: false, explorer: 'https://plasmaexplorer.io',
  },
  polygon: {
    id: 137, kind: 'evm', name: 'Polygon', shortName: 'pol',
    nativeSymbol: 'POL', gatewayLive: false, lzEid: 30109, cctpDomain: 7,
    defaultRouter: '0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff',
    usdc: '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359',
    explorer: 'https://polygonscan.com',
  },
  pulsechain: {
    id: 369, kind: 'evm', name: 'PulseChain', shortName: 'pls',
    nativeSymbol: 'PLS', gatewayLive: false, explorer: 'https://scan.pulsechain.com',
  },
  sei: {
    id: 1329, kind: 'evm', name: 'Sei', shortName: 'sei',
    nativeSymbol: 'SEI', gatewayLive: false, lzEid: 30280,
    explorer: 'https://seitrace.com',
  },
  solana: {
    id: 'sol:mainnet', kind: 'solana', name: 'Solana', shortName: 'sol',
    nativeSymbol: 'SOL', gatewayLive: false, cctpDomain: 5,
    usdc: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    explorer: 'https://explorer.solana.com',
  },
  sonic: {
    id: 146, kind: 'evm', name: 'Sonic', shortName: 'sonic',
    nativeSymbol: 'S', gatewayLive: false, explorer: 'https://sonicscan.org',
  },
  starknet: {
    id: 'stark:mainnet', kind: 'starknet', name: 'Starknet', shortName: 'stark',
    nativeSymbol: 'ETH', gatewayLive: false, explorer: 'https://starkscan.co',
  },
  sui: {
    id: 'sui:mainnet', kind: 'sui', name: 'Sui', shortName: 'sui',
    nativeSymbol: 'SUI', gatewayLive: false, explorer: 'https://suiscan.xyz',
  },
  tron: {
    id: 'tron:mainnet', kind: 'tron', name: 'Tron', shortName: 'trx',
    nativeSymbol: 'TRX', gatewayLive: false, explorer: 'https://tronscan.org',
  },
  unichain: {
    id: 130, kind: 'evm', name: 'Unichain', shortName: 'uni',
    nativeSymbol: 'ETH', gatewayLive: false, cctpDomain: 10,
    explorer: 'https://uniscan.xyz',
  },
};

export const ALL_CHAINS: ChainInfo[] = Object.values(CHAINS);

export function getChain(id: ChainId): ChainInfo | undefined {
  return ALL_CHAINS.find((c) => c.id === id);
}

export function requireChain(id: ChainId): ChainInfo {
  const c = getChain(id);
  if (!c) throw new Error(`Unknown chain ${String(id)}`);
  return c;
}

export function chainsByKind(kind: ChainInfo['kind']): ChainInfo[] {
  return ALL_CHAINS.filter((c) => c.kind === kind);
}
