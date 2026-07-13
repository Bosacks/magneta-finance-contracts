/**
 * Safe v1.4.1 in-house deployment + signing helpers.
 *
 * Use case: deploy/operate a Safe on a chain where app.safe.global UI doesn't
 * support the chain (Cronos, Dexalot, Rootstock, etc.). The Safe contracts
 * themselves are canonical — only the UI is missing.
 *
 * Workflow:
 *   1. Compute predicted Safe address with createMagnetaSafe.ts
 *   2. If matches our target 0xC4c9...717a, deploy via SafeProxyFactory
 *   3. Use execBatch.ts to run any Safe Tx Builder JSON file directly via execTransaction
 */
import { ethers, type AbiCoder, type BytesLike } from "ethers";

// ─── Magneta Safe identity ───────────────────────────────────────────
// Note: the canonical address 0xC4c96aF54cdE078dc993d6948199b0AF8cD6717a (used by Safe Wallet
// UI on the 14 supported chains) cannot be reproduced on UI-unsupported chains because Safe
// Wallet uses a timestamp-based saltNonce that we cannot recover without their backend.
// In-house deploys produce a per-chain address with the same owners + threshold — equivalent
// security, just a different address. Recorded in deployments/<chain>.json under `gnosisSafe`.
export const MAGNETA_SAFE_UI_ADDRESS = "0xC4c96aF54cdE078dc993d6948199b0AF8cD6717a";
export const SAFE_OWNERS = [
  "0x620684F822da9adF36F41e3554791D889947e25E", // Deployer
  "0x92F440Bc1f1FaBD6D3e6256491631E07857F4260", // PauseGuardian — rotated 2026-05-09 (previous 0x479ED5228… leaked in chat)
];
export const SAFE_THRESHOLD = 2n;
// Default saltNonce for in-house deploys. Change only if you need to deploy a second Safe
// on the same chain (e.g., to recover from a buggy first deploy).
export const DEFAULT_SALT_NONCE = 0n;

// ─── Canonical Safe v1.4.1 contract addresses (same on every supported chain) ──
export const SAFE_PROXY_FACTORY = "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67";
export const SAFE_L2_SINGLETON = "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762";
export const COMPATIBILITY_FALLBACK_HANDLER = "0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99";
export const MULTISEND_CALLONLY = "0x9641d764fc13c8B624c04430C7356C1C7C8102e2";
export const SAFE_SINGLETON_FACTORY = "0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7";

// SafeProxy v1.4.1 creation code — fetched from SafeProxyFactory.proxyCreationCode() on Base.
// First half is constructor + runtime, then constructor arg (singleton address) is appended.
export const PROXY_CREATION_CODE =
  "0x608060405234801561001057600080fd5b506040516101e63803806101e68339818101604052602081101561003357600080fd5b8101908080519060200190929190505050600073ffffffffffffffffffffffffffffffffffffffff168173ffffffffffffffffffffffffffffffffffffffff1614156100ca576040517f08c379a00000000000000000000000000000000000000000000000000000000081526004018080602001828103825260228152602001806101c46022913960400191505060405180910390fd5b806000806101000a81548173ffffffffffffffffffffffffffffffffffffffff021916908373ffffffffffffffffffffffffffffffffffffffff1602179055505060ab806101196000396000f3fe608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea264697066735822122003d1488ee65e08fa41e58e888a9865554c535f2c77126a82cb4c0f917f31441364736f6c63430007060033496e76616c69642073696e676c65746f6e20616464726573732070726f7669646564";

// ─── Safe `setup()` initializer encoding ─────────────────────────────
// function setup(
//   address[] calldata _owners,
//   uint256 _threshold,
//   address to,
//   bytes calldata data,
//   address fallbackHandler,
//   address paymentToken,
//   uint256 payment,
//   address payable paymentReceiver
// )
const SETUP_SELECTOR = "0xb63e800d";

export function encodeSetupInitializer(): string {
  const abi = ethers.AbiCoder.defaultAbiCoder();
  const encoded = abi.encode(
    ["address[]", "uint256", "address", "bytes", "address", "address", "uint256", "address"],
    [
      SAFE_OWNERS,
      SAFE_THRESHOLD,
      ethers.ZeroAddress, // to
      "0x", // data
      COMPATIBILITY_FALLBACK_HANDLER,
      ethers.ZeroAddress, // paymentToken
      0n, // payment
      ethers.ZeroAddress, // paymentReceiver
    ],
  );
  return SETUP_SELECTOR + encoded.slice(2);
}

