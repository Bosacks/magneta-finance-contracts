import type { ChainId, OpResult } from '../types';
import { OpType } from '../types';

/**
 * Uniform wallet abstraction. One implementation per ecosystem (EVM, Solana,
 * Cosmos, Near, Aptos, Sui, Starknet, Tron). The SDK never branches on kind —
 * it looks up the adapter for the connected wallet and calls the same methods.
 *
 * Non-EVM adapters that aren't yet live can throw `NotSupportedYetError` from
 * the methods they don't implement; the surface must still exist from Phase 1.
 */
export interface WalletAdapter {
  /** Identifier of the chain the wallet is currently connected to. */
  readonly chain: ChainId;
  /** Human-readable address as the ecosystem formats it (checksum hex, base58, bech32…). */
  getAddress(): Promise<string>;
  /** Sign + broadcast a raw transaction payload already prepared by the SDK. */
  sendRaw(tx: PreparedTx): Promise<string>;
  /** Sign a typed message for cross-chain intent authorization (EIP-712-equivalent per ecosystem). */
  signIntent(intent: OpIntent): Promise<string>;
}

export interface PreparedTx {
  /** ABI-encoded call data (EVM) or serialized tx (non-EVM). */
  data: string | Uint8Array;
  /** Destination address / program / contract. */
  to: string;
  /** Native value forwarded with the tx. */
  value: bigint;
  /** Gas limit hint. Optional — adapters may override. */
  gasLimit?: bigint;
}

export interface OpIntent {
  op: OpType;
  srcChain: ChainId;
  dstChain: ChainId;
  /** Arbitrary params that the destination gateway will validate. */
  params: Record<string, unknown>;
  /** Unix ts (seconds) after which the intent is void. */
  deadline: number;
  /** Nonce to prevent replay. */
  nonce: bigint;
}

export class NotSupportedYetError extends Error {
  constructor(chain: ChainId, op: OpType) {
    super(`Operation ${OpType[op]} on chain ${String(chain)} is on the roadmap but not yet live.`);
    this.name = 'NotSupportedYetError';
  }
}

/** Minimal representation of a relayed/observed op for progress UIs. */
export interface RelayedOp extends OpResult {
  status: 'pending' | 'in_transit' | 'delivered' | 'failed';
  updatedAt: number;
}
