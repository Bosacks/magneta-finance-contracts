import * as React from 'react';
import type { FeeQuote } from '@magneta/chain-service';

export interface FeeBreakdownProps {
  quote: FeeQuote;
  /** Native symbol of the destination chain (ETH, SOL, BNB…) — shown next to gas. */
  nativeSymbol: string;
  /** Render compact inline summary instead of a table. */
  compact?: boolean;
}

function formatUsdc(amount6d: bigint): string {
  const d = Number(amount6d) / 1_000_000;
  return `$${d.toFixed(d < 0.01 ? 6 : 2)}`;
}

function formatNative(amountWei: bigint, symbol: string): string {
  const d = Number(amountWei) / 1e18;
  return `${d.toFixed(6)} ${symbol}`;
}

export function FeeBreakdown({ quote, nativeSymbol, compact }: FeeBreakdownProps) {
  if (compact) {
    return (
      <span style={{ fontSize: 12, color: '#6b7280' }}>
        Fee {formatUsdc(quote.magnetaFeeUsdc)} · Routing {formatUsdc(quote.routingFeeUsdc)} · Gas{' '}
        {formatNative(quote.gasCostNative, nativeSymbol)}
      </span>
    );
  }

  return (
    <table style={{ width: '100%', fontSize: 13, borderCollapse: 'collapse' }}>
      <tbody>
        <Row label="Magneta fee (0.15%)" value={formatUsdc(quote.magnetaFeeUsdc)} />
        <Row label="Routing (bridge + aggregator)" value={formatUsdc(quote.routingFeeUsdc)} hint="Estimated — passed through from LI.FI / CCTP / LayerZero quotes" />
        <Row label="Destination gas" value={formatNative(quote.gasCostNative, nativeSymbol)} hint="Paid in native, not USDC" />
        <tr>
          <td style={{ padding: '6px 0', borderTop: '1px solid #e5e7eb', fontWeight: 600 }}>You approve (USDC)</td>
          <td style={{ padding: '6px 0', borderTop: '1px solid #e5e7eb', textAlign: 'right', fontWeight: 600 }}>
            {formatUsdc(quote.userTotalUsdc)}
          </td>
        </tr>
      </tbody>
    </table>
  );
}

function Row({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <tr>
      <td style={{ padding: '4px 0', color: '#374151' }}>
        {label}
        {hint && <div style={{ fontSize: 11, color: '#9ca3af' }}>{hint}</div>}
      </td>
      <td style={{ padding: '4px 0', textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{value}</td>
    </tr>
  );
}
