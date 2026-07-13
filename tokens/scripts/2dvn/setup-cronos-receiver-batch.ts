/**
 * Sprint D #2 — Generate a Safe batch that wires the on-chain
 * CronosCreateTokenReceiver into the legacy factory + whitelists every
 * source chain's MagnetaGateway as a valid intent origin.
 *
 * The batch contains 1 + 19 transactions:
 *   1. factory.setCrossChainCreator(receiver) — replaces the bare Relayer
 *      wallet with the on-chain verifier in the factory's permission slot
 *   2-20. receiver.setTrustedSource(chainId, gateway) for each of the 19
 *      EVM chains whose MagnetaGateway can produce valid intents
 *
 * Output: scripts/safe/setup-cronos-receiver-batch.json
 * Execute via execBatch.ts in the contracts repo (network = cronos).
 *
 * Usage:
 *   pnpm tsx scripts/2dvn/setup-cronos-receiver-batch.ts
 */
import fs from "node:fs";
import path from "node:path";
import { encodeFunctionData } from "viem";

const REPO_ROOT = path.join(__dirname, "..", "..");
const OUTPUT_DIR = path.join(REPO_ROOT, "scripts", "safe");

// The 19 source chains whose Gateway can sign CREATE_TOKEN intents bound
// for Cronos. Read from the contracts repo's deployments/<chain>.json so
// the whitelist always reflects the real, deployed Gateway addresses.
const SOURCE_CHAINS = [
  "polygon", "arbitrum", "base", "optimism", "avalanche", "bsc", "mantle",
  "celo", "linea", "gnosis", "sei", "monad", "unichain", "sonic",
  "berachain", "plasma", "katana", "flare", "abstract",
];

const CHAIN_ID_BY_NAME: Record<string, number> = {
  polygon: 137,    arbitrum: 42161,  base: 8453,      optimism: 10,
  avalanche: 43114, bsc: 56,         mantle: 5000,    celo: 42220,
  linea: 59144,    gnosis: 100,      sei: 1329,       monad: 143,
  unichain: 130,   sonic: 146,       berachain: 80094, plasma: 9745,
  katana: 747474,  flare: 14,        abstract: 2741,
};

const FACTORY_ACCEPT_OWNERSHIP_ABI = [{
  type: "function",
  name: "acceptOwnership",
  stateMutability: "nonpayable",
  inputs: [],
  outputs: [],
}] as const;

const FACTORY_SET_CROSS_CHAIN_CREATOR_ABI = [{
  type: "function",
  name: "setCrossChainCreator",
  stateMutability: "nonpayable",
  inputs: [{ name: "_creator", type: "address" }],
  outputs: [],
}] as const;

const RECEIVER_SET_TRUSTED_SOURCE_ABI = [{
  type: "function",
  name: "setTrustedSource",
  stateMutability: "nonpayable",
  inputs: [
    { name: "sourceChainId", type: "uint256" },
    { name: "sourceGateway", type: "address" },
  ],
  outputs: [],
}] as const;

interface ContractsDeployment {
  network: string;
  contracts?: { MagnetaGateway?: string };
}

function readSourceGateway(chainName: string): string | null {
  // Sibling repo: ../../../../magneta-finance-contracts/deployments/<chain>.json
  const candidate = path.resolve(
    REPO_ROOT, "..", "..", "..",
    "magneta-finance-contracts", "deployments", `${chainName}.json`,
  );
  if (!fs.existsSync(candidate)) return null;
  const j: ContractsDeployment = JSON.parse(fs.readFileSync(candidate, "utf-8"));
  return j.contracts?.MagnetaGateway ?? null;
}

function readReceiverDeployment(): { receiver: string; factory: string; safe: string } {
  const recordPath = path.join(REPO_ROOT, "deployments-cronos-receiver", "cronos.json");
  if (!fs.existsSync(recordPath)) {
    throw new Error(
      `No deployment record at ${recordPath} — run deploy-cronos-receiver.ts first.`,
    );
  }
  const j = JSON.parse(fs.readFileSync(recordPath, "utf-8"));
  return { receiver: j.receiver, factory: j.factory, safe: j.owner };
}

