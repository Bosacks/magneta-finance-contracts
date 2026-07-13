/**
 * Phase 1 — parameterized Safe Transaction Builder batch GENERATOR.
 *
 * WHAT THIS DOES
 * --------------
 * Phase 1 of the contract redeploy redeploys `MagnetaOFTStandardFactory` on each
 * LZ-V2 chain and re-wires it so:
 *   (a) the new factory auto-registers freshly-minted tokens on the local
 *       TokenOpsModule  -> factory.setTokenOpsModule(tokenOpsModule)   [the
 *       registerToken functional fix; the new factory bytecode calls
 *       TokenOpsModule.registerByTokenOwner inside createOFTStandardToken /
 *       createForCreator]
 *   (b) the new factory is wired as the cross-chain creator so module-only
 *       createForCreator works         -> factory.setCrossChainCreator(dispatcher)
 *   (c) cross-chain CREATE_TOKEN lands on the NEW factory
 *                                       -> dispatcher.setStandardFactory(newFactory)
 *       (repeated for the V3 dispatcher where one exists).
 *
 * The final factory addresses are not known until deploy time, so this is a
 * GENERATOR: it reads an address table the owner fills in post-deploy
 * (scripts/safe/phase1-addresses.json, falling back to the committed
 * .template.json) and emits one Safe Transaction Builder JSON per chain.
 *
 * OWNERSHIP / WHO SIGNS WHAT (evidence from the .sol sources)
 * -----------------------------------------------------------
 *   - MagnetaOFTStandardFactory.setTokenOpsModule(address)   onlyOwner  (0x1dff08b6)
 *   - MagnetaOFTStandardFactory.setCrossChainCreator(address) onlyOwner (0x291604e5)
 *       (contracts/MagnetaOFTStandardFactory.sol L94, L104)
 *     The factory is `Ownable(msg.sender)` (OZ 4.x single-step Ownable, NOT
 *     Ownable2Step), so right after deploy it is owned by the DEPLOYER EOA
 *     (deploy-oft-factories.ts: "Ownership is NOT yet transferred to the Safe").
 *     => By default (factoryOwnedBySafe=false) these TWO setters are EOA calls
 *        and are printed as cast/hardhat commands, NOT placed in the Safe batch.
 *     => If the owner transfers factory ownership to the Safe first
 *        (single tx, no acceptOwnership leg) and sets factoryOwnedBySafe=true,
 *        the two setters ARE included in the Safe batch.
 *
 *   - CreateTokenDispatcher(.V3).setStandardFactory(address) onlyOwner (0x005fa939)
 *       (contracts/CreateTokenDispatcher.sol L131, CreateTokenDispatcherV3.sol L139)
 *     Both dispatchers are `Ownable(_delegate)` and were transferred to the
 *     chain's Safe (deployments-dispatcher[-v3]/<net>.json `safe`), so this is
 *     ALWAYS a Safe-batch tx.
 *
 *   NOTE on the selector: an earlier hand-made batch (polygon-d3-redeploy-batch.json)
 *   encoded the dispatcher repoint with selector 0x193055ae = setStdFactory(address),
 *   which does NOT exist on the deployed dispatcher. The real function is
 *   setStandardFactory(address) = 0x005fa939. This generator uses the real ABI.
 *
 * USAGE
 * -----
 *   cd contracts/solidity
 *   # fill scripts/safe/phase1-addresses.json (copy from the .template.json)
 *   npx hardhat run scripts/safe/generate-phase1-batches.ts
 *   # or: npx ts-node scripts/safe/generate-phase1-batches.ts
 *
 * OUTPUT
 * ------
 *   scripts/safe/<network>-phase1-OFTSetup-batch.json   (one per filled chain)
 *   ...containing ONLY Safe-owned txs. Import each into the Safe Transaction
 *   Builder app and sign with the listed Safe.
 *
 * No on-chain calls are made.
 */
import { ethers } from "ethers";
import * as fs from "node:fs";
import * as path from "node:path";

const SAFE_DIR = __dirname;
const CONFIG_PATH = path.join(SAFE_DIR, "phase1-addresses.json");
const TEMPLATE_PATH = path.join(SAFE_DIR, "phase1-addresses.template.json");

