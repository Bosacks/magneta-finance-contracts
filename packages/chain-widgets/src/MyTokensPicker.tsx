/**
 * "Pick from your Magneta tokens" dropdown — shared between the DEX
 * (multi-chain Create LP) and Tokens (multi-chain Create LP & Buy).
 *
 * Pure UI: takes a `groups` map (from `useUserCreatedTokens`) and emits
 * a `PickedToken` payload when the user selects a symbol. The payload
 * includes the master address (first chain alphabetically) and the
 * per-chain address map, so the parent form can auto-fill its master
 * input + per-chain overrides + chain checkboxes in one click.
 */
import { useState } from 'react';
import type { Address } from 'viem';
import type { CreatedTokenGroups, CreatedTokenRow } from './useUserCreatedTokens';

export interface PickedToken {
  symbol:         string;
  /** First chain alphabetically — the parent typically uses this as the
   *  "master" address shown in the form, with the rest as per-chain
   *  overrides. */
  masterAddress:  Address;
  masterChainId:  number;
  /** Per-chain map (chainId → address) for ALL chains where this logical
   *  token exists. The parent should auto-select these chains in its
   *  multi-chain checkbox list. */
  addressByChain: Record<number, Address>;
  /** Decimals matching the master row — typically 18 across deploys but
   *  surfaced for completeness. */
  decimals:       number;
  name:           string;
}

export interface MyTokensPickerProps {
  groups:    CreatedTokenGroups;
  loading?:  boolean;
  onPick:    (picked: PickedToken) => void;
  /** Trigger label override. */
  label?:    string;
  /** When true, hides the per-row chain list under each symbol entry —
   *  useful in narrow column layouts. */
  compact?:  boolean;
}

export function MyTokensPicker({ groups, loading, onPick, label, compact }: MyTokensPickerProps) {
  const [open, setOpen] = useState(false);
  const groupKeys = Object.keys(groups).sort();

  const handlePick = (symbol: string, sorted: CreatedTokenRow[]) => {
    const master = sorted[0];
    const addressByChain: Record<number, Address> = {};
    for (const r of sorted) addressByChain[r.chainId] = r.address;
    onPick({
      symbol,
      masterAddress: master.address,
      masterChainId: master.chainId,
      addressByChain,
      decimals:      master.decimals,
      name:          master.name,
    });
    setOpen(false);
  };

  return (
    <div className="space-y-1">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="w-full px-3 py-2 rounded-lg border border-gray-300 dark:border-zinc-700 bg-white dark:bg-zinc-900/50 text-left text-sm hover:border-blue-500 transition-colors flex items-center justify-between"
      >
        <span className="text-gray-700 dark:text-gray-300">
          {loading
            ? 'Scanning your Magneta tokens…'
            : (label ?? `Pick from your tokens (${groupKeys.length})`)}
        </span>
        <svg className={`w-4 h-4 text-gray-400 transition-transform ${open ? 'rotate-180' : ''}`} fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      {open && !loading && (
        <div className="rounded-lg border border-gray-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 max-h-64 overflow-y-auto">
          {groupKeys.length === 0 ? (
            <p className="px-3 py-4 text-xs text-gray-500 text-center">
              No Magneta-created tokens found on the connected wallet.
            </p>
          ) : (
            groupKeys.map((symbol) => {
              const sorted = [...groups[symbol]].sort((a, b) => a.chainName.localeCompare(b.chainName));
              return (
                <button
                  key={symbol}
                  type="button"
                  onClick={() => handlePick(symbol, sorted)}
                  className="w-full px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-zinc-800 border-b border-gray-100 dark:border-zinc-800 last:border-b-0"
                >
                  <div className="flex items-center justify-between">
                    <span className="font-semibold text-sm text-gray-900 dark:text-white">{symbol}</span>
                    <span className="text-[10px] text-gray-500">{sorted.length} chain{sorted.length === 1 ? '' : 's'}</span>
                  </div>
                  {!compact && (
                    <div className="text-[10px] text-gray-500 dark:text-gray-400 capitalize mt-0.5">
                      {sorted.map((r) => r.chainName).join(' · ')}
                    </div>
                  )}
                </button>
              );
            })
          )}
        </div>
      )}
    </div>
  );
}
