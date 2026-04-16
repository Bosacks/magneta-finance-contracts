import * as React from 'react';
import type { RelayedOp } from '@magneta/chain-service';

export interface CrossChainProgressProps {
  /** List of ops currently in flight (one row per destination chain). */
  ops: RelayedOp[];
  /** Called when user clicks a retry button on a failed op. */
  onRetry?: (op: RelayedOp) => void;
}

const labels: Record<RelayedOp['status'], string> = {
  pending: 'Waiting for signature',
  in_transit: 'Bridging',
  delivered: 'Delivered',
  failed: 'Failed',
};

const colors: Record<RelayedOp['status'], string> = {
  pending: '#6b7280',
  in_transit: '#2563eb',
  delivered: '#16a34a',
  failed: '#dc2626',
};

/**
 * Linear progress list that mirrors each cross-chain dispatch by destination.
 * Treats every destination equally — no "first one is most important" styling.
 */
export function CrossChainProgress({ ops, onRetry }: CrossChainProgressProps) {
  return (
    <ul role="list" style={{ display: 'flex', flexDirection: 'column', gap: 8, padding: 0, margin: 0, listStyle: 'none' }}>
      {ops.map((op) => (
        <li
          key={`${String(op.dstChain)}-${op.srcTxHash}`}
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: 12,
            padding: '10px 12px',
            border: '1px solid #e5e7eb',
            borderRadius: 8,
          }}
        >
          <div
            aria-label={`Status: ${labels[op.status]}`}
            style={{ width: 10, height: 10, borderRadius: 5, background: colors[op.status] }}
          />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2, flex: 1 }}>
            <strong style={{ fontSize: 14 }}>
              {String(op.srcChain)} → {String(op.dstChain)}
            </strong>
            <span style={{ fontSize: 12, color: '#6b7280' }}>{labels[op.status]}</span>
          </div>
          {op.status === 'failed' && onRetry && (
            <button type="button" onClick={() => onRetry(op)} style={{ fontSize: 12 }}>
              Retry
            </button>
          )}
        </li>
      ))}
    </ul>
  );
}
