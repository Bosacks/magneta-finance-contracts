/**
 * Execute a Safe Tx Builder JSON batch via direct execTransaction call.
 * Replaces the Safe Wallet UI flow for chains where the UI doesn't support the chain.
 *
 * Reads the Safe address from deployments/<network>.json under `gnosisSafe`.
 * Requires both owner private keys to sign:
 *   - DEPLOYER_PRIVATE_KEY env var (already used by Hardhat config)
 *   - PAUSE_GUARDIAN_PRIVATE_KEY env var (paste only when running this script)
 *
 * Usage:
 *   PAUSE_GUARDIAN_PRIVATE_KEY=0x... pnpm hardhat run scripts/safe/inhouse/execBatch.ts \
 *     --network cronos -- scripts/safe/cronos-acceptOwnership-batch.json
 *
 * Or shorthand (positional argument is the batch file path):
 *   BATCH=scripts/safe/cronos-acceptOwnership-batch.json PAUSE_GUARDIAN_PRIVATE_KEY=0x... \
 *     pnpm hardhat run scripts/safe/inhouse/execBatch.ts --network cronos
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import {
  SAFE_OWNERS,
  MULTISEND_CALLONLY,
  computeSafeTxHash,
  signSafeTxHash,
  packSignatures,
  encodeMultiSend,
  type MultiSendCall,
  type SafeTx,
} from "./lib/safe";

const SAFE_ABI = [
  "function nonce() view returns (uint256)",
  "function getThreshold() view returns (uint256)",
  "function getOwners() view returns (address[])",
  "function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures) external payable returns (bool)",
];

interface SafeBatchTransaction {
  to: string;
  value: string;
  data: string | null;
  contractMethod?: {
    inputs: Array<{ internalType?: string; name: string; type: string }>;
    name: string;
    payable: boolean;
  };
  contractInputsValues?: Record<string, string>;
}

interface SafeBatch {
  version: string;
  chainId: string;
  meta?: { name?: string; description?: string };
  transactions: SafeBatchTransaction[];
}

function encodeBatchTransaction(tx: SafeBatchTransaction): { to: string; data: string } {
  if (tx.data && tx.data !== "0x" && tx.data !== "0x0") {
    return { to: tx.to, data: tx.data };
  }
  if (!tx.contractMethod || !tx.contractInputsValues) {
    return { to: tx.to, data: "0x" };
  }
  const fn = tx.contractMethod;
  const types = fn.inputs.map((i) => i.type);
  const names = fn.inputs.map((i) => i.name);
  const fragment = `function ${fn.name}(${fn.inputs.map((i) => `${i.type} ${i.name}`).join(",")})`;
  const iface = new ethers.Interface([fragment]);
  const args = names.map((n, idx) => {
    const raw = tx.contractInputsValues![n];
    if (raw === undefined) throw new Error(`Missing input value for ${n}`);
    // Parse JSON arrays/booleans/numbers; addresses + bytes stay strings
    if (raw.startsWith("[") || raw === "true" || raw === "false") return JSON.parse(raw);
    if (types[idx].startsWith("uint") || types[idx].startsWith("int")) return BigInt(raw);
    return raw;
  });
  const data = iface.encodeFunctionData(fn.name, args);
  return { to: tx.to, data };
}

async function main() {
  const batchPath = process.env.BATCH || process.argv[process.argv.length - 1];
  if (!batchPath || !fs.existsSync(batchPath)) {
    console.error(`Batch file not found: ${batchPath}`);
    console.error(`Pass via BATCH=path env var, or as last positional arg.`);
    process.exit(1);
  }

  const guardianKey = process.env.PAUSE_GUARDIAN_PRIVATE_KEY;
  if (!guardianKey) {
    console.error(`PAUSE_GUARDIAN_PRIVATE_KEY env var required (the second Safe owner).`);
    process.exit(1);
  }

  const batch: SafeBatch = JSON.parse(fs.readFileSync(batchPath, "utf-8"));
  console.log(`Network    : ${network.name}`);
  console.log(`Batch      : ${path.basename(batchPath)} (${batch.transactions.length} tx)`);
  console.log(`Description: ${batch.meta?.description ?? "(none)"}`);
  console.log();

  // Resolve Safe address
  const depPath = path.join(__dirname, "..", "..", "..", "deployments", `${network.name}.json`);
  if (!fs.existsSync(depPath)) {
    console.error(`No deployments/${network.name}.json — deploy Safe first via createMagnetaSafe.ts`);
    process.exit(1);
  }
  const dep = JSON.parse(fs.readFileSync(depPath, "utf-8"));
  const safeAddress: string = dep.gnosisSafe;
  if (!safeAddress) {
    console.error(`deployments/${network.name}.json missing 'gnosisSafe' field`);
    process.exit(1);
  }
  console.log(`Safe       : ${safeAddress}`);

  const safe = await ethers.getContractAt(SAFE_ABI, safeAddress);

  // Read on-chain state. Sanity check + we NEED the nonce + chainId to compute safeTxHash.
  // Some RPCs (Sei) return malformed responses; retry up to 3 times before giving up.
  /** Tiny pacer for RPCs that throttle on bursts of eth_call (Sei evm-rpc). */
  const pace = (ms = 250) => new Promise((r) => setTimeout(r, ms));

  async function readSafeState() {
    const MAX_ATTEMPTS = 6;
    let attempt = 0;
    while (attempt < MAX_ATTEMPTS) {
      try {
        const onChainOwners: string[] = await safe.getOwners();
        await pace();
        const threshold = await safe.getThreshold();
        await pace();
        const nonce = await safe.nonce();
        await pace();
        const chainId = (await ethers.provider.getNetwork()).chainId;
        return { onChainOwners, threshold, nonce, chainId };
      } catch (err: any) {
        attempt++;
        const msg = err?.message ?? String(err);
        console.warn(`[exec] readSafeState attempt ${attempt}/${MAX_ATTEMPTS} failed: ${msg.slice(0, 120)}`);
        if (attempt < MAX_ATTEMPTS) {
          // Exponential backoff — 2s, 5s, 10s, 20s, 40s — gives the rate limit
          // window time to reset.
          const backoff = Math.min(2000 * 2 ** (attempt - 1), 40000);
          await new Promise((r) => setTimeout(r, backoff));
        }
      }
    }
    throw new Error(`Unable to read Safe state after ${MAX_ATTEMPTS} attempts`);
  }

  const { onChainOwners, threshold, nonce, chainId } = await readSafeState();
  console.log(`On-chain   : threshold=${threshold} nonce=${nonce} owners=[${onChainOwners.map((o) => o.slice(0, 8)).join(", ")}]`);

  // Encode all batch txs into MultiSend calldata
  const calls: MultiSendCall[] = batch.transactions.map((t) => {
    const { to, data } = encodeBatchTransaction(t);
    return { operation: 0, to, value: BigInt(t.value || "0"), data };
  });
  const isMulti = calls.length > 1;
  const safeTx: SafeTx = isMulti
    ? {
        to: MULTISEND_CALLONLY,
        value: 0n,
        data: encodeMultiSend(calls),
        operation: 1, // delegatecall to MultiSend
        safeTxGas: 0n,
        baseGas: 0n,
        gasPrice: 0n,
        gasToken: ethers.ZeroAddress,
        refundReceiver: ethers.ZeroAddress,
        nonce,
      }
    : {
        to: calls[0].to,
        value: calls[0].value,
        data: calls[0].data,
        operation: 0, // direct call
        safeTxGas: 0n,
        baseGas: 0n,
        gasPrice: 0n,
        gasToken: ethers.ZeroAddress,
        refundReceiver: ethers.ZeroAddress,
        nonce,
      };

  const safeTxHash = computeSafeTxHash(safeAddress, chainId, safeTx);
  console.log(`safeTxHash : ${safeTxHash}`);
  console.log();

  // Get deployer key from Hardhat signer (already configured)
  const [deployerSigner] = await ethers.getSigners();
  const deployerAddr = await deployerSigner.getAddress();
  if (deployerAddr.toLowerCase() !== SAFE_OWNERS[0].toLowerCase()) {
    console.error(`Hardhat signer ${deployerAddr} doesn't match expected Deployer ${SAFE_OWNERS[0]}`);
    process.exit(1);
  }
  // Hardhat signer doesn't expose its private key directly — need to use HardhatEthersSigner.signMessage
  // For raw EIP-712 signing of the safeTxHash, we use signer.signTypedData OR signer.signMessage(arrayify(hash))
  // Safe expects a 65-byte sig: r||s||v with v in {27,28} (raw ECDSA, no message prefix)
  // signMessage adds the "\x19Ethereum Signed Message:\n32" prefix → wrong
  // We must use the raw signing path. With Hardhat HDWallet, we can extract private key from config.
  const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || process.env.PRIVATE_KEY;
  if (!PRIVATE_KEY) {
    console.error(`DEPLOYER_PRIVATE_KEY (or PRIVATE_KEY) env var required for raw EIP-712 signing.`);
    process.exit(1);
  }

  // Sign with both owners
  const sigDeployer = signSafeTxHash(safeTxHash, PRIVATE_KEY);
  const sigGuardian = signSafeTxHash(safeTxHash, guardianKey);
  const guardianAddr = new ethers.Wallet(guardianKey).address;
  if (guardianAddr.toLowerCase() !== SAFE_OWNERS[1].toLowerCase()) {
    console.error(`PauseGuardian key produces address ${guardianAddr}, expected ${SAFE_OWNERS[1]}`);
    process.exit(1);
  }

  const signatures = packSignatures([
    { owner: deployerAddr, sig: sigDeployer },
    { owner: guardianAddr, sig: sigGuardian },
  ]);

  console.log(`Submitting execTransaction (sender=${deployerAddr})...`);
  const tx = await safe.execTransaction(
    safeTx.to,
    safeTx.value,
    safeTx.data,
    safeTx.operation,
    safeTx.safeTxGas,
    safeTx.baseGas,
    safeTx.gasPrice,
    safeTx.gasToken,
    safeTx.refundReceiver,
    signatures,
  );
  console.log(`Tx hash    : ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`Mined in block ${receipt!.blockNumber}, gas used ${receipt!.gasUsed}`);
  console.log(`✅ Batch executed successfully`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
