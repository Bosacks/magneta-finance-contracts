import type { OpType, ChainId } from '../types.js';

export type MessageStatus = 'pending' | 'in_transit' | 'delivered' | 'failed';

export interface CrossChainMessage {
  guid: string;
  srcChain: string;
  dstChain: string;
  srcEid: number;
  dstEid: number;
  op: number;
  caller: string;
  srcTxHash: string;
  dstTxHash: string | null;
  status: MessageStatus;
  createdAt: number;
  updatedAt: number;
  retries: number;
}

export interface TrackingOptions {
  relayerUrl: string;
  pollIntervalMs?: number;
  timeoutMs?: number;
}