/**
 * Compute the CREATE2 address that SafeProxyFactory.createProxyWithNonce(...)
 * would deploy a SafeProxy at, given an initializer + saltNonce.
 *
 * Salt formula (per Safe contracts):
 *   salt = keccak256(keccak256(initializer) || saltNonce)
 *
 * InitCode:
 *   PROXY_CREATION_CODE || abi.encode(singleton)
 */
export function computeSafeAddress(initializer: string, saltNonce: bigint): string {
  const initializerHash = ethers.keccak256(initializer);
  const salt = ethers.keccak256(
    ethers.solidityPacked(["bytes32", "uint256"], [initializerHash, saltNonce]),
  );

  const initCode = ethers.concat([
    PROXY_CREATION_CODE,
    ethers.AbiCoder.defaultAbiCoder().encode(["address"], [SAFE_L2_SINGLETON]),
  ]);
  const initCodeHash = ethers.keccak256(initCode);

  return ethers.getCreate2Address(SAFE_PROXY_FACTORY, salt, initCodeHash);
}


// ─── EIP-712 safeTxHash for execTransaction signing ──────────────────
const SAFE_TX_TYPEHASH = "0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8";
const DOMAIN_SEPARATOR_TYPEHASH = "0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218";

export interface SafeTx {
  to: string;
  value: bigint;
  data: string;
  operation: number; // 0 = Call, 1 = DelegateCall
  safeTxGas: bigint;
  baseGas: bigint;
  gasPrice: bigint;
  gasToken: string;
  refundReceiver: string;
  nonce: bigint;
}

export function computeSafeTxHash(safe: string, chainId: bigint, tx: SafeTx): string {
  const abi = ethers.AbiCoder.defaultAbiCoder();
  const domainSeparator = ethers.keccak256(
    abi.encode(["bytes32", "uint256", "address"], [DOMAIN_SEPARATOR_TYPEHASH, chainId, safe]),
  );
  const safeTxStructHash = ethers.keccak256(
    abi.encode(
      ["bytes32", "address", "uint256", "bytes32", "uint8", "uint256", "uint256", "uint256", "address", "address", "uint256"],
      [
        SAFE_TX_TYPEHASH,
        tx.to,
        tx.value,
        ethers.keccak256(tx.data),
        tx.operation,
        tx.safeTxGas,
        tx.baseGas,
        tx.gasPrice,
        tx.gasToken,
        tx.refundReceiver,
        tx.nonce,
      ],
    ),
  );
  return ethers.keccak256(
    ethers.concat(["0x1901", domainSeparator, safeTxStructHash]),
  );
}

/**
 * Sign safeTxHash with a private key, returns 65-byte ECDSA signature
 * formatted as Safe expects (r || s || v).
 */
export function signSafeTxHash(safeTxHash: string, privateKey: string): string {
  const signingKey = new ethers.SigningKey(privateKey);
  const sig = signingKey.sign(safeTxHash);
  // Safe expects v in {27, 28} for EOA sigs (no chain id); ethers gives us {27, 28} already
  return ethers.concat([sig.r, sig.s, ethers.toBeHex(sig.v, 1)]);
}

/**
 * Pack multiple owner signatures sorted by owner address ascending (Safe requirement).
 */
export function packSignatures(sigs: Array<{ owner: string; sig: string }>): string {
  const sorted = [...sigs].sort((a, b) => (a.owner.toLowerCase() < b.owner.toLowerCase() ? -1 : 1));
  return ethers.concat(sorted.map((s) => s.sig));
}

// ─── MultiSend encoding for batch transactions ───────────────────────
export interface MultiSendCall {
  operation: number; // 0 = Call, 1 = DelegateCall
  to: string;
  value: bigint;
  data: string;
}

/**
 * Encode multiple calls into MultiSendCallOnly format.
 * Each call: operation(1) + to(20) + value(32) + dataLength(32) + data
 */
export function encodeMultiSend(calls: MultiSendCall[]): string {
  const parts = calls.map((c) => {
    const dataBytes = ethers.getBytes(c.data);
    return ethers.solidityPacked(
      ["uint8", "address", "uint256", "uint256", "bytes"],
      [c.operation, c.to, c.value, dataBytes.length, c.data],
    );
  });
  const packed = ethers.concat(parts);
  // multiSend(bytes transactions) selector
  const MULTISEND_SELECTOR = "0x8d80ff0a";
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(["bytes"], [packed]);
  return MULTISEND_SELECTOR + encoded.slice(2);
}
