import type { ChainId, OpResult } from '../types';
import { OpType } from '../types';
import type { WalletAdapter } from '../adapters/WalletAdapter';
import { NotSupportedYetError } from '../adapters/WalletAdapter';
import { buildPlan } from '../routing/plan';
import { quoteFee, type FeeInputs } from '../fees';
import { requireChain } from '../chains';
import { execEvm, encodeCrossChainLPParams } from '../adapters/evm/executor';
import { execEvmCrossChain, execEvmCrossChainValue, execEvmFanOut, execEvmFanOutValue } from '../adapters/evm/crossChainExecutor';
import { opKind } from '../fees';

/**
 * High-level SDK entrypoint. Every op accepts a `dstChain` explicitly; the
 * source chain is taken from the connected wallet. This deliberately avoids
 * any implicit chain preference — Near users and Base users hit the same fn.
 */
export interface OpBaseArgs {
  wallet: WalletAdapter;
  dstChain: ChainId;
  /** USDC-denominated value of the op (for fee + routing). Optional for command-only ops. */
  valueUsdc6d?: bigint;
  /** Unix-second deadline for the whole flow (including bridge). */
  deadline: number;
}

export interface CreateLpArgs extends OpBaseArgs {
  token: string;
  tokenAmount: bigint;
  nativeAmount: bigint;
  amountTokenMin: bigint;
  amountNativeMin: bigint;
}

export interface SwapArgs extends OpBaseArgs {
  tokenIn: string;
  tokenOut: string;
  amountIn: bigint;
  amountOutMin: bigint;
  /** For cross-chain swaps (SWAP_OUT) the USDC intermediary is implicit. */
  crossChain: boolean;
}

export interface TokenCommandArgs extends OpBaseArgs {
  token: string;
  /** MINT only. */
  to?: string;
  amount?: bigint;
  /** UPDATE_METADATA only. */
  newURI?: string;
  /** FREEZE/UNFREEZE only. */
  account?: string;
  /** REVOKE_PERMISSION only: 0=UPDATE, 1=FREEZE, 2=MINT. */
  revokeKind?: 0 | 1 | 2;
}

export interface ClaimTaxArgs extends OpBaseArgs {
  token: string;
  /** USDC slippage floor. */
  amountOutMin: bigint;
  /** true = CCTP-burn to treasury; false = keep on local chain. */
  bridgeToTreasury: boolean;
}

/**
 * Run CREATE_LP on `dstChain`, from whatever chain the wallet is connected to.
 * Caller pre-approves the SDK for the required USDC fee; native gas is paid
 * by the wallet in the usual way.
 */
export async function createLp(args: CreateLpArgs): Promise<OpResult> {
  return dispatch(OpType.CREATE_LP, args);
}

export async function removeLp(args: CreateLpArgs): Promise<OpResult> {
  return dispatch(OpType.REMOVE_LP, args);
}

export type BurnLpArgs = Omit<CreateLpArgs, 'nativeAmount' | 'amountTokenMin' | 'amountNativeMin'>;

export async function burnLp(args: BurnLpArgs): Promise<OpResult> {
  const full: CreateLpArgs = { ...args, nativeAmount: 0n, amountTokenMin: 0n, amountNativeMin: 0n };
  return dispatch(OpType.BURN_LP, full);
}

export async function mint(args: TokenCommandArgs): Promise<OpResult> {
  return dispatch(OpType.MINT, args);
}

export async function setFrozen(args: TokenCommandArgs, frozen: boolean): Promise<OpResult> {
  return dispatch(frozen ? OpType.FREEZE_ACCOUNT : OpType.UNFREEZE_ACCOUNT, args);
}

export async function updateMetadata(args: TokenCommandArgs): Promise<OpResult> {
  return dispatch(OpType.UPDATE_METADATA, args);
}

export async function revokePermission(args: TokenCommandArgs): Promise<OpResult> {
  return dispatch(OpType.REVOKE_PERMISSION, args);
}

export async function swap(args: SwapArgs): Promise<OpResult> {
  return dispatch(args.crossChain ? OpType.SWAP_OUT : OpType.SWAP_LOCAL, args);
}

export async function claimTaxFees(args: ClaimTaxArgs): Promise<OpResult> {
  return dispatch(OpType.CLAIM_TAX_FEES, args);
}

// ─── Cross-chain LP from USDC (CCTP value op) ───────────────────────

