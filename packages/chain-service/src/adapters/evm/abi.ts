/**
 * Minimal ABI fragments for the MagnetaGateway and its modules. Only the
 * functions the SDK calls directly are listed — anything else goes through
 * the gateway's generic `executeOperation(op, params)` dispatcher.
 */

export const MagnetaGatewayAbi = [
  {
    type: 'function',
    name: 'executeOperation',
    stateMutability: 'payable',
    inputs: [
      { name: 'op', type: 'uint8' },
      { name: 'params', type: 'bytes' },
    ],
    outputs: [{ name: 'result', type: 'bytes' }],
  },
  {
    type: 'function',
    name: 'moduleFor',
    stateMutability: 'view',
    inputs: [{ name: 'op', type: 'uint8' }],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'function',
    name: 'feeVault',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
  },
] as const;

/** Struct tuple types for LPModule params, matching the Solidity layout. */
export const LpCreateParamsType = {
  type: 'tuple',
  components: [
    { name: 'token', type: 'address' },
    { name: 'tokenAmount', type: 'uint256' },
    { name: 'ethAmount', type: 'uint256' },
    { name: 'amountTokenMin', type: 'uint256' },
    { name: 'amountETHMin', type: 'uint256' },
    { name: 'usdcFee', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

export const LpRemoveParamsType = {
  type: 'tuple',
  components: [
    { name: 'token', type: 'address' },
    { name: 'liquidity', type: 'uint256' },
    { name: 'amountTokenMin', type: 'uint256' },
    { name: 'amountETHMin', type: 'uint256' },
    { name: 'usdcFee', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

export const LpBurnParamsType = {
  type: 'tuple',
  components: [
    { name: 'token', type: 'address' },
    { name: 'liquidity', type: 'uint256' },
  ],
} as const;

export const MintParamsType = {
  type: 'tuple',
  components: [
    { name: 'token', type: 'address' },
    { name: 'to', type: 'address' },
    { name: 'amount', type: 'uint256' },
    { name: 'usdcFee', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

export const UpdateMetadataParamsType = {
  type: 'tuple',
  components: [
    { name: 'token', type: 'address' },
    { name: 'newURI', type: 'string' },
  ],
} as const;

export const BlacklistParamsType = {
  type: 'tuple',
  components: [
    { name: 'token', type: 'address' },
    { name: 'account', type: 'address' },
  ],
} as const;

export const RevokeParamsType = {
  type: 'tuple',
  components: [
    { name: 'token', type: 'address' },
    { name: 'kind', type: 'uint8' },
  ],
} as const;

export const SwapLocalParamsType = {
  type: 'tuple',
  components: [
    { name: 'tokenIn', type: 'address' },
    { name: 'tokenOut', type: 'address' },
    { name: 'amountIn', type: 'uint256' },
    { name: 'amountOutMin', type: 'uint256' },
    { name: 'path', type: 'address[]' },
    { name: 'recipient', type: 'address' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

export const SwapOutParamsType = {
  type: 'tuple',
  components: [
    { name: 'tokenIn', type: 'address' },
    { name: 'amountIn', type: 'uint256' },
    { name: 'amountOutMin', type: 'uint256' },
    { name: 'path', type: 'address[]' },
    { name: 'dstDomain', type: 'uint32' },
    { name: 'recipient', type: 'bytes32' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

export const ClaimTaxParamsType = {
  type: 'tuple',
  components: [
    { name: 'token', type: 'address' },
    { name: 'amountOutMin', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
    { name: 'bridgeToTreasury', type: 'bool' },
  ],
} as const;
