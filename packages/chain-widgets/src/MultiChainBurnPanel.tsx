/**
 * Multi-chain Burn (or Remove) panel — one row per LP position across
 * chains, each with its own slider + Max chip. Single dispatch button
 * at the bottom that hands selected (position, lpAmount) pairs back to
 * the parent for sequential on-chain execution.
 *
 * Visual:
 *   ┌─────────────────────────────────────────────────────────────────────┐
 *   │ ☑ Polygon   WPOL / TT2MF   LP: 0.1     [▬▬▬▬▬▬▬▬▬▬▬] 50% [Max]    │
 *   │             you'll lock ~0.575 WPOL + ~0.001 TT2MF                  │
 *   │ ☑ Base      WETH / TT2MF   LP: 0.05    [▬▬▬▬▬▬] 30% [Max]          │
 *   │             you'll lock ~0.015 WETH + ~0.0003 TT2MF                 │
 *   │ ☐ Arbitrum  WETH / TT2MF   LP: 0.02    [—] (unchecked)              │
 *   ├─────────────────────────────────────────────────────────────────────┤
 *   │ ⚠ Burning is irreversible across all selected chains                │
 *   │ [   Burn on 2 chains   ]                                            │
 *   └─────────────────────────────────────────────────────────────────────┘
 *
 * Status pills appear inline next to each row's chain name when the
 * caller passes per-leg `progress` (typically from the existing
 * useMultiChainLp dispatcher in the Tokens repo).
 */
import { useEffect, useMemo, useState } from 'react';
import { formatUnits } from 'viem';
import type { MultiChainLpPosition } from './useMultiChainLpPositions';

export interface BurnLeg {
  position: MultiChainLpPosition;
  lpAmount: bigint;
}

export interface MultiChainBurnPanelProps {
  positions:    MultiChainLpPosition[];
  isProcessing?: boolean;
  /** Per-leg dispatch progress; chainId-keyed. */
  progress?:    Array<{ chainId: number; status: string }>;
  /** Confirm + dispatch. Receives only the rows the user selected. */
  onSubmit:     (legs: BurnLeg[]) => void | Promise<void>;
  /** "burn" (default) → red + irreversible warning. "remove" → blue. */
  variant?:     'burn' | 'remove';
}

const PCT_CHIPS = [25, 50, 75, 100] as const;

