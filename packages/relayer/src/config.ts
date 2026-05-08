import type { RelayerConfig, ChainRpc } from './types.js';

/**
 * Build relayer config from environment variables.
 *
 * Each chain needs: MAGNETA_RPC_<KEY>=https://... and MAGNETA_GATEWAY_<KEY>=0x...
 * where <KEY> is the uppercase chain key (ARBITRUM, BASE, POLYGON, etc.).
 *
 * Only chains with both RPC and gateway configured are watched.
 */
export function loadConfig(): RelayerConfig {
  const allChains = getChainDefs();
  const chains: ChainRpc[] = [];

  for (const def of allChains) {
    const key = def.chainKey.toUpperCase();
    const rpcUrl = process.env[`MAGNETA_RPC_${key}`];
    const gatewayAddress = process.env[`MAGNETA_GATEWAY_${key}`];
    if (!rpcUrl || !gatewayAddress) continue;

    chains.push({
      ...def,
      rpcUrl,
      gatewayAddress,
    });
  }

  return {
    chains,
    pollIntervalMs: Number(process.env.RELAYER_POLL_MS) || 12_000,
    lzScanApiUrl: process.env.LZ_SCAN_API_URL || 'https://scan.layerzero-api.com',
    port: Number(process.env.RELAYER_PORT) || 3010,
    dbPath: process.env.RELAYER_DB_PATH || './data/relayer.db',
  };
}

interface ChainDef {
  chainKey: string;
  chainId: number | string;
  lzEid: number;
  blockConfirmations: number;
}

function getChainDefs(): ChainDef[] {
  return [
    { chainKey: 'ethereum', chainId: 1, lzEid: 30101, blockConfirmations: 12 },
    { chainKey: 'arbitrum', chainId: 42161, lzEid: 30110, blockConfirmations: 1 },
    { chainKey: 'optimism', chainId: 10, lzEid: 30111, blockConfirmations: 1 },
    { chainKey: 'base', chainId: 8453, lzEid: 30184, blockConfirmations: 1 },
    { chainKey: 'polygon', chainId: 137, lzEid: 30109, blockConfirmations: 32 },
    { chainKey: 'avalanche', chainId: 43114, lzEid: 30106, blockConfirmations: 1 },
    { chainKey: 'bsc', chainId: 56, lzEid: 30102, blockConfirmations: 3 },
    { chainKey: 'linea', chainId: 59144, lzEid: 30183, blockConfirmations: 1 },
    { chainKey: 'mantle', chainId: 5000, lzEid: 30181, blockConfirmations: 1 },
    { chainKey: 'sonic', chainId: 146, lzEid: 30332, blockConfirmations: 1 },
    { chainKey: 'sei', chainId: 1329, lzEid: 30280, blockConfirmations: 1 },
    { chainKey: 'gnosis', chainId: 100, lzEid: 30145, blockConfirmations: 5 },
    { chainKey: 'celo', chainId: 42220, lzEid: 30125, blockConfirmations: 1 },
    { chainKey: 'flare', chainId: 14, lzEid: 30295, blockConfirmations: 1 },
    { chainKey: 'berachain', chainId: 80094, lzEid: 30291, blockConfirmations: 1 },
    { chainKey: 'abstract', chainId: 2741, lzEid: 30305, blockConfirmations: 1 },
    { chainKey: 'unichain', chainId: 130, lzEid: 0, blockConfirmations: 1 },
  ];
}
