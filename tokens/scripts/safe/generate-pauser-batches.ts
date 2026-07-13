/**
 * Multipauser — Safe Transaction Builder batch GENERATOR.
 *
 * Emits, per chain, a Safe batch that calls `addPauser(account)` on EVERY
 * pausable Magneta contract for BOTH the human guardian and the OpenZeppelin
 * Defender Relayer. `unpause()` stays owner-only, so this only grants the fast
 * PAUSE trigger to those two — never the ability to resume.
 *
 * WHY a Safe batch (not the deploy script): `deployAll.ts` adds the guardian to
 * gateway+swap inline while the deployer is still owner. After ownership moves to
 * the Safe, the remaining coverage (factory/pool/bundler/proxy/modules/curve/
 * bridge) and the Defender Relayer pauser must come from the Safe — this batch.
 *
 * ABI: `function addPauser(address)` — onlyOwner on every core/module/curve
 * contract (the multipauser change). Selector computed from the ABI below.
 *
 * USAGE
 *   cd contracts/solidity
 *   cp scripts/safe/pauser-addresses.template.json scripts/safe/pauser-addresses.json
 *   # fill safe + guardian + relayer + each deployed pausable address per chain
 *   npx hardhat run scripts/safe/generate-pauser-batches.ts
 * OUTPUT
 *   scripts/safe/<network>-pauser-batch.json  (import into Safe Tx Builder, sign)
 * No on-chain calls are made.
 */
import { ethers } from "ethers";
import * as fs from "node:fs";
import * as path from "node:path";

const SAFE_DIR = __dirname;
const CONFIG_PATH = path.join(SAFE_DIR, "pauser-addresses.json");
const TEMPLATE_PATH = path.join(SAFE_DIR, "pauser-addresses.template.json");
const ZERO = "0x0000000000000000000000000000000000000000";

const pauserIface = new ethers.Interface(["function addPauser(address)"]);

// The pausable contracts (keys are informational; any set address is wired).
const PAUSABLE_KEYS = [
  "gateway", "swap", "factory", "pool", "bundler", "proxy",
  "lpModule", "swapModule", "taxClaimModule", "tokenOpsModule",
  "lpAtomicModule", "curveFactory", "curvePool", "bridge",
] as const;

interface ChainEntry {
  network: string;
  safe: string;
  guardian: string;
  relayer?: string; // Defender Relayer; optional
  contracts: Partial<Record<(typeof PAUSABLE_KEYS)[number], string>>;
}
interface SafeTx { to: string; value: string; data: string; contractMethod: null; contractInputsValues: null; }

const isSet = (a?: string) => !!a && ethers.isAddress(a) && a.toLowerCase() !== ZERO;

function loadConfig() {
  const used = fs.existsSync(CONFIG_PATH) ? CONFIG_PATH : TEMPLATE_PATH;
  if (!fs.existsSync(used)) throw new Error(`No address table at ${CONFIG_PATH} or ${TEMPLATE_PATH}.`);
  return { source: used, chains: JSON.parse(fs.readFileSync(used, "utf-8")).chains as Record<string, ChainEntry> };
}

function main() {
  const { source, chains } = loadConfig();
  console.log(`\n── Multipauser Safe-batch generator ──`);
  console.log(`Address table: ${path.relative(process.cwd(), source)}`);
  const generated: string[] = [];
  const skipped: { network: string; chainId: string; reason: string }[] = [];

  for (const [chainId, e] of Object.entries(chains)) {
    const net = e.network ?? `chain-${chainId}`;
    if (!isSet(e.safe)) { skipped.push({ network: net, chainId, reason: "safe blank" }); continue; }
    if (!isSet(e.guardian)) { skipped.push({ network: net, chainId, reason: "guardian blank" }); continue; }

    const pausers = [e.guardian, ...(isSet(e.relayer) ? [e.relayer as string] : [])];
    const txs: SafeTx[] = [];
    const wiredContracts: string[] = [];

    for (const key of PAUSABLE_KEYS) {
      const addr = e.contracts?.[key];
      if (!isSet(addr)) continue;
      wiredContracts.push(key);
      for (const pauser of pausers) {
        txs.push({
          to: addr as string,
          value: "0",
          data: pauserIface.encodeFunctionData("addPauser", [pauser]),
          contractMethod: null,
          contractInputsValues: null,
        });
      }
    }

    if (txs.length === 0) { skipped.push({ network: net, chainId, reason: "no pausable address filled" }); continue; }

    const batch = {
      version: "1.0",
      chainId: String(chainId),
      createdAt: Math.floor(Date.now() / 1000),
      meta: {
        name: `Magneta multipauser — ${net}`,
        description:
          `addPauser for [${pausers.join(", ")}] on ${wiredContracts.length} contract(s): ` +
          `${wiredContracts.join(", ")}. unpause() stays Safe-only. Sign with Safe ${e.safe}.`,
      },
      transactions: txs,
    };
    const out = path.join(SAFE_DIR, `${net}-pauser-batch.json`);
    fs.writeFileSync(out, JSON.stringify(batch, null, 2));
    generated.push(`${net}: ${txs.length} tx (${wiredContracts.length} contracts × ${pausers.length} pauser)`);
  }

  console.log(`\nGenerated:\n  ${generated.join("\n  ") || "(none)"}`);
  if (skipped.length) console.log(`\nSkipped:\n  ${skipped.map((s) => `${s.network}: ${s.reason}`).join("\n  ")}`);
}

main();
