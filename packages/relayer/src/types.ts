export type OpStatus = 'pending' | 'in_transit' | 'delivered' | 'failed';

export interface TrackedOp {
  guid: string;
  srcChain: string;
  dstChain: string;
  srcEid: number;
  dstEid: number;
  op: number;
  caller: string;
  srcTxHash: string;
  dstTxHash: string | null;
  status: OpStatus;
  createdAt: number;
  updatedAt: number;
  retries: number;
}

export interface ChainRpc {
  chainKey: string;
  chainId: number | string;
  lzEid: number;
  rpcUrl: string;
  gatewayAddress: string;
  blockConfirmations: number;
}

export interface RelayerConfig {
  chains: ChainRpc[];
  pollIntervalMs: number;
  lzScanApiUrl: string;
  port: number;
  dbPath: string;
}