export function MultiChainBurnPanel({
  positions,
  isProcessing = false,
  progress,
  onSubmit,
  variant = 'burn',
}: MultiChainBurnPanelProps) {
  const isBurn = variant === 'burn';
  const verb   = isBurn ? 'Burn' : 'Remove';

  // Group positions by the user-side token's symbol (the non-wnative side
  // of the pair). Each group represents one logical token deployed across
  // multiple chains — TT2MF on Polygon+Base+Arbitrum is one group with
  // 3 rows. Critical for users with 30+ pools to avoid scroll overload.
  const tokenGroups = useMemo(() => {
    const groups: Record<string, MultiChainLpPosition[]> = {};
    for (const p of positions) {
      const sym = p.tokenSide.toLowerCase() === p.token0.toLowerCase() ? p.symbol0 : p.symbol1;
      (groups[sym] ??= []).push(p);
    }
    return groups;
  }, [positions]);
  const groupKeys = useMemo(() => Object.keys(tokenGroups).sort(), [tokenGroups]);

  // Picked group state. When only 1 group exists, auto-pick it.
  const [pickedSymbol, setPickedSymbol] = useState<string | null>(null);
  useEffect(() => {
    if (groupKeys.length === 1 && pickedSymbol !== groupKeys[0]) {
      setPickedSymbol(groupKeys[0]);
    } else if (pickedSymbol && !groupKeys.includes(pickedSymbol)) {
      setPickedSymbol(null);
    }
  }, [groupKeys.join(','), pickedSymbol]);

  const visiblePositions = pickedSymbol ? (tokenGroups[pickedSymbol] ?? []) : [];

  // Per-pair state: selected + percentage slider.
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [percents, setPercents] = useState<Record<string, number>>({});

  // Reset selection when switching token groups so stale percentages
  // don't carry over.
  useEffect(() => {
    setSelected(new Set());
    setPercents({});
  }, [pickedSymbol]);

  const fmt = (raw: bigint, decimals: number) =>
    Number(formatUnits(raw, decimals)).toLocaleString(undefined, { maximumFractionDigits: 6 });

  const toggleSelect = (pair: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(pair)) next.delete(pair);
      else { next.add(pair); if (!percents[pair]) setPercents((p) => ({ ...p, [pair]: 50 })); }
      return next;
    });
  };

  const setPercent = (pair: string, v: number) => {
    setPercents((p) => ({ ...p, [pair]: Math.max(0, Math.min(100, v)) }));
  };

  const selectedCount = selected.size;
  const legs: BurnLeg[] = useMemo(() => {
    const out: BurnLeg[] = [];
    for (const p of visiblePositions) {
      if (!selected.has(p.pair)) continue;
      const pct = BigInt(percents[p.pair] ?? 0);
      if (pct === 0n) continue;
      out.push({ position: p, lpAmount: (p.userLp * pct) / 100n });
    }
    return out;
  }, [visiblePositions, selected, percents]);

  if (positions.length === 0) {
    return (
      <div className="p-4 text-center text-sm text-gray-500 italic">
        No LP positions found across the supported chains. Create or add liquidity first.
      </div>
    );
  }

  return (
    <div className="space-y-3">
      {/* Token group dropdown — narrows the list to one logical token's
          positions across chains. Hidden when there's only one group
          (auto-picked) or none. */}
      {groupKeys.length > 1 && (
        <div className="space-y-1">
          <label className="text-xs uppercase tracking-wider text-gray-500">
            Pick a token to manage across chains
          </label>
          <select
            value={pickedSymbol ?? ''}
            onChange={(e) => setPickedSymbol(e.target.value || null)}
            disabled={isProcessing}
            className="w-full px-3 py-2 rounded-lg border border-gray-300 dark:border-zinc-700 bg-white dark:bg-zinc-900/50 text-sm text-gray-900 dark:text-white focus:outline-none focus:border-blue-500"
          >
            <option value="">— pick a token ({groupKeys.length} available) —</option>
            {groupKeys.map((sym) => {
              const cnt = tokenGroups[sym].length;
              return (
                <option key={sym} value={sym}>
                  {sym} ({cnt} chain{cnt > 1 ? 's' : ''})
                </option>
              );
            })}
          </select>
        </div>
      )}

      {!pickedSymbol && groupKeys.length > 1 && (
        <p className="text-sm text-gray-500 italic text-center py-4">
          Pick a token above to see its LP positions across chains.
        </p>
      )}

      {pickedSymbol && (
      <div className="rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800/50 divide-y divide-gray-200 dark:divide-gray-700/50">
        {visiblePositions.map((p) => {
          const isSelected = selected.has(p.pair);
          const pct = percents[p.pair] ?? 0;
          const lpToBurn = (p.userLp * BigInt(pct)) / 100n;
          const expected0 = p.totalSupply > 0n ? (p.reserve0 * lpToBurn) / p.totalSupply : 0n;
          const expected1 = p.totalSupply > 0n ? (p.reserve1 * lpToBurn) / p.totalSupply : 0n;
          const legProgress = progress?.find((x) => x.chainId === p.chainId);

          return (
            <div key={p.pair} className={`p-3 transition-opacity ${isSelected ? '' : 'opacity-60'}`}>
              <div className="flex items-center gap-3">
                <button
                  type="button"
                  onClick={() => toggleSelect(p.pair)}
                  disabled={isProcessing}
                  className={`flex-shrink-0 w-5 h-5 rounded border-2 flex items-center justify-center transition-colors ${isSelected
                    ? (isBurn ? 'border-red-500 bg-red-500' : 'border-blue-500 bg-blue-500')
                    : 'border-gray-400 dark:border-gray-600 hover:border-blue-400'}`}
                >
                  {isSelected && (
                    <svg className="w-3 h-3 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="3" d="M5 13l4 4L19 7" />
                    </svg>
                  )}
                </button>
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-xs uppercase tracking-wider text-gray-500 capitalize">{p.chainName}</span>
                    <span className="text-sm font-semibold text-gray-900 dark:text-white">
                      {p.symbol0} / {p.symbol1}
                    </span>
                    {legProgress && (
                      <span className={`text-[10px] px-2 py-0.5 rounded ${
                        legProgress.status === 'success' ? 'bg-green-500/20 text-green-400' :
                        legProgress.status === 'error'   ? 'bg-red-500/20 text-red-400' :
                        legProgress.status === 'pending' ? 'bg-zinc-700/50 text-gray-400' :
                                                          'bg-pale-yellow/20 text-pale-yellow'
                      }`}>{legProgress.status}</span>
                    )}
                  </div>
                  <div className="text-[11px] text-gray-500 mt-0.5">
                    Your LP: <span className="font-mono">{fmt(p.userLp, 18)}</span>
                    {' · '}
                    {(Number((p.userLp * 10000n) / (p.totalSupply || 1n)) / 100).toFixed(4)}% of pool
                  </div>
                </div>
                <span className={`text-sm font-semibold ${isBurn ? 'text-red-500' : 'text-blue-500'} w-12 text-right`}>{pct}%</span>
              </div>

              {isSelected && (
                <div className="mt-2 ml-8 space-y-2">
                  <input
                    type="range"
                    min={0}
                    max={100}
                    step={1}
                    value={pct}
                    onChange={(e) => setPercent(p.pair, Number(e.target.value))}
                    disabled={isProcessing}
                    className={`w-full ${isBurn ? 'accent-red-500' : 'accent-blue-500'}`}
                  />
                  <div className="flex gap-2">
                    {PCT_CHIPS.map((v) => (
                      <button
                        key={v}
                        type="button"
                        onClick={() => setPercent(p.pair, v)}
                        disabled={isProcessing}
                        className={`flex-1 px-2 py-1 rounded text-[11px] border ${pct === v
                          ? (isBurn ? 'border-red-500 bg-red-500/10 text-red-400'
                                    : 'border-blue-500 bg-blue-500/10 text-blue-400')
                          : 'border-gray-300 dark:border-gray-700 text-gray-500 hover:border-blue-400'}`}
                      >
                        {v === 100 ? 'Max' : `${v}%`}
                      </button>
                    ))}
                  </div>
                  <div className="text-[11px] text-gray-600 dark:text-gray-400 px-1">
                    {isBurn ? "You'll lock " : "You'll receive "}
                    ~{fmt(expected0, p.decimals0)} {p.symbol0}
                    {' + '}
                    ~{fmt(expected1, p.decimals1)} {p.symbol1}
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>
      )}

      {pickedSymbol && isBurn && (
        <div className="p-2 rounded bg-red-500/10 border border-red-500/30 text-[11px] text-red-400">
          ⚠ Burning is irreversible. The selected LP tokens will be sent to a dead address on each chain — the underlying liquidity becomes permanently locked.
        </div>
      )}

      <button
        type="button"
        onClick={() => onSubmit(legs)}
        disabled={isProcessing || legs.length === 0 || !pickedSymbol}
        className={`w-full py-2.5 rounded-lg text-white text-sm font-semibold disabled:opacity-50 disabled:cursor-not-allowed ${
          isBurn ? 'bg-red-600 hover:bg-red-700' : 'bg-blue-600 hover:bg-blue-700'
        }`}
      >
        {isProcessing
          ? `Dispatching… (${(progress?.filter((p) => p.status === 'success').length ?? 0)}/${legs.length} done)`
          : `${verb} on ${selectedCount} chain${selectedCount === 1 ? '' : 's'}`}
      </button>
    </div>
  );
}
