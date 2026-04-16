import type { FeeQuote, OpType as OpTypeT } from './types';
import { OpType } from './types';

const BPS = 15n;              // 0.15% Magneta markup on value ops
const BPS_DENOM = 10_000n;
const FLAT_FEE_USDC_6D = 1_000_000n; // $1.00 command-only ops (TokenOpsModule.flatFeeUsdc default)

/** Classify each op as value-based (percentage markup) or command-only (flat). */
export function opKind(op: OpTypeT): 'value' | 'command' {
  switch (op) {
    case OpType.CREATE_LP:
    case OpType.REMOVE_LP:
    case OpType.CREATE_LP_AND_BUY:
    case OpType.CLAIM_TAX_FEES:
    case OpType.SWAP_LOCAL:
    case OpType.SWAP_OUT:
    case OpType.MINT:
      return 'value';
    case OpType.BURN_LP:
    case OpType.UPDATE_METADATA:
    case OpType.FREEZE_ACCOUNT:
    case OpType.UNFREEZE_ACCOUNT:
    case OpType.AUTO_FREEZE:
    case OpType.REVOKE_PERMISSION:
      return 'command';
  }
}

export interface FeeInputs {
  op: OpTypeT;
  /** USDC equivalent of the value moving on-chain (6 decimals). For CREATE_LP this is the LP value; for swaps, amountIn. */
  valueUsdc6d: bigint;
  /** Routing component — estimated fees reported by LI.FI / CCTP / LZ aggregators. */
  routingFeeUsdc6d: bigint;
  /** Native gas estimate on destination chain (wei-equivalent). */
  gasCostNative: bigint;
}

export function quoteFee(inputs: FeeInputs): FeeQuote {
  const kind = opKind(inputs.op);
  const magnetaFeeUsdc =
    kind === 'value'
      ? (inputs.valueUsdc6d * BPS) / BPS_DENOM
      : FLAT_FEE_USDC_6D;

  return {
    magnetaFeeUsdc,
    gasCostNative: inputs.gasCostNative,
    routingFeeUsdc: inputs.routingFeeUsdc6d,
    // User approves in USDC: Magneta fee + routing. Gas paid separately in native.
    userTotalUsdc: magnetaFeeUsdc + inputs.routingFeeUsdc6d,
  };
}
