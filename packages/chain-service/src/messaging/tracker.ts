import type { CrossChainMessage, TrackingOptions, MessageStatus } from './types.js';

const DEFAULT_POLL_MS = 5_000;
const DEFAULT_TIMEOUT_MS = 600_000; // 10 min

/**
 * Client-side cross-chain op tracker. Polls the Magneta relayer API until the
 * op reaches a terminal state (delivered | failed) or the timeout expires.
 *
 * Usage:
 *   const msg = await trackOp({ relayerUrl: 'https://relayer.magneta.finance' }, guid);
 *   // msg.status === 'delivered'
 *
 *   // Or with progress callback:
 *   await trackOp(opts, guid, (msg) => updateUI(msg.status));
 */
export async function trackOp(
  opts: TrackingOptions,
  guid: string,
  onProgress?: (msg: CrossChainMessage) => void,
): Promise<CrossChainMessage> {
  const pollMs = opts.pollIntervalMs ?? DEFAULT_POLL_MS;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    const msg = await fetchOpStatus(opts.relayerUrl, guid);
    if (!msg) {
      await sleep(pollMs);
      continue;
    }

    onProgress?.(msg);

    if (msg.status === 'delivered' || msg.status === 'failed') {
      return msg;
    }

    await sleep(pollMs);
  }

  throw new Error(`Tracking timeout for guid ${guid} after ${timeoutMs}ms`);
}

/**
 * One-shot fetch of op status from the relayer.
 */
export async function fetchOpStatus(
  relayerUrl: string,
  guid: string,
): Promise<CrossChainMessage | null> {
  const url = `${relayerUrl}/api/v1/ops/${guid}`;
  const res = await fetch(url, {
    headers: { 'Accept': 'application/json' },
    signal: AbortSignal.timeout(10_000),
  });

  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Relayer returned ${res.status}`);

  return (await res.json()) as CrossChainMessage;
}

/**
 * Fetch all ops for a given caller address.
 */
export async function fetchCallerOps(
  relayerUrl: string,
  caller: string,
  limit = 50,
): Promise<CrossChainMessage[]> {
  const url = `${relayerUrl}/api/v1/ops?caller=${encodeURIComponent(caller)}&limit=${limit}`;
  const res = await fetch(url, {
    headers: { 'Accept': 'application/json' },
    signal: AbortSignal.timeout(10_000),
  });

  if (!res.ok) throw new Error(`Relayer returned ${res.status}`);
  return (await res.json()) as CrossChainMessage[];
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}
