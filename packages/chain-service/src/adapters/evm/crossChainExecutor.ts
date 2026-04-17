import { encodeFunctionData, concat, toHex, type Hex } from 'viem';
import { OpType, type ChainId, type OpResult } from '../../types';
import { requireChain } from '../../chains';
import type { WalletAdapter, PreparedTx } from '../WalletAdapter';
import { MagnetaGatewayAbi } from './abi';
import { encodeModuleParams } from './executor';

/**
 * Default LayerZero executor options: 200k gas on destination chain.
 * Encodes as LZ v2 OptionsType.3 (lzReceive gas).
 */
const DEFAULT_LZ_OPTIONS: Hex = buildLzOptions(200_000n);

export interface CrossChainExecParams {
  wallet: WalletAdapter;
  srcChain: ChainId;
  dstChain: ChainId;
  op: OpType;
  moduleParams: unknown;
  nativeValue: bigint;
  /** Override default LZ gas options. */
  lzOptions?: Hex;
}

export interface FanOutExecParams {
  wallet: WalletAdapter;
  srcChain: ChainId;
  dstChains: ChainId[];
  op: OpType;
  moduleParamsPerChain: unknown[];
  nativeValue: bigint;
  lzOptions?: Hex;
}

/**
 * Send a cross-chain op via the source chain's MagnetaGateway.sendCrossChainOp().
 * The Gateway collects USDC fee on source, sends LZ message, target Gateway executes.
 */
export async function execEvmCrossChain(args: CrossChainExecParams): Promise<OpResult> {
  const src = requireChain(args.srcChain);
  const dst = requireChain(args.dstChain);
  if (src.kind !== 'evm') throw new Error(`Cross-chain source must be EVM, got ${src.kind}`);
  if (dst.kind !== 'evm') throw new Error(`Cross-chain EVM dest required, got ${dst.kind}`);
  if (!src.gatewayAddress) throw new Error(`No gateway on ${src.name}`);
  if (!dst.lzEid) throw new Error(`No LZ endpoint for ${dst.name}`);

  const innerParams = encodeModuleParams(args.op, args.moduleParams);
  const lzOptions = args.lzOptions ?? DEFAULT_LZ_OPTIONS;

  const calldata = encodeFunctionData({
    abi: MagnetaGatewayAbi,
    functionName: 'sendCrossChainOp',
    args: [dst.lzEid, args.op as number, innerParams, lzOptions],
  });

  const tx: PreparedTx = {
    to: src.gatewayAddress,
    data: calldata,
    value: args.nativeValue,
  };
  const txHash = await args.wallet.sendRaw(tx);

  return {
    srcChain: src.id,
    dstChain: dst.id,
    op: args.op,
    srcTxHash: txHash,
  };
}

/**
 * Fan-out: broadcast an op to multiple destination chains in one tx.
 * Uses MagnetaGateway.sendFanOut() which sends N LZ messages.
 */
export async function execEvmFanOut(args: FanOutExecParams): Promise<OpResult> {
  const src = requireChain(args.srcChain);
  if (src.kind !== 'evm') throw new Error(`Fan-out source must be EVM`);
  if (!src.gatewayAddress) throw new Error(`No gateway on ${src.name}`);

  const dstEids: number[] = [];
  const encodedParams: Hex[] = [];

  for (let i = 0; i < args.dstChains.length; i++) {
    const dst = requireChain(args.dstChains[i]);
    if (!dst.lzEid) throw new Error(`No LZ endpoint for ${dst.name}`);
    dstEids.push(dst.lzEid);
    encodedParams.push(encodeModuleParams(args.op, args.moduleParamsPerChain[i]));
  }

  const lzOptions = args.lzOptions ?? DEFAULT_LZ_OPTIONS;

  const calldata = encodeFunctionData({
    abi: MagnetaGatewayAbi,
    functionName: 'sendFanOut',
    args: [dstEids, args.op as number, encodedParams, lzOptions],
  });

  const tx: PreparedTx = {
    to: src.gatewayAddress,
    data: calldata,
    value: args.nativeValue,
  };
  const txHash = await args.wallet.sendRaw(tx);

  return {
    srcChain: src.id,
    dstChain: args.dstChains[0],
    op: args.op,
    srcTxHash: txHash,
  };
}

/**
 * Build LZ v2 executor options with specified gas limit for _lzReceive.
 * Format: OptionsType 3 = [0x0003] [0x01] [gas: uint128]
 */
function buildLzOptions(gasLimit: bigint): Hex {
  return concat([
    toHex(3, { size: 2 }),     // options type 3 (lzReceive)
    toHex(1, { size: 1 }),     // worker id 1 (executor)
    toHex(16 + 1, { size: 2 }), // option length (uint128 gas = 16 bytes + 1 byte worker)
    toHex(gasLimit, { size: 16 }),
  ]);
}
