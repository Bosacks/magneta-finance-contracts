/**
 * Pure-UI Remove Liquidity panel — the slider + chips + Remove All UX
 * shared by both the DEX (V2 router path) and Tokens (Gateway/LPModule
 * path). The on-chain submission is callback-driven so the parent picks
 * which path to use.
 *
 * Layout:
 *   ┌──────────────────────────────────────────┐
 *   │ TT2MF / WPOL                Manage        │
 *   │ Your LP: 0.05  ($12.30)                   │
 *   ├──────────────────────────────────────────┤
 *   │ ┌──────────────[ slider ]────────────┐    │
 *   │ [25%] [50%] [75%] [Max]                   │
 *   │                                           │
 *   │ You receive: ~0.0011 TT2MF + ~0.575 WPOL │
 *   │                                           │
 *   │ [   Remove Liquidity (50%)   ]            │
 *   │ [   Remove All                ]            │
 *   └──────────────────────────────────────────┘
 *
 * Callers compute `expectedToken0` / `expectedToken1` from reserves +
 * totalSupply + percentage, since the UI doesn't reach the chain.
 */
import { useState, useMemo } from 'react';
import { formatUnits } from 'viem';

export interface RemovePanelProps {
  /** Display label, e.g. "TT2MF / WPOL". */
  pairLabel:        string;
  /** User's current LP token balance (raw bigint, 18 dec). */
  userLpBalance:    bigint;
  /** Pair total supply (for ratio calc). */
  totalSupply:      bigint;
  /** Reserves and decimals for display + amount preview. */
  reserve0:         bigint;
  reserve1:         bigint;
  symbol0:          string;
  symbol1:          string;
  decimals0:        number;
  decimals1:        number;
  /** "in flight" lock from the parent (approve / tx pending). */
  isProcessing?:    boolean;
  /** Status hint shown above the buttons (e.g. "Approving LP token…"). */
  statusHint?:      string;
  /** Called with the bigint amount of LP to remove (0 < x ≤ userLpBalance). */
  onRemove:         (lpAmount: bigint) => void | Promise<void>;
  /** Optional close button on the top-right (e.g. for inline panels). */
  onClose?:         () => void;
  /**
   * "remove" (default) → user gets the underlying tokens back. Blue primary
   * button, red border on the Max shortcut.
   * "burn" → LP is sent to dead address (irreversible). All buttons red,
   * primary filled, label says "Burn" / "Burn All", and the panel surfaces
   * an extra warning banner.
   */
  variant?:         "remove" | "burn";
}

const PCT_CHIPS = [25, 50, 75, 100] as const;

export function RemovePanel({
  pairLabel,
  userLpBalance,
  totalSupply,
  reserve0,
  reserve1,
  symbol0,
  symbol1,
  decimals0,
  decimals1,
  isProcessing = false,
  statusHint,
  onRemove,
  onClose,
  variant = "remove",
}: RemovePanelProps) {
  const isBurn = variant === "burn";
  const verb   = isBurn ? "Burn" : "Remove";
  const [percent, setPercent] = useState(50);

  const lpToRemove = useMemo(() => (userLpBalance * BigInt(percent)) / 100n, [userLpBalance, percent]);
  const share = totalSupply > 0n ? (lpToRemove * 10000n) / totalSupply : 0n; // bps

  const expected0 = useMemo(
    () => (totalSupply > 0n ? (reserve0 * lpToRemove) / totalSupply : 0n),
    [reserve0, totalSupply, lpToRemove],
  );
  const expected1 = useMemo(
    () => (totalSupply > 0n ? (reserve1 * lpToRemove) / totalSupply : 0n),
    [reserve1, totalSupply, lpToRemove],
  );

  const fmt = (raw: bigint, decimals: number) =>
    Number(formatUnits(raw, decimals)).toLocaleString(undefined, { maximumFractionDigits: 6 });

  const disabled = isProcessing || userLpBalance === 0n || percent === 0;

  return (
    <div className="space-y-3 p-4 rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800/50">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="min-w-0">
          <div className="font-semibold text-gray-900 dark:text-white">{pairLabel}</div>
          <div className="text-xs text-gray-500 dark:text-gray-400">
            Your LP: <span className="font-mono">{fmt(userLpBalance, 18)}</span> ({(Number(share) / 100).toFixed(4)}% of pool)
          </div>
        </div>
        {onClose && (
          <button
            type="button"
            onClick={onClose}
            className="text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 text-lg leading-none px-2"
          >
            ×
          </button>
        )}
      </div>

      {/* Slider */}
      <div>
        <div className="flex items-center justify-between mb-1">
          <span className="text-xs text-gray-500">Amount to remove</span>
          <span className="text-sm font-semibold text-blue-600 dark:text-blue-400">{percent}%</span>
        </div>
        <input
          type="range"
          min={0}
          max={100}
          step={1}
          value={percent}
          onChange={(e) => setPercent(Number(e.target.value))}
          disabled={isProcessing}
          className="w-full accent-blue-500"
        />
        <div className="flex gap-2 mt-2">
          {PCT_CHIPS.map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => setPercent(p)}
              disabled={isProcessing}
              className={`flex-1 px-2 py-1 rounded text-xs border ${percent === p
                ? 'border-blue-500 bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300'
                : 'border-gray-300 dark:border-gray-700 text-gray-600 dark:text-gray-400 hover:border-blue-400'}`}
            >
              {p === 100 ? 'Max' : `${p}%`}
            </button>
          ))}
        </div>
      </div>

      {/* Expected output */}
      <div className="text-xs text-gray-600 dark:text-gray-400 p-2 rounded bg-gray-50 dark:bg-gray-900/30">
        You&apos;ll receive ~{fmt(expected0, decimals0)} {symbol0} + ~{fmt(expected1, decimals1)} {symbol1}
        <span className="text-gray-500 dark:text-gray-500"> (before fees / slippage)</span>
      </div>

      {/* Burn-only warning */}
      {isBurn && (
        <div className="p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-400">
          ⚠ Burning is irreversible. The LP tokens will be sent to a dead address and the underlying liquidity is locked forever.
        </div>
      )}

      {statusHint && (
        <p className="text-[11px] text-gray-500 dark:text-gray-400 italic">{statusHint}</p>
      )}

      {/* Actions */}
      <div className="grid grid-cols-2 gap-2">
        <button
          type="button"
          onClick={() => onRemove(lpToRemove)}
          disabled={disabled}
          className={`w-full py-2 rounded-lg text-white text-sm font-medium disabled:opacity-50 disabled:cursor-not-allowed ${
            isBurn ? "bg-red-600 hover:bg-red-700" : "bg-blue-600 hover:bg-blue-700"
          }`}
        >
          {verb} {percent}%
        </button>
        <button
          type="button"
          onClick={() => { setPercent(100); onRemove(userLpBalance); }}
          disabled={isProcessing || userLpBalance === 0n}
          className={`w-full py-2 rounded-lg text-sm font-medium disabled:opacity-50 disabled:cursor-not-allowed ${
            isBurn
              ? "bg-red-700 hover:bg-red-800 text-white"
              : "border border-red-500/50 text-red-500 hover:bg-red-500/10"
          }`}
        >
          {verb} All
        </button>
      </div>
    </div>
  );
}
