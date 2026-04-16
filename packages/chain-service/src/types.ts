/**
 * Shared types for the Magneta chain-service SDK.
 * Every op the SDK exposes is equally available from any supported chain; no
 * ecosystem plays the role of a hub. See `chains.ts` for the registry.
 */

export type ChainKind =
  | 'evm'
  | 'solana'
  | 'cosmos'
  | 'near'
  | 'aptos'
  | 'sui'
  | 'starknet'
  | 'tron';

/** Unique SDK-local identifier for every supported chain.
 *  EVM chains use their numeric chainId; non-EVM get their canonical namespace
 *  (Solana mainnet `sol:mainnet`, Near `near:mainnet`, etc.).
 */
export type ChainId = number | string;

export interface ChainInfo {
  id: ChainId;
  kind: ChainKind;
  name: string;
  shortName: string;
  /** Native gas token symbol (ETH, SOL, NEAR…). */
  nativeSymbol: string;
  /** true when MagnetaGateway (or its non-EVM equivalent) is deployed and registered. */
  gatewayLive: boolean;
  /** Address (EVM) or program/account id (non-EVM) of the gateway when live. */
  gatewayAddress?: string;
  /** LayerZero endpoint id if applicable — used for cross-chain command dispatch. */
  lzEid?: number;
  /** Circle CCTP domain id if USDC burn/mint is available (enables native routing of value). */
  cctpDomain?: number;
  /** Canonical local DEX router (V2-compatible) for same-chain LP/swap ops. */
  defaultRouter?: string;
  /** Canonical USDC token on this chain. */
  usdc?: string;
  /** Explorer base URL (for building receipt links). */
  explorer: string;
}

/**
 * OpType mirrors the Solidity IMagnetaGateway.OpType enum, extended to include
 * non-EVM-native ops that may not round-trip to the on-chain gateway.
 * The numeric values MUST stay aligned with the Solidity enum's ordinal.
 */
export enum OpType {
  // LP
  CREATE_LP = 0,
  REMOVE_LP = 1,
  BURN_LP = 2,
  CREATE_LP_AND_BUY = 3,
  // Token ops
  MINT = 4,
  UPDATE_METADATA = 5,
  FREEZE_ACCOUNT = 6,
  UNFREEZE_ACCOUNT = 7,
  AUTO_FREEZE = 8,
  REVOKE_PERMISSION = 9,
  // Tax / fees
  CLAIM_TAX_FEES = 10,
  // Swap
  SWAP_LOCAL = 11,
  SWAP_OUT = 12,
}

/** Per-op classification used by the fee calculator (value-based vs flat). */
export type OpKind = 'value' | 'command';

export interface FeeQuote {
  /** Magneta markup in USDC (6 decimals bigint). */
  magnetaFeeUsdc: bigint;
  /** Estimated gas on destination chain, in native (wei-equivalent bigint). */
  gasCostNative: bigint;
  /** Bridge / cross-chain routing fees (Circle, LI.FI, LayerZero) in USDC. */
  routingFeeUsdc: bigint;
  /** Total the user is expected to pre-approve (USDC, gas is paid separately). */
  userTotalUsdc: bigint;
}

export interface OpResult {
  /** Source chain where the user signed. */
  srcChain: ChainId;
  /** Destination chain where the op lands. */
  dstChain: ChainId;
  op: OpType;
  /** Source-chain transaction hash (identifier — format varies by ecosystem). */
  srcTxHash: string;
  /** Destination-chain transaction hash once observed (undefined until relayed). */
  dstTxHash?: string;
  /** Op-specific return payload (ABI-decoded on EVM, JSON elsewhere). */
  payload?: unknown;
}
