import { encodeAbiParameters, encodeFunctionData, concat, toHex, type Hex } from 'viem';
import { OpType, type ChainId, type OpResult } from '../../types';
import { requireChain } from '../../chains';
import type { WalletAdapter, PreparedTx } from '../WalletAdapter';
import {
  MagnetaGatewayAbi,
  LpCreateParamsType,
  LpRemoveParamsType,
  LpBurnParamsType,
  MintParamsType,
  UpdateMetadataParamsType,
  BlacklistParamsType,
  RevokeParamsType,
  SwapLocalParamsType,
  SwapOutParamsType,
  ClaimTaxParamsType,
} from './abi';

/**
 * Encode and send an op to the MagnetaGateway on the destination EVM chain.
 * This handles SAME-CHAIN execution only — cross-chain LZ dispatch goes
 * through `encodeLzCommand()` + an OApp send wrapper (next milestone).
 */
export interface EvmExecParams {
  wallet: WalletAdapter;
  dstChain: ChainId;
  op: OpType;
  /** Raw params expected by the chosen module (see OpType → module mapping). */
  moduleParams: unknown;
  /** Native value sent with the call (ETH for LP create, 0 otherwise). */
  nativeValue: bigint;
}

export async function execEvm(args: EvmExecParams): Promise<OpResult> {
  const dst = requireChain(args.dstChain);
  if (dst.kind !== 'evm') throw new Error(`execEvm called with non-EVM dst ${String(dst.id)}`);
  if (!dst.gatewayAddress) throw new Error(`No gateway address for ${dst.name}`);

  const innerParams = encodeModuleParams(args.op, args.moduleParams);
  const calldata = encodeFunctionData({
    abi: MagnetaGatewayAbi,
    functionName: 'executeOperation',
    args: [opToUint8(args.op), innerParams],
  });

  const tx: PreparedTx = {
    to: dst.gatewayAddress,
    data: calldata,
    value: args.nativeValue,
  };
  const txHash = await args.wallet.sendRaw(tx);

  return {
    srcChain: args.wallet.chain,
    dstChain: dst.id,
    op: args.op,
    srcTxHash: txHash,
  };
}

function opToUint8(op: OpType): number {
  return op as number;
}

/**
 * Turn an op + user args into the `bytes` blob the module expects. Modules
 * that serve multiple ops (LPModule, TokenOpsModule, SwapModule) prefix the
 * inner payload with a 1-byte OpType discriminator; single-op modules
 * (TaxClaimModule) accept the tuple directly.
 */
// Relax viem's strict tuple shape inference — the SDK's public API validates
// params at the caller boundary; here we only care that the ABI layout matches.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const enc = encodeAbiParameters as unknown as (types: any, values: any) => Hex;

function encodeModuleParams(op: OpType, params: unknown): Hex {
  switch (op) {
    case OpType.CREATE_LP:
      return prefixWithOp(op, enc([LpCreateParamsType], [params]));
    case OpType.REMOVE_LP:
      return prefixWithOp(op, enc([LpRemoveParamsType], [params]));
    case OpType.BURN_LP:
      return prefixWithOp(op, enc([LpBurnParamsType], [params]));
    case OpType.CREATE_LP_AND_BUY:
      return prefixWithOp(
        op,
        enc(
          [
            {
              type: 'tuple',
              components: [
                { name: 'lp', ...LpCreateParamsType },
                { name: 'buyEth', type: 'uint256' },
                { name: 'buyAmountOutMin', type: 'uint256' },
                { name: 'buyRecipient', type: 'address' },
              ],
            },
          ],
          [params]
        )
      );
    case OpType.MINT:
      return prefixWithOp(op, enc([MintParamsType], [params]));
    case OpType.UPDATE_METADATA:
      return prefixWithOp(op, enc([UpdateMetadataParamsType], [params]));
    case OpType.FREEZE_ACCOUNT:
    case OpType.UNFREEZE_ACCOUNT:
    case OpType.AUTO_FREEZE:
      return prefixWithOp(op, enc([BlacklistParamsType], [params]));
    case OpType.REVOKE_PERMISSION:
      return prefixWithOp(op, enc([RevokeParamsType], [params]));
    case OpType.SWAP_LOCAL:
      return prefixWithOp(op, enc([SwapLocalParamsType], [params]));
    case OpType.SWAP_OUT:
      return prefixWithOp(op, enc([SwapOutParamsType], [params]));
    case OpType.CLAIM_TAX_FEES:
      return enc([ClaimTaxParamsType], [params]);
  }
}

function prefixWithOp(op: OpType, encoded: Hex): Hex {
  return concat([toHex(op, { size: 1 }), encoded]);
}