export interface CreateLpFromUsdcArgs {
  wallet: WalletAdapter;
  dstChain: ChainId;
  token: string;
  usdcTotal: bigint;
  /** Basis points for token side, e.g. 5000 = 50%. */
  tokenShareBps: number;
  amountTokenMin: bigint;
  amountNativeMin: bigint;
  lpAmountTokenMin: bigint;
  lpAmountNativeMin: bigint;
  deadline: number;
}

export async function createLpFromUsdc(args: CreateLpFromUsdcArgs): Promise<OpResult> {
  const src = requireChain(args.wallet.chain);
  const dst = requireChain(args.dstChain);

  if (src.kind !== 'evm' || dst.kind !== 'evm') {
    throw new NotSupportedYetError(src.kind !== 'evm' ? src.id : dst.id, OpType.CREATE_LP);
  }
  if (!src.gatewayLive || !dst.gatewayLive) {
    throw new NotSupportedYetError(!src.gatewayLive ? src.id : dst.id, OpType.CREATE_LP);
  }
  if (src.cctpDomain === undefined || dst.cctpDomain === undefined) {
    throw new Error('CCTP not available on source or destination chain');
  }

  const moduleParams = encodeCrossChainLPParams({
    token: args.token,
    usdcTotal: args.usdcTotal,
    tokenShareBps: args.tokenShareBps,
    amountTokenMin: args.amountTokenMin,
    amountNativeMin: args.amountNativeMin,
    lpAmountTokenMin: args.lpAmountTokenMin,
    lpAmountNativeMin: args.lpAmountNativeMin,
    deadline: BigInt(args.deadline),
  });

  return execEvmCrossChainValue({
    wallet: args.wallet,
    srcChain: src.id,
    dstChain: dst.id,
    op: OpType.CREATE_LP,
    moduleParams,
    usdcAmount: args.usdcTotal,
    nativeValue: 0n,
  });
}

// ─── Fan-out LP from USDC across multiple chains ─────────────────────

export interface CreateLpFromUsdcFanOutArgs {
  wallet: WalletAdapter;
  dstChains: ChainId[];
  /** Per-chain LP config builder. */
  buildParams: (dstChain: ChainId) => {
    token: string;
    usdcAmount: bigint;
    tokenShareBps: number;
    amountTokenMin: bigint;
    amountNativeMin: bigint;
    lpAmountTokenMin: bigint;
    lpAmountNativeMin: bigint;
    deadline: number;
  };
  /** Total native value to cover LZ fees across all chains. */
  totalNativeValue: bigint;
}

export async function createLpFromUsdcFanOut(args: CreateLpFromUsdcFanOutArgs): Promise<OpResult> {
  const src = requireChain(args.wallet.chain);
  if (src.kind !== 'evm') throw new NotSupportedYetError(src.id, OpType.CREATE_LP);
  if (src.cctpDomain === undefined) throw new Error('CCTP not available on source chain');

  const moduleParamsPerChain: unknown[] = [];
  const usdcAmountsPerChain: bigint[] = [];

  for (const dstChain of args.dstChains) {
    const dst = requireChain(dstChain);
    if (dst.cctpDomain === undefined) throw new Error(`CCTP not available on ${dst.name}`);

    const p = args.buildParams(dstChain);
    moduleParamsPerChain.push({
      token: p.token,
      usdcTotal: p.usdcAmount,
      tokenShareBps: p.tokenShareBps,
      amountTokenMin: p.amountTokenMin,
      amountNativeMin: p.amountNativeMin,
      lpAmountTokenMin: p.lpAmountTokenMin,
      lpAmountNativeMin: p.lpAmountNativeMin,
      deadline: BigInt(p.deadline),
    });
    usdcAmountsPerChain.push(p.usdcAmount);
  }

  return execEvmFanOutValue({
    wallet: args.wallet,
    srcChain: src.id,
    dstChains: args.dstChains,
    op: OpType.CREATE_LP,
    moduleParamsPerChain,
    usdcAmountsPerChain,
    nativeValue: args.totalNativeValue,
  });
}

// ─── Fan-out: broadcast an op to multiple chains ───────────────────────

export interface FanOutArgs {
  wallet: WalletAdapter;
  dstChains: ChainId[];
  op: OpType;
  /** Per-chain module params builder. Receives the chain id, returns params for that chain. */
  buildParams: (dstChain: ChainId) => OpBaseArgs;
  /** Total native value to cover LZ fees across all chains. */
  totalNativeValue: bigint;
}

