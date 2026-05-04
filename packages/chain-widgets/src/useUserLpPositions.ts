/**
 * Discover the user's LP positions for a given list of V2 pair addresses.
 *
 * Pure logic helper — takes a viem `PublicClient` so it stays detached from
 * wagmi's React layer. Both the DEX (My Pools tab) and Tokens (Liquidity
 * Manage → Remove) call this with their own list of candidate pair
 * addresses (sourced from localStorage trackers / OFT factory scans / etc.)
 * and get back the subset where the user actually holds non-zero LP, with
 * everything needed to render `<RemovePanel>` (reserves, total supply,
 * token metadata).
 *
 * Each pair adds 5 reads (token0, token1, reserves, totalSupply, balanceOf)
 * + 6 reads for token metadata (3 per token: symbol, decimals, …). At ~10
 * pairs that's ~110 reads — cheap with our self-hosted RPCs, fine with
 * publicnode/llamarpc fallback for the chains we don't run.
 */
import { useEffect, useState } from 'react';
import { erc20Abi, type Address, type PublicClient } from 'viem';

const PAIR_ABI = [
  { type: 'function', stateMutability: 'view', name: 'token0',     inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', stateMutability: 'view', name: 'token1',     inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', stateMutability: 'view', name: 'getReserves', inputs: [], outputs: [
    { type: 'uint112' }, { type: 'uint112' }, { type: 'uint32' },
  ] },
  { type: 'function', stateMutability: 'view', name: 'totalSupply', inputs: [], outputs: [{ type: 'uint256' }] },
] as const;

export interface LpPosition {
  pair:        Address;
  token0:      Address;
  token1:      Address;
  symbol0:     string;
  symbol1:     string;
  decimals0:   number;
  decimals1:   number;
  reserve0:    bigint;
  reserve1:    bigint;
  totalSupply: bigint;
  /** User's LP balance — guaranteed > 0 in the returned list. */
  userLp:      bigint;
}

export interface UseUserLpPositionsResult {
  positions: LpPosition[];
  loading:   boolean;
  error:     string | null;
  /** Force a re-read (e.g. after a removeLiquidity tx). */
  refresh:   () => void;
}

/**
 * @param publicClient viem public client bound to the chain we're scanning
 * @param user         the LP holder
 * @param pairAddresses candidate pair addresses (already filtered to one chain)
 * @param refetchKey   bump to force a re-read
 */
export function useUserLpPositions(
  publicClient:   PublicClient | undefined,
  user:           Address | undefined,
  pairAddresses:  Address[],
  refetchKey:     number = 0,
): UseUserLpPositionsResult {
  const [positions, setPositions] = useState<LpPosition[]>([]);
  const [loading,   setLoading]   = useState(false);
  const [error,     setError]     = useState<string | null>(null);
  const [tick,      setTick]      = useState(0);

  useEffect(() => {
    if (!publicClient || !user || pairAddresses.length === 0) {
      setPositions([]); setLoading(false); setError(null);
      return;
    }

    let cancelled = false;
    setLoading(true);
    setError(null);

    (async () => {
      try {
        const found: LpPosition[] = [];

        await Promise.all(pairAddresses.map(async (pair) => {
          try {
            const [token0, token1, reserves, totalSupply, userLp] = await Promise.all([
              publicClient.readContract({ address: pair, abi: PAIR_ABI,   functionName: 'token0' })      as Promise<Address>,
              publicClient.readContract({ address: pair, abi: PAIR_ABI,   functionName: 'token1' })      as Promise<Address>,
              publicClient.readContract({ address: pair, abi: PAIR_ABI,   functionName: 'getReserves' }) as Promise<readonly [bigint, bigint, number]>,
              publicClient.readContract({ address: pair, abi: PAIR_ABI,   functionName: 'totalSupply' }) as Promise<bigint>,
              publicClient.readContract({ address: pair, abi: erc20Abi,   functionName: 'balanceOf', args: [user] }) as Promise<bigint>,
            ]);

            if (userLp === 0n) return; // no position — skip

            const [symbol0, symbol1, decimals0, decimals1] = await Promise.all([
              (publicClient.readContract({ address: token0, abi: erc20Abi, functionName: 'symbol' })   as Promise<string>).catch(() => '?'),
              (publicClient.readContract({ address: token1, abi: erc20Abi, functionName: 'symbol' })   as Promise<string>).catch(() => '?'),
              (publicClient.readContract({ address: token0, abi: erc20Abi, functionName: 'decimals' }) as Promise<number>).catch(() => 18),
              (publicClient.readContract({ address: token1, abi: erc20Abi, functionName: 'decimals' }) as Promise<number>).catch(() => 18),
            ]);

            found.push({
              pair, token0, token1,
              symbol0, symbol1,
              decimals0: Number(decimals0),
              decimals1: Number(decimals1),
              reserve0: reserves[0],
              reserve1: reserves[1],
              totalSupply,
              userLp,
            });
          } catch {
            // pair read failed (not a V2 pair, or RPC error) — skip silently
          }
        }));

        if (!cancelled) {
          // Surface the largest positions first.
          found.sort((a, b) => (b.userLp > a.userLp ? 1 : b.userLp < a.userLp ? -1 : 0));
          setPositions(found);
          setLoading(false);
        }
      } catch (e: any) {
        if (!cancelled) { setError(e?.message ?? 'unknown'); setLoading(false); }
      }
    })();

    return () => { cancelled = true; };
  }, [publicClient, user, pairAddresses.join(','), refetchKey, tick]);

  return {
    positions,
    loading,
    error,
    refresh: () => setTick((t) => t + 1),
  };
}