function main() {
  const { receiver, factory, safe } = readReceiverDeployment();
  console.log(`Receiver: ${receiver}`);
  console.log(`Factory : ${factory}`);
  console.log(`Safe    : ${safe}`);

  const transactions: Array<{
    to: string;
    value: string;
    data: string;
    contractMethod: null;
    contractInputsValues: null;
  }> = [];

  // Tx 1 — accept factory ownership (Ownable2Step second leg, after the
  // deployer EOA calls transferOwnership(safe) — done outside this batch).
  const acceptData = encodeFunctionData({
    abi: FACTORY_ACCEPT_OWNERSHIP_ABI,
    functionName: "acceptOwnership",
    args: [],
  });
  transactions.push({
    to: factory,
    value: "0",
    data: acceptData,
    contractMethod: null,
    contractInputsValues: null,
  });
  console.log(`\nTx 1: factory.acceptOwnership() (Ownable2Step)`);

  // Tx 2 — promote receiver as factory's crossChainCreator
  const setCrossData = encodeFunctionData({
    abi: FACTORY_SET_CROSS_CHAIN_CREATOR_ABI,
    functionName: "setCrossChainCreator",
    args: [receiver as `0x${string}`],
  });
  transactions.push({
    to: factory,
    value: "0",
    data: setCrossData,
    contractMethod: null,
    contractInputsValues: null,
  });
  console.log(`Tx 2: factory.setCrossChainCreator(${receiver})`);

  // Tx 2..20 — whitelist each source Gateway
  let added = 0;
  const skipped: string[] = [];
  for (const chainName of SOURCE_CHAINS) {
    const gateway = readSourceGateway(chainName);
    if (!gateway) {
      skipped.push(`${chainName} (no contracts/${chainName}.json or no MagnetaGateway field)`);
      continue;
    }
    const chainId = CHAIN_ID_BY_NAME[chainName];
    if (!chainId) {
      skipped.push(`${chainName} (no chainId mapping)`);
      continue;
    }
    const data = encodeFunctionData({
      abi: RECEIVER_SET_TRUSTED_SOURCE_ABI,
      functionName: "setTrustedSource",
      args: [BigInt(chainId), gateway as `0x${string}`],
    });
    transactions.push({
      to: receiver,
      value: "0",
      data,
      contractMethod: null,
      contractInputsValues: null,
    });
    console.log(`  + ${chainName.padEnd(10)} chainId=${String(chainId).padEnd(7)} gateway=${gateway}`);
    added++;
  }

  if (skipped.length > 0) {
    console.log(`\n⚠ Skipped:`);
    for (const s of skipped) console.log(`  - ${s}`);
  }

  const batch = {
    version: "1.0",
    chainId: "25", // Cronos
    createdAt: 1780500000, // fixed for replay-reproducibility
    meta: {
      name: "Magneta Cronos receiver — setup",
      description:
        `Sprint D #2 setup. Accepts factory (${factory}) ownership ` +
        `(Ownable2Step second leg — deployer must have called ` +
        `transferOwnership(safe) first), wires the on-chain ` +
        `CronosCreateTokenReceiver (${receiver}) as the factory's ` +
        `crossChainCreator, and whitelists ${added} source-chain Gateways ` +
        `as valid EIP-712 intent origins. Sign with the in-house Safe ` +
        `${safe} via execBatch.ts.`,
    },
    transactions,
  };

  if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  const outPath = path.join(OUTPUT_DIR, "setup-cronos-receiver-batch.json");
  fs.writeFileSync(outPath, JSON.stringify(batch, null, 2));

  console.log(`\n── DONE ──`);
  console.log(`Batch written: ${outPath}`);
  console.log(`Transactions: ${transactions.length} (1 acceptOwnership + 1 setCrossChainCreator + ${added} setTrustedSource)`);
  console.log(`\nNext: copy to contracts repo + execBatch.ts:`);
  console.log(`  cp ${outPath} ../../magneta-finance-contracts/scripts/safe/`);
  console.log(`  cd ../../magneta-finance-contracts`);
  console.log(`  BATCH=scripts/safe/setup-cronos-receiver-batch.json \\`);
  console.log(`    pnpm hardhat run scripts/safe/inhouse/execBatch.ts --network cronos`);
}

main();