export async function fanOut(args: FanOutArgs): Promise<OpResult> {
  const src = requireChain(args.wallet.chain);

  if (src.kind !== 'evm') {
    throw new NotSupportedYetError(src.id, args.op);
  }

  const moduleParamsPerChain: unknown[] = [];
  for (const dstChain of args.dstChains) {
    const chainArgs = args.buildParams(dstChain);
    const { moduleParams } = buildEvmParams(args.op, chainArgs);
    moduleParamsPerChain.push(moduleParams);
  }

  return execEvmFanOut({
    wallet: args.wallet,
    srcChain: src.id,
    dstChains: args.dstChains,
    op: args.op,
    moduleParamsPerChain,
    nativeValue: args.totalNativeValue,
  });
}

/**
 * Internal dispatcher. For Phase 1 it handles the EVM path end-to-end; other
 * ecosystems throw `NotSupportedYetError` so callers can catch it and prompt
 * the user to reconnect a supported wallet or wait for rollout.
 */
async function dispatch(op: OpType, args: OpBaseArgs): Promise<OpResult> {
  const src = requireChain(args.wallet.chain);
  const dst = requireChain(args.dstChain);

  // Phase-1 gate: widgets catch this to render "Coming soon" on unsupported dests.
  if (!src.gatewayLive || !dst.gatewayLive) {
    throw new NotSupportedYetError(src.gatewayLive ? dst.id : src.id, op);
  }

  const plan = buildPlan({ op, srcChain: src.id, dstChain: dst.id, valueUsdc6d: args.valueUsdc6d });
  quoteFee(defaultFeeInputs(op, args.valueUsdc6d ?? 0n));

  const { moduleParams, nativeValue } = buildEvmParams(op, args);

  if (plan.sameChain && dst.kind === 'evm') {
    return execEvm({ wallet: args.wallet, dstChain: dst.id, op, moduleParams, nativeValue });
  }

  // Cross-chain EVM → EVM: command ops use LZ-only, value ops use CCTP+LZ.
  if (src.kind === 'evm' && dst.kind === 'evm' && dst.lzEid) {
    const kind = opKind(op);
    const hasCctp = src.cctpDomain !== undefined && dst.cctpDomain !== undefined;
    const isValueOp = kind === 'value' && args.valueUsdc6d && args.valueUsdc6d > 0n;

    if (isValueOp && hasCctp) {
      return execEvmCrossChainValue({
        wallet: args.wallet,
        srcChain: src.id,
        dstChain: dst.id,
        op,
        moduleParams,
        usdcAmount: args.valueUsdc6d!,
        nativeValue,
      });
    }

    return execEvmCrossChain({
      wallet: args.wallet,
      srcChain: src.id,
      dstChain: dst.id,
      op,
      moduleParams,
      nativeValue,
    });
  }

  // Non-EVM paths: staged for Phase 3 adapters.
  throw new NotSupportedYetError(dst.id, op);
}

/**
 * Turn the SDK's caller-facing op args into the tuple + native value the
 * on-chain module expects. Consolidated here so every op keeps its mapping
 * next to the user API.
 */
