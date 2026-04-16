import type { ChainId, OpType as OpTypeT } from '../types';
import { OpType } from '../types';
import { requireChain } from '../chains';

/**
 * A RoutePlan lists the concrete steps required to fulfil an op when the
 * source wallet is on a different chain than the destination. Every step has
 * a well-defined primitive so Phase 2/3 adapters can plug in without the
 * caller changing.
 */
export interface RoutePlan {
  op: OpTypeT;
  srcChain: ChainId;
  dstChain: ChainId;
  steps: RouteStep[];
  /** True when no cross-chain hop is needed (pure same-chain gateway call). */
  sameChain: boolean;
}

export type RouteStep =
  | { kind: 'cctp'; amountUsdc: bigint; srcDomain: number; dstDomain: number; mintRecipient: string }
  | { kind: 'lifi'; fromToken: string; toToken: string; fromAmount: bigint; minOutAmount: bigint }
  | { kind: 'lz-command'; dstEid: number; payload: string /* hex */; nativeFee: bigint }
  | { kind: 'local-call'; gateway: string; calldata: string; value: bigint }
  | { kind: 'non-evm-native'; program: string; instruction: string; args: unknown };

export interface PlanInputs {
  op: OpTypeT;
  srcChain: ChainId;
  dstChain: ChainId;
  /** USDC-denominated value being bridged (for routing step sizing). */
  valueUsdc6d?: bigint;
  /** Override routing provider preference — default chooses CCTP > LI.FI > LZ. */
  preferredProvider?: 'cctp' | 'lifi' | 'lz';
}

/**
 * Build a RoutePlan for the given op.
 *
 * This is a skeleton: the real implementation queries LI.FI for quotes and
 * checks CCTP domain availability. Exposed as-is so application code can be
 * written against the stable contract while provider integrations arrive.
 */
export function buildPlan(inputs: PlanInputs): RoutePlan {
  const src = requireChain(inputs.srcChain);
  const dst = requireChain(inputs.dstChain);

  const sameChain = src.id === dst.id;
  if (sameChain) {
    return {
      op: inputs.op,
      srcChain: src.id,
      dstChain: dst.id,
      sameChain: true,
      steps: [
        {
          kind: 'local-call',
          gateway: dst.gatewayAddress ?? '',
          calldata: '',
          value: 0n,
        },
      ],
    };
  }

  const steps: RouteStep[] = [];

  // 1. Cross-chain value transport (skip if op carries no USDC value).
  const needsValueHop =
    inputs.valueUsdc6d !== undefined && inputs.valueUsdc6d > 0n &&
    [OpType.CREATE_LP, OpType.CREATE_LP_AND_BUY, OpType.SWAP_LOCAL, OpType.SWAP_OUT].includes(inputs.op);

  if (needsValueHop) {
    if (src.cctpDomain !== undefined && dst.cctpDomain !== undefined &&
        inputs.preferredProvider !== 'lifi' && inputs.preferredProvider !== 'lz') {
      steps.push({
        kind: 'cctp',
        amountUsdc: inputs.valueUsdc6d!,
        srcDomain: src.cctpDomain,
        dstDomain: dst.cctpDomain,
        mintRecipient: dst.gatewayAddress ?? '',
      });
    } else {
      steps.push({
        kind: 'lifi',
        fromToken: src.usdc ?? '',
        toToken: dst.usdc ?? '',
        fromAmount: inputs.valueUsdc6d!,
        minOutAmount: (inputs.valueUsdc6d! * 995n) / 1000n, // 0.5% slippage default
      });
    }
  }

  // 2. Command dispatch.
  if (src.kind === 'evm' && dst.kind === 'evm' && src.lzEid && dst.lzEid) {
    steps.push({
      kind: 'lz-command',
      dstEid: dst.lzEid,
      payload: '',
      nativeFee: 0n, // quoted at prepare-time
    });
  } else {
    // Non-EVM source or destination: the SDK signs an intent and the relayer
    // (or the user, re-connecting to the dst chain's wallet) executes locally.
    steps.push({
      kind: dst.kind === 'evm' ? 'local-call' : 'non-evm-native',
      ...(dst.kind === 'evm'
        ? { gateway: dst.gatewayAddress ?? '', calldata: '', value: 0n }
        : { program: dst.gatewayAddress ?? '', instruction: '', args: {} }),
    } as RouteStep);
  }

  return {
    op: inputs.op,
    srcChain: src.id,
    dstChain: dst.id,
    sameChain: false,
    steps,
  };
}
