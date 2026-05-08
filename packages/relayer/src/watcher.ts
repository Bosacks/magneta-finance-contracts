import { createPublicClient, http, parseAbiItem, type Log, type PublicClient } from 'viem';
import type { ChainRpc, TrackedOp } from './types.js';
import type { OpStore } from './store.js';

const CROSS_CHAIN_OP_SENT_EVENT = parseAbiItem(
  'event CrossChainOpSent(uint32 indexed dstEid, uint8 indexed op, address indexed caller, bytes32 guid)'
);

const OPERATION_EXECUTED_EVENT = parseAbiItem(
  'event OperationExecuted(uint8 indexed op, address module, address indexed caller, uint256 indexed originChainId, bytes32 resultHash)'
);

interface WatcherClient {
  chain: ChainRpc;
  client: PublicClient;
  lastBlock: bigint;
}

export class ChainWatcher {
  private clients: WatcherClient[] = [];
  private store: OpStore;
  private running = false;
  private pollIntervalMs: number;

  constructor(store: OpStore, chains: ChainRpc[], pollIntervalMs: number) {
    this.store = store;
    this.pollIntervalMs = pollIntervalMs;

    for (const chain of chains) {
      if (!chain.gatewayAddress || !chain.rpcUrl) continue;
      const client = createPublicClient({
        transport: http(chain.rpcUrl, { retryCount: 3, timeout: 15_000 }),
      });
      this.clients.push({ chain, client, lastBlock: 0n });
    }
  }

  async start(): Promise<void> {
    this.running = true;

    for (const wc of this.clients) {
      try {
        wc.lastBlock = await wc.client.getBlockNumber();
      } catch {
        console.warn(`[watcher] Failed to get block for ${wc.chain.chainKey}, will retry`);
      }
    }

    console.log(`[watcher] Watching ${this.clients.length} chains, poll every ${this.pollIntervalMs}ms`);
    this.poll();
  }

  stop(): void {
    this.running = false;
  }

  private async poll(): Promise<void> {
    while (this.running) {
      for (const wc of this.clients) {
        try {
          await this.pollChain(wc);
        } catch (err) {
          console.error("[watcher] Error polling chain:", wc.chain.chainKey, err);
        }
      }
      await sleep(this.pollIntervalMs);
    }
  }

  private async pollChain(wc: WatcherClient): Promise<void> {
    const currentBlock = await wc.client.getBlockNumber();
    if (currentBlock <= wc.lastBlock) return;

    const fromBlock = wc.lastBlock + 1n;
    const toBlock = currentBlock;

    const [sentLogs, execLogs] = await Promise.all([
      wc.client.getLogs({
        address: wc.chain.gatewayAddress as `0x${string}`,
        event: CROSS_CHAIN_OP_SENT_EVENT,
        fromBlock,
        toBlock,
      }),
      wc.client.getLogs({
        address: wc.chain.gatewayAddress as `0x${string}`,
        event: OPERATION_EXECUTED_EVENT,
        fromBlock,
        toBlock,
      }),
    ]);

    for (const log of sentLogs) {
      this.handleCrossChainSent(wc.chain, log);
    }

    for (const log of execLogs) {
      this.handleOperationExecuted(wc.chain, log);
    }

    wc.lastBlock = toBlock;
  }

  private handleCrossChainSent(chain: ChainRpc, log: Log<bigint, number, false, typeof CROSS_CHAIN_OP_SENT_EVENT>): void {
    if (!log.args.guid || !log.args.caller || log.args.dstEid === undefined || log.args.op === undefined) return;

    const now = Math.floor(Date.now() / 1000);
    const op: TrackedOp = {
      guid: log.args.guid,
      srcChain: chain.chainKey,
      dstChain: this.eidToChainKey(log.args.dstEid) ?? String(log.args.dstEid),
      srcEid: chain.lzEid,
      dstEid: log.args.dstEid,
      op: log.args.op,
      caller: log.args.caller.toLowerCase(),
      srcTxHash: log.transactionHash ?? '',
      dstTxHash: null,
      status: 'in_transit',
      createdAt: now,
      updatedAt: now,
      retries: 0,
    };

    this.store.insert(op);
    console.log(`[watcher] CrossChainOpSent guid=${op.guid.slice(0, 10)}… ${chain.chainKey} → ${op.dstChain} op=${op.op}`);
  }

  private handleOperationExecuted(chain: ChainRpc, log: Log<bigint, number, false, typeof OPERATION_EXECUTED_EVENT>): void {
    if (!log.args.caller || log.args.op === undefined || log.args.originChainId === undefined) return;

    if (log.args.originChainId === BigInt(chain.chainId)) return;

    const pending = this.store.getPending();
    for (const tracked of pending) {
      if (
        tracked.dstEid === chain.lzEid &&
        tracked.op === log.args.op &&
        tracked.caller === log.args.caller.toLowerCase()
      ) {
        this.store.updateStatus(tracked.guid, 'delivered', log.transactionHash ?? undefined);
        console.log(`[watcher] Delivered guid=${tracked.guid.slice(0, 10)}… on ${chain.chainKey} tx=${log.transactionHash?.slice(0, 10)}…`);
        break;
      }
    }
  }

  private eidToChainKey(eid: number): string | undefined {
    return this.clients.find(c => c.chain.lzEid === eid)?.chain.chainKey;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}