function buildEvmParams(op: OpType, args: OpBaseArgs): { moduleParams: unknown; nativeValue: bigint } {
  const a = args as unknown as Record<string, unknown>;
  switch (op) {
    case OpType.CREATE_LP:
    case OpType.REMOVE_LP: {
      const r = a as unknown as CreateLpArgs;
      const params = {
        token: r.token,
        tokenAmount: r.tokenAmount,
        ethAmount: r.nativeAmount,
        liquidity: r.tokenAmount,
        amountTokenMin: r.amountTokenMin,
        amountETHMin: r.amountNativeMin,
        usdcFee: args.valueUsdc6d ? (args.valueUsdc6d * 15n) / 10_000n : 0n,
        deadline: BigInt(args.deadline),
      };
      return { moduleParams: params, nativeValue: op === OpType.CREATE_LP ? r.nativeAmount : 0n };
    }
    case OpType.BURN_LP: {
      const r = a as unknown as CreateLpArgs;
      return { moduleParams: { token: r.token, liquidity: r.tokenAmount }, nativeValue: 0n };
    }
    case OpType.MINT: {
      const r = a as unknown as TokenCommandArgs;
      return {
        moduleParams: {
          token: r.token,
          to: r.to,
          amount: r.amount,
          usdcFee: args.valueUsdc6d ? (args.valueUsdc6d * 15n) / 10_000n : 0n,
          deadline: BigInt(args.deadline),
        },
        nativeValue: 0n,
      };
    }
    case OpType.UPDATE_METADATA: {
      const r = a as unknown as TokenCommandArgs;
      return { moduleParams: { token: r.token, newURI: r.newURI }, nativeValue: 0n };
    }
    case OpType.FREEZE_ACCOUNT:
    case OpType.UNFREEZE_ACCOUNT:
    case OpType.AUTO_FREEZE: {
      const r = a as unknown as TokenCommandArgs;
      return { moduleParams: { token: r.token, account: r.account }, nativeValue: 0n };
    }
    case OpType.REVOKE_PERMISSION: {
      const r = a as unknown as TokenCommandArgs;
      return { moduleParams: { token: r.token, kind: r.revokeKind ?? 0 }, nativeValue: 0n };
    }
    case OpType.SWAP_LOCAL:
    case OpType.SWAP_OUT: {
      const r = a as unknown as SwapArgs;
      const nativeIn = r.tokenIn === '0x0000000000000000000000000000000000000000';
      return {
        moduleParams: {
          tokenIn: r.tokenIn,
          tokenOut: r.tokenOut,
          amountIn: r.amountIn,
          amountOutMin: r.amountOutMin,
          path: [r.tokenIn, r.tokenOut],
          recipient: r.tokenOut,
          deadline: BigInt(args.deadline),
        },
        nativeValue: nativeIn ? r.amountIn : 0n,
      };
    }
    case OpType.CLAIM_TAX_FEES: {
      const r = a as unknown as ClaimTaxArgs;
      return {
        moduleParams: {
          token: r.token,
          amountOutMin: r.amountOutMin,
          deadline: BigInt(args.deadline),
          bridgeToTreasury: r.bridgeToTreasury,
        },
        nativeValue: 0n,
      };
    }
    case OpType.CREATE_LP_AND_BUY:
      throw new Error('CREATE_LP_AND_BUY arg mapper not yet wired — supply lp/buy tuple explicitly');

    case OpType.CREATE_TOKEN:
      throw new Error('CREATE_TOKEN uses its own dispatcher, not buildEvmParams');

    case OpType.POOL_FEE_COMPOUND: {
      const r = a as unknown as PoolFeeCompoundArgs;
      return {
        moduleParams: {
          pair:     r.pair,
          router:   r.router,
          lpAmount: r.lpAmount,
          deadline: BigInt(args.deadline),
        },
        nativeValue: 0n,
      };
    }

    case OpType.MIGRATE_LP: {
      const r = a as unknown as MigrateLpArgs;
      return {
        moduleParams: {
          srcPair:   r.srcPair,
          srcRouter: r.srcRouter,
          dstRouter: r.dstRouter,
          lpAmount:  r.lpAmount,
          deadline:  BigInt(args.deadline),
        },
        nativeValue: 0n,
      };
    }
  }
}

// ─── V1.1 atomic LP ops (handled by LPAtomicModule + helper) ────────────

export interface PoolFeeCompoundArgs extends OpBaseArgs {
  /** UniV2 pair address on `dstChain`. */
  pair:     string;
  /** UniV2 router for that pair. */
  router:   string;
  /** LP amount to compound (the helper pulls this via safeTransferFrom). */
  lpAmount: bigint;
  // `deadline` (unix seconds) inherited from OpBaseArgs.
}

export interface MigrateLpArgs extends OpBaseArgs {
  srcPair:   string;
  srcRouter: string;
  dstRouter: string;
  lpAmount:  bigint;
  // `deadline` (unix seconds) inherited from OpBaseArgs.
}

/** Single-chain or cross-chain compound: 1 user signature, executed atomically
 *  on `dstChain` by LPAtomicModule via MagnetaLpAtomicHelper. */
export async function poolFeeCompound(args: PoolFeeCompoundArgs): Promise<OpResult> {
  return dispatch(OpType.POOL_FEE_COMPOUND, args);
}

/** Single-chain or cross-chain migrate (LP → other router on same chain).
 *  Cross-DEX same-chain only; cross-chain migration would require bridging
 *  the underlying tokens (out of scope for V1.1). */
export async function migrateLp(args: MigrateLpArgs): Promise<OpResult> {
  return dispatch(OpType.MIGRATE_LP, args);
}

export function quoteOp(inputs: FeeInputs) {
  return quoteFee(inputs);
}

function defaultFeeInputs(op: OpType, valueUsdc6d: bigint): FeeInputs {
  return {
    op,
    valueUsdc6d,
    routingFeeUsdc6d: 0n,
    gasCostNative: 0n,
  };
}
