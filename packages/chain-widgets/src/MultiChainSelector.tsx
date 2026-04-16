import * as React from 'react';
import { ALL_CHAINS, type ChainId, type ChainInfo } from '@magneta/chain-service';

export interface MultiChainSelectorProps {
  /** Currently selected destination chain ids (controlled). */
  value: ChainId[];
  onChange: (next: ChainId[]) => void;
  /** When true, only chains with a live gateway are selectable; roadmap chains are rendered disabled. */
  onlyLive?: boolean;
  /** Hide any chain whose kind is in this list. */
  excludeKinds?: ChainInfo['kind'][];
  /** Optional className on the root element. */
  className?: string;
}

/**
 * Grid-of-chains picker. Lists every supported chain equally — no ordering by
 * ecosystem, no "featured" chain. Roadmap chains (gateway not yet live) are
 * visible but disabled with a "Coming soon" tooltip.
 */
export function MultiChainSelector({
  value,
  onChange,
  onlyLive = false,
  excludeKinds = [],
  className,
}: MultiChainSelectorProps) {
  const chains = ALL_CHAINS.filter((c) => !excludeKinds.includes(c.kind));

  const toggle = (id: ChainId) => {
    onChange(value.includes(id) ? value.filter((v) => v !== id) : [...value, id]);
  };

  return (
    <div
      className={className}
      role="group"
      aria-label="Select destination chains"
      style={{
        display: 'grid',
        gridTemplateColumns: 'repeat(auto-fill, minmax(140px, 1fr))',
        gap: 8,
      }}
    >
      {chains.map((chain) => {
        const selected = value.includes(chain.id);
        const disabled = onlyLive && !chain.gatewayLive;
        return (
          <button
            key={String(chain.id)}
            type="button"
            onClick={() => !disabled && toggle(chain.id)}
            disabled={disabled}
            aria-pressed={selected}
            title={disabled ? `${chain.name} — coming soon` : chain.name}
            style={{
              padding: 12,
              border: selected ? '2px solid currentColor' : '1px solid #d1d5db',
              borderRadius: 10,
              background: disabled ? '#f3f4f6' : selected ? '#eff6ff' : 'white',
              cursor: disabled ? 'not-allowed' : 'pointer',
              opacity: disabled ? 0.6 : 1,
              textAlign: 'left',
              display: 'flex',
              flexDirection: 'column',
              gap: 4,
            }}
          >
            <span style={{ fontWeight: 600, fontSize: 14 }}>{chain.name}</span>
            <span style={{ fontSize: 12, color: '#6b7280' }}>
              {chain.kind.toUpperCase()} · {chain.nativeSymbol}
            </span>
            {!chain.gatewayLive && (
              <span style={{ fontSize: 11, color: '#9ca3af' }}>Coming soon</span>
            )}
          </button>
        );
      })}
    </div>
  );
}