const ZERO = "0x0000000000000000000000000000000000000000";

// Real ABIs (verified against the .sol sources + selector computation).
const factoryIface = new ethers.Interface([
  "function setTokenOpsModule(address)", // 0x1dff08b6 onlyOwner
  "function setCrossChainCreator(address)", // 0x291604e5 onlyOwner
]);
const dispatcherIface = new ethers.Interface([
  "function setStandardFactory(address)", // 0x005fa939 onlyOwner (V2 + V3)
]);

interface ChainEntry {
  network: string;
  newStandardFactory: string;
  tokenOpsModule: string;
  dispatcher: string;
  dispatcherV3?: string;
  safe: string;
  factoryOwnedBySafe?: boolean;
}

interface SafeTx {
  to: string;
  value: string;
  data: string;
  contractMethod: null;
  contractInputsValues: null;
}

function isSet(addr: string | undefined): boolean {
  return !!addr && ethers.isAddress(addr) && addr.toLowerCase() !== ZERO;
}

function loadConfig(): { source: string; chains: Record<string, ChainEntry> } {
  const usedPath = fs.existsSync(CONFIG_PATH) ? CONFIG_PATH : TEMPLATE_PATH;
  if (!fs.existsSync(usedPath)) {
    throw new Error(
      `No address table found. Expected ${CONFIG_PATH} or ${TEMPLATE_PATH}.`,
    );
  }
  const raw = JSON.parse(fs.readFileSync(usedPath, "utf-8"));
  return { source: usedPath, chains: raw.chains as Record<string, ChainEntry> };
}

