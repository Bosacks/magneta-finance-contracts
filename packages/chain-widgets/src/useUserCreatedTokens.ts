/**
 * Cross-chain "tokens you've created via Magneta" registry — reads each
 * chain's OFTStandardFactory + OFTAutoLiquidityFactory `getUserTokens(creator)`
 * and groups by symbol so a logical token deployed on multiple chains
 * (TT2MF on Polygon+Base+Arbitrum) shows up as one entry with three rows.
 *
 * Caller passes pre-built configs (one per chain) so this stays detached
 * from any specific wagmi setup. The DEX and Tokens repos build their
 * configs from their own GATEWAY_CHAINS + getPublicClient.
 */
import { useEffect, useState } from 'react';
import { erc20Abi, type Address, type PublicClient } from 'viem';

const FACTORY_ABI = [{
  type: 'function',
  stateMutability: 'view',
  name: 'getUserTokens',
  inputs: [{ name: 'user', type: 'address' }],
  outputs: [{ type: 'address[]' }],
}] as const;

export interface CreatedTokenRow {
  chainId:   number;
  chainName: string;
  address:   Address;
  symbol:    string;
  name:      string;
  decimals:  number;
  /** 'standard' or 'autoLiquidity' — which factory deployed it. */
  variant:   'standard' | 'autoLiquidity';
}

export interface UserTokensScanConfig {
  chainId:      number;
  chainName:    string;
  publicClient: PublicClient | undefined;
  /** Factory addresses to query (typically OFTStandard + OFTAutoLiquidity). */
  factories:    Array<{ address: Address; variant: 'standard' | 'autoLiquidity' }>;
}

/** Tokens grouped by uppercase symbol. */
export type CreatedTokenGroups = Record<string, CreatedTokenRow[]>;

export interface UseUserCreatedTokensResult {
  groups:  CreatedTokenGroups;
  rows:    CreatedTokenRow[];
  loading: boolean;
  error:   string | null;
}

export function useUserCreatedTokens(
  creator: Address | undefined,
  configs: UserTokensScanConfig[],
): UseUserCreatedTokensResult {
  const [rows, setRows] = useState<CreatedTokenRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!creator || configs.length === 0) {
      setRows([]); setLoading(false); setError(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);

    (async () => {
      const collected: CreatedTokenRow[] = [];

      await Promise.all(configs.map(async (cfg) => {
        if (!cfg.publicClient) return;
        const client = cfg.publicClient;

        await Promise.all(cfg.factories.map(async ({ address, variant }) => {
          let tokens: readonly Address[] = [];
          try {
            tokens = (await client.readContract({
              address,
              abi: FACTORY_ABI,
              functionName: 'getUserTokens',
              args: [creator],
            })) as readonly Address[];
          } catch {
            return; // factory missing or RPC failure — skip silently
          }

          const enriched = await Promise.all(tokens.map(async (tokenAddr) => {
            try {
              const [symbol, name, decimals] = await Promise.all([
                client.readContract({ address: tokenAddr, abi: erc20Abi, functionName: 'symbol' })   as Promise<string>,
                client.readContract({ address: tokenAddr, abi: erc20Abi, functionName: 'name' })     as Promise<string>,
                client.readContract({ address: tokenAddr, abi: erc20Abi, functionName: 'decimals' }) as Promise<number>,
              ]);
              return {
                chainId:   cfg.chainId,
                chainName: cfg.chainName,
                address:   tokenAddr,
                symbol, name,
                decimals:  Number(decimals),
                variant,
              } satisfies CreatedTokenRow;
            } catch { return null; }
          }));
          for (const r of enriched) if (r) collected.push(r);
        }));
      }));

      if (cancelled) return;
      setRows(collected);
      setLoading(false);
    })().catch((e: any) => {
      if (cancelled) return;
      setError(e?.shortMessage ?? e?.message ?? 'unknown');
      setLoading(false);
    });

    return () => { cancelled = true; };
  }, [creator, configs.map((c) => c.chainId).join(',')]);

  // Group by uppercase symbol (cheap, no need for useMemo).
  const groups: CreatedTokenGroups = {};
  for (const r of rows) {
    const key = r.symbol.toUpperCase();
    (groups[key] ??= []).push(r);
  }

  return { groups, rows, loading, error };
}
