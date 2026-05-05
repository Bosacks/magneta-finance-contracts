/**
 * Cross-chain version of useUserLpPositions — scans every chain in
 * parallel and returns one flat list with chain metadata attached.
 *
 * Caller passes a `configs` array (one per chain to scan) so the hook
 * stays decoupled from any specific factory layout. Each config carries:
 *   - publicClient (viem) bound to that chain
 *   - oftFactories (the user-tokens registries to read)
 *   - v2Factory (to derive pair addresses from token + wnative)
 *   - wnative (the chain's wrapped native side)
 *
 * Used by the multi-chain Burn UX: once the user has positions across
 * Polygon + Base + Arbitrum + …, we list them all in one panel with a
 * per-row slider so the user picks how much to burn on each chain in
 * a single review.
 */
import { useEffect, useState } from 'react';
import { erc20Abi, type Address, type PublicClient } from 'viem';
import type { LpPosition } from './useUserLpPositions';

const FACTORY_ABI = [
  { type: 'function', stateMutability: 'view', name: 'getUserTokens',
    inputs: [{ name: 'user', type: 'address' }], outputs: [{ type: 'address[]' }] },
  { type: 'function', stateMutability: 'view', name: 'getPair',
    inputs: [{ name: 'tokenA', type: 'address' }, { name: 'tokenB', type: 'address' }],
    outputs: [{ type: 'address' }] },
] as const;

const PAIR_ABI = [
  { type: 'function', stateMutability: 'view', name: 'token0',     inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', stateMutability: 'view', name: 'token1',     inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', stateMutability: 'view', name: 'getReserves', inputs: [], outputs: [
    { type: 'uint112' }, { type: 'uint112' }, { type: 'uint32' },
  ] },
  { type: 'function', stateMutability: 'view', name: 'totalSupply', inputs: [], outputs: [{ type: 'uint256' }] },
] as const;

const ZERO = '0x0000000000000000000000000000000000000000' as const;

export interface ChainScanConfig {
  chainId:      number;
  chainName:    string;
  publicClient: PublicClient | undefined;
  /** OFTStandard + OFTAutoLiquidity factory addresses (or any other
   *  registry that exposes `getUserTokens(user)`). */
  oftFactories: Address[];
  /** V2 factory for `getPair(token, wnative)`. */
  v2Factory:    Address;
  /** Wrapped-native address for this chain. */
  wnative:      Address;
}

export interface MultiChainLpPosition extends LpPosition {
  chainId:   number;
  chainName: string;
  /** The non-wnative side of the pair = the "token" arg for LPModule. */
  tokenSide: Address;
}

export interface UseMultiChainLpPositionsResult {
  positions: MultiChainLpPosition[];
  loading:   boolean;
  error:     string | null;
  refresh:   () => void;
}

export function useMultiChainLpPositions(
  creator: Address | undefined,
  configs: ChainScanConfig[],
  refetchKey: number = 0,
): UseMultiChainLpPositionsResult {
  const [positions, setPositions] = useState<MultiChainLpPosition[]>([]);
  const [loading,   setLoading]   = useState(false);
  const [error,     setError]     = useState<string | null>(null);
  const [tick,      setTick]      = useState(0);

  useEffect(() => {
    if (!creator || configs.length === 0) {
      setPositions([]); setLoading(false); setError(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);

    (async () => {
      const all: MultiChainLpPosition[] = [];

      await Promise.all(configs.map(async (cfg) => {
        if (!cfg.publicClient) return;
        const client = cfg.publicClient;

        try {
          // 1. user tokens on this chain (across both factory variants).
          const tokens: Address[] = [];
          for (const f of cfg.oftFactories) {
            try {
              const list = (await client.readContract({
                address:      f,
                abi:          FACTORY_ABI,
                functionName: 'getUserTokens',
                args:         [creator],
              })) as readonly Address[];
              tokens.push(...list);
            } catch { /* factory not present — skip */ }
          }
          if (tokens.length === 0) return;

          // 2. derive pair addresses (TOKEN + wnative).
          const pairs = await Promise.all(tokens.map(async (t) => {
            try {
              const p = (await client.readContract({
                address:      cfg.v2Factory,
                abi:          FACTORY_ABI,
                functionName: 'getPair',
                args:         [t, cfg.wnative],
              })) as Address;
              return p === ZERO ? null : p;
            } catch { return null; }
          }));
          const validPairs = Array.from(new Set(pairs.filter((p): p is Address => !!p)));
          if (validPairs.length === 0) return;

          // 3. read pair state + user LP for each.
          await Promise.all(validPairs.map(async (pair) => {
            try {
              const [token0, token1, reserves, totalSupply, userLp] = await Promise.all([
                client.readContract({ address: pair, abi: PAIR_ABI, functionName: 'token0' }) as Promise<Address>,
                client.readContract({ address: pair, abi: PAIR_ABI, functionName: 'token1' }) as Promise<Address>,
                client.readContract({ address: pair, abi: PAIR_ABI, functionName: 'getReserves' }) as Promise<readonly [bigint, bigint, number]>,
                client.readContract({ address: pair, abi: PAIR_ABI, functionName: 'totalSupply' }) as Promise<bigint>,
                client.readContract({ address: pair, abi: erc20Abi, functionName: 'balanceOf', args: [creator] }) as Promise<bigint>,
              ]);
              if (userLp === 0n) return;

              const [symbol0, symbol1, decimals0, decimals1] = await Promise.all([
                (client.readContract({ address: token0, abi: erc20Abi, functionName: 'symbol' })   as Promise<string>).catch(() => '?'),
                (client.readContract({ address: token1, abi: erc20Abi, functionName: 'symbol' })   as Promise<string>).catch(() => '?'),
                (client.readContract({ address: token0, abi: erc20Abi, functionName: 'decimals' }) as Promise<number>).catch(() => 18),
                (client.readContract({ address: token1, abi: erc20Abi, functionName: 'decimals' }) as Promise<number>).catch(() => 18),
              ]);

              const wn = cfg.wnative.toLowerCase();
              const tokenSide = token0.toLowerCase() === wn ? token1 : token0;

              all.push({
                pair, token0, token1,
                symbol0, symbol1,
                decimals0: Number(decimals0),
                decimals1: Number(decimals1),
                reserve0: reserves[0],
                reserve1: reserves[1],
                totalSupply,
                userLp,
                chainId:   cfg.chainId,
                chainName: cfg.chainName,
                tokenSide,
              });
            } catch { /* pair read failed — skip */ }
          }));
        } catch { /* chain-level failure — skip */ }
      }));

      if (!cancelled) {
        all.sort((a, b) => {
          if (a.chainName !== b.chainName) return a.chainName.localeCompare(b.chainName);
          return b.userLp > a.userLp ? 1 : b.userLp < a.userLp ? -1 : 0;
        });
        setPositions(all);
        setLoading(false);
      }
    })().catch((e: any) => {
      if (!cancelled) { setError(e?.message ?? 'unknown'); setLoading(false); }
    });

    return () => { cancelled = true; };
  }, [creator, configs.map((c) => c.chainId).join(','), refetchKey, tick]);

  return {
    positions,
    loading,
    error,
    refresh: () => setTick((t) => t + 1),
  };
}
