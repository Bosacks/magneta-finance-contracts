import { encodeAbiParameters, type Hex } from 'viem';
import { OpType, type ChainId } from '../../types';
import { requireChain } from '../../chains';

/**
 * Encode an EVM→EVM cross-chain command payload. The MagnetaGateway's
 * `_lzReceive` decodes `abi.encode(OpType, address, bytes)` — so we produce
 * exactly that, delegating the inner module-param blob to the regular executor
 * encoder. The caller is then passed to an OApp `send()` call (not done here
 * — the OApp send wrapper lives with the LZ integration milestone).
 */
export interface LzCommandInputs {
  op: OpType;
  dstChain: ChainId;
  callerOnDst: string; // usually the same EOA as source, since EVM addresses match
  innerParams: Hex;    // already-encoded module payload (with OpType prefix if relevant)
}

export interface LzCommand {
  dstEid: number;
  /** abi.encode(OpType, address, bytes) */
  payload: Hex;
}

export function encodeLzCommand(inputs: LzCommandInputs): LzCommand {
  const dst = requireChain(inputs.dstChain);
  if (!dst.lzEid) throw new Error(`Chain ${dst.name} has no LayerZero endpoint id`);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const enc = encodeAbiParameters as unknown as (types: any, values: any) => Hex;
  const payload = enc(
    [
      { type: 'uint8' },
      { type: 'address' },
      { type: 'bytes' },
    ],
    [inputs.op, inputs.callerOnDst, inputs.innerParams]
  );

  return { dstEid: dst.lzEid, payload };
}