function main() {
  const { source, chains } = loadConfig();
  console.log(`\n── Phase 1 Safe-batch generator ──`);
  console.log(`Address table: ${path.relative(process.cwd(), source)}`);
  if (path.basename(source) === "phase1-addresses.template.json") {
    console.log(
      `  (using the TEMPLATE — all factory/tokenOps fields are zero, so every`,
    );
    console.log(`   chain will be reported SKIPPED. Copy it to phase1-addresses.json`);
    console.log(`   and fill in the real addresses post-deploy.)`);
  }

  const generated: string[] = [];
  const skipped: { network: string; chainId: string; reason: string }[] = [];
  // EOA-side setter calls the deployer must run directly (factory still EOA-owned).
  const eoaCalls: string[] = [];

  for (const [chainId, e] of Object.entries(chains)) {
    const net = e.network ?? `chain-${chainId}`;

    // Skip if the post-deploy addresses are not filled in yet.
    if (!isSet(e.newStandardFactory)) {
      skipped.push({ network: net, chainId, reason: "newStandardFactory blank/zero" });
      continue;
    }
    if (!isSet(e.tokenOpsModule)) {
      skipped.push({ network: net, chainId, reason: "tokenOpsModule blank/zero" });
      continue;
    }
    if (!isSet(e.safe)) {
      skipped.push({ network: net, chainId, reason: "safe blank/zero" });
      continue;
    }
    const hasV2 = isSet(e.dispatcher);
    const hasV3 = isSet(e.dispatcherV3);
    if (!hasV2 && !hasV3) {
      skipped.push({ network: net, chainId, reason: "no dispatcher (V2/V3) set" });
      continue;
    }

    const factoryToSafe = e.factoryOwnedBySafe === true;
    const txs: SafeTx[] = [];

    // (a)+(b) factory setters — Safe batch only if factory ownership is on the Safe.
    if (factoryToSafe) {
      txs.push({
        to: e.newStandardFactory,
        value: "0",
        data: factoryIface.encodeFunctionData("setTokenOpsModule", [e.tokenOpsModule]),
        contractMethod: null,
        contractInputsValues: null,
      });
      // crossChainCreator = the V3 dispatcher if present, else the V2 dispatcher
      // (the dispatcher is what calls factory.createForCreator).
      const crossChainCreator = hasV3 ? (e.dispatcherV3 as string) : e.dispatcher;
      txs.push({
        to: e.newStandardFactory,
        value: "0",
        data: factoryIface.encodeFunctionData("setCrossChainCreator", [crossChainCreator]),
        contractMethod: null,
        contractInputsValues: null,
      });
    } else {
      const crossChainCreator = hasV3 ? (e.dispatcherV3 as string) : e.dispatcher;
      eoaCalls.push(
        `# ${net} (chainId ${chainId}) — factory ${e.newStandardFactory} still EOA-owned`,
      );
      eoaCalls.push(
        `cast send ${e.newStandardFactory} "setTokenOpsModule(address)" ${e.tokenOpsModule} --rpc-url $RPC_${chainId} --private-key $DEPLOYER_PK`,
      );
      eoaCalls.push(
        `cast send ${e.newStandardFactory} "setCrossChainCreator(address)" ${crossChainCreator} --rpc-url $RPC_${chainId} --private-key $DEPLOYER_PK`,
      );
    }

    // (c) dispatcher repoint(s) — ALWAYS Safe batch (dispatchers are Safe-owned).
    if (hasV2) {
      txs.push({
        to: e.dispatcher,
        value: "0",
        data: dispatcherIface.encodeFunctionData("setStandardFactory", [e.newStandardFactory]),
        contractMethod: null,
        contractInputsValues: null,
      });
    }
    if (hasV3) {
      txs.push({
        to: e.dispatcherV3 as string,
        value: "0",
        data: dispatcherIface.encodeFunctionData("setStandardFactory", [e.newStandardFactory]),
        contractMethod: null,
        contractInputsValues: null,
      });
    }

    const batch = {
      version: "1.0",
      chainId: String(chainId),
      createdAt: 1780500000,
      meta: {
        name: `Magneta Phase 1 OFT setup — ${net}`,
        description:
          `Phase 1 redeploy of MagnetaOFTStandardFactory. Repoints the ` +
          `CreateTokenDispatcher${hasV3 ? "(+V3)" : ""} so cross-chain CREATE_TOKEN ` +
          `lands on the new factory (${e.newStandardFactory})` +
          (factoryToSafe
            ? ` AND wires the new factory's TokenOpsModule (${e.tokenOpsModule}) + ` +
              `crossChainCreator so freshly-minted tokens auto-register (no extra ` +
              `registerByTokenOwner tx). `
            : ` . NOTE: factory.setTokenOpsModule + factory.setCrossChainCreator are ` +
              `NOT in this batch — the factory is still deployer-EOA-owned; run those ` +
              `two setters as EOA cast txs (see generator output). `) +
          `Sign with Safe ${e.safe}.`,
      },
      transactions: txs,
    };

    const outPath = path.join(SAFE_DIR, `${net}-phase1-OFTSetup-batch.json`);
    fs.writeFileSync(outPath, JSON.stringify(batch, null, 2) + "\n");
    generated.push(
      `${net.padEnd(12)} chainId ${chainId.padEnd(7)} ${txs.length} tx  -> ${path.relative(process.cwd(), outPath)}` +
        (factoryToSafe ? "  [factory setters IN batch]" : "  [factory setters = EOA]"),
    );
  }

  // ── Summary ──────────────────────────────────────────────────────────────
  console.log(`\n── GENERATED (${generated.length}) ──`);
  if (generated.length === 0) console.log("  (none)");
  for (const g of generated) console.log("  " + g);

  console.log(`\n── SKIPPED (${skipped.length}) ──`);
  for (const s of skipped) {
    console.log(`  ${s.network.padEnd(12)} chainId ${s.chainId.padEnd(7)} — ${s.reason}`);
  }

  console.log(`\n── EOA-SIDE SETTER CALLS (run these directly; NOT in any Safe batch) ──`);
  if (eoaCalls.length === 0) {
    console.log("  (none — every generated chain has factoryOwnedBySafe=true)");
  } else {
    console.log(
      "  Factory is owned by the deployer EOA post-deploy; these onlyOwner setters",
    );
    console.log("  must be sent by the deployer key (set $DEPLOYER_PK and per-chain $RPC_<id>):");
    for (const c of eoaCalls) console.log("    " + c);
  }

  console.log(`\nDone. ${generated.length} batch(es) written, ${skipped.length} chain(s) skipped.`);
}

main();
