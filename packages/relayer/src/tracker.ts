import type { OpStore } from './store.js';

const MAX_RETRIES = 5;
const STALE_THRESHOLD_S = 600; // 10 min without update → check LZ scan

/**
 * Periodic sweep that promotes stale in_transit ops to failed after
 * repeated timeouts. In production, this queries the LayerZero Scan API
 * (`/v1/messages/tx/{hash}`) to get definitive delivery status.
 *
 * The watcher handles the happy path (event-based delivery detection);
 * the tracker handles the sad path (timeouts, retries, finality).
 */
export class StatusTracker {
  private store: OpStore;
  private lzScanApiUrl: string;
  private running = false;

  constructor(store: OpStore, lzScanApiUrl: string) {
    this.store = store;
    this.lzScanApiUrl = lzScanApiUrl;
  }

  async start(intervalMs: number): Promise<void> {
    this.running = true;
    console.log(`[tracker] Sweeping stale ops every ${intervalMs}ms`);

    while (this.running) {
      await this.sweep();
      await sleep(intervalMs);
    }
  }

  stop(): void {
    this.running = false;
  }

  private async sweep(): Promise<void> {
    const pending = this.store.getPending();
    const now = Math.floor(Date.now() / 1000);

    for (const op of pending) {
      const age = now - op.updatedAt;
      if (age < STALE_THRESHOLD_S) continue;

      const delivered = await this.checkLzScan(op.srcTxHash);

      if (delivered === true) {
        this.store.updateStatus(op.guid, 'delivered');
        console.log(`[tracker] LZ Scan confirmed delivery guid=${op.guid.slice(0, 10)}…`);
      } else if (delivered === false && op.retries >= MAX_RETRIES) {
        this.store.updateStatus(op.guid, 'failed');
        console.warn(`[tracker] Marked failed after ${MAX_RETRIES} retries guid=${op.guid.slice(0, 10)}…`);
      } else {
        this.store.incrementRetries(op.guid);
      }
    }
  }

  /**
   * Query LayerZero Scan API for message delivery status.
   * Returns true if delivered, false if not yet / failed, undefined if API unreachable.
   */
  private async checkLzScan(srcTxHash: string): Promise<boolean | undefined> {
    if (!this.lzScanApiUrl || !srcTxHash) return undefined;

    try {
      const url = `${this.lzScanApiUrl}/v1/messages/tx/${srcTxHash}`;
      const res = await fetch(url, {
        headers: { 'Accept': 'application/json' },
        signal: AbortSignal.timeout(10_000),
      });

      if (!res.ok) return undefined;

      const data = await res.json() as { messages?: Array<{ status: string }> };
      const msg = data.messages?.[0];
      if (!msg) return undefined;

      if (msg.status === 'DELIVERED') return true;
      if (msg.status === 'FAILED' || msg.status === 'BLOCKED') return false;
      return undefined;
    } catch {
      return undefined;
    }
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}
