/**
 * Migrate Polygon + Base Layer 1 ownership EOA → Safe.
 *
 * Background — Sentinelle config-drift scanner finding 2026-06-08:
 *   On Polygon (chainId 137) and Base (8453), the frontend constants point
 *   at a Gateway + LPModule + TokenOpsModule deployment owned by the deployer
 *   EOA (0x6206…e25E). A separate Safe-multisig-owned deployment exists in
 *   the contracts repo but is NOT what the frontend or LPSourceWrapper
 *   actually use — the EOA-owned ecosystem is the production one.
 *   Single-key compromise of the deployer would hijack LP/MINT/FREEZE on
 *   those two chains.
 *
 *   The fix is to transfer ownership of the EOA-owned Gateway + LPModule +
 *   TokenOpsModule to the Safe so the multisig posture matches the other
 *   17 chains. The LPSourceWrapper has no owner (immutable wiring) so no
 *   action needed there. TokenCreationModule is already Safe-owned (done
 *   in an earlier session, partial migration).
 *
 *   All target contracts use OZ Ownable2Step — the deployer initiates the
 *   transfer (sets pendingOwner), the Safe accepts via a Safe batch (this
 *   script also generates that batch).
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/migrate-layer1-to-safe.ts --network polygon
 *   pnpm hardhat run scripts/deploy/migrate-layer1-to-safe.ts --network base
 *
 * After running per chain:
 *   1. Sign + execute scripts/safe/<chain>-accept-layer1-batch.json via the
 *      chain's in-house OR Safe Wallet UI Safe (execBatch.ts).
 *   2. Remove the chain from KNOWN_LAYER1_DRIFT in
 *      magneta-finance-tokens/__tests__/integration/frontendOnChainParity.test.ts
 *      so the strict cross-repo parity check re-engages on this chain.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const BATCH_DIR = path.join(__dirname, "..", "safe");

// Hardcoded per chain — these are the EOA-owned addresses we're migrating.
// Pulled from magneta-finance-tokens/lib/constants/gatewayChains.ts (the
// frontend's source of truth — the active production Layer 1 ecosystem).
const TARGETS: Record<number, {
  safe: string;
  gateway: string;
  lpModule: string;
  tokenOpsModule: string;
}> = {
  137: {
    safe:           "0x4AeA3A398Db41b45e146c08131aD27c75b02EC2F",
    gateway:        "0x7b1A44FA3928d61E04e8C04E6798DEe1c3d5f66C",
    lpModule:       "0x864Eed1d5DF4b8457bfb42aBee1468127D315539",
    tokenOpsModule: "0xfB95B039c6Cd2Dfbf94D3e849D16Fc333B27c0C6",
  },
  8453: {
    safe:           "0xC4c96aF54cdE078dc993d6948199b0AF8cD6717a",
    gateway:        "0x852976d4c837824e53357E84e851ce0C5A1092ff",
    lpModule:       "0x9003cEe70616B07e184FB4bC39a54A4694FC1642",
    tokenOpsModule: "0xb234B37211f2c5653501FA42936b0729c49a0eB7",
  },
};

const OWNABLE2STEP_ABI = [
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function transferOwnership(address)",
  "function acceptOwnership()",
];

async function main() {
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const cfg = TARGETS[chainId];
  if (!cfg) throw new Error(`No Layer 1 migration target for chainId ${chainId} — supported: 137, 8453`);

  console.log(`\n── Migrate Layer 1 ownership EOA → Safe on ${network.name} ──`);
  console.log(`   Caller   : ${signer.address}`);
  console.log(`   Safe     : ${cfg.safe}`);
  console.log(`   Gateway        : ${cfg.gateway}`);
  console.log(`   LPModule       : ${cfg.lpModule}`);
  console.log(`   TokenOpsModule : ${cfg.tokenOpsModule}`);

  const contracts = [
    { addr: cfg.gateway,        label: "Gateway" },
    { addr: cfg.lpModule,       label: "LPModule" },
    { addr: cfg.tokenOpsModule, label: "TokenOpsModule" },
  ];

  // ─── Pre-flight: verify deployer is current owner of all 3 ─────────────
  console.log(`\n── Pre-flight ownership check ──`);
  for (const c of contracts) {
    const inst = await ethers.getContractAt(OWNABLE2STEP_ABI, c.addr);
    const owner = await inst.owner();
    const pending = await inst.pendingOwner();
    console.log(`   ${c.label.padEnd(16)} owner=${owner} pending=${pending}`);
    if (pending.toLowerCase() === cfg.safe.toLowerCase()) {
      console.log(`     ⚠ Already pending to the right Safe — transferOwnership is idempotent, skipping`);
      continue;
    }
    if (owner.toLowerCase() === cfg.safe.toLowerCase()) {
      console.log(`     ✓ Already owned by Safe — nothing to do for this contract`);
      continue;
    }
    if (owner.toLowerCase() !== signer.address.toLowerCase()) {
      throw new Error(
        `${c.label} owner (${owner}) is not the deployer (${signer.address}) ` +
        `AND not the Safe (${cfg.safe}). Manual investigation required.`,
      );
    }
  }

  // ─── Phase 1 (deployer): transferOwnership × 3 ──────────────────────────
  console.log(`\n── Phase 1: deployer calls transferOwnership(safe) for each ──`);
  for (const c of contracts) {
    const inst = await ethers.getContractAt(OWNABLE2STEP_ABI, c.addr);
    const owner = await inst.owner();
    const pending = await inst.pendingOwner();
    if (owner.toLowerCase() === cfg.safe.toLowerCase()) continue;
    if (pending.toLowerCase() === cfg.safe.toLowerCase()) {
      console.log(`   ⏭  ${c.label}: pendingOwner already set, skipping tx`);
      continue;
    }
    const tx = await inst.transferOwnership(cfg.safe);
    const receipt = await tx.wait();
    console.log(`   ✓ ${c.label.padEnd(16)} tx ${tx.hash} (gas ${receipt!.gasUsed.toString()})`);
  }

  // ─── Phase 2: generate Safe batch for acceptOwnership × 3 ───────────────
  console.log(`\n── Phase 2: generate Safe batch with acceptOwnership × 3 ──`);
  const iface = new ethers.Interface([
    "function acceptOwnership()",
  ]);
  const transactions = contracts.map((c) => ({
    to: c.addr,
    value: "0",
    data: iface.encodeFunctionData("acceptOwnership", []),
    contractMethod: null,
    contractInputsValues: null,
  }));

  const batch = {
    version: "1.0",
    chainId: String(chainId),
    createdAt: 1780500000,
    meta: {
      name: `Magneta Layer 1 ownership migration — ${network.name}`,
      description:
        `Sentinelle config-drift scanner finding remediation 2026-06-08. ` +
        `Completes the Ownable2Step second leg for ${network.name}: ` +
        `Safe accepts ownership of Gateway (${cfg.gateway}), LPModule ` +
        `(${cfg.lpModule}), and TokenOpsModule (${cfg.tokenOpsModule}). ` +
        `Eliminates single-key risk on ${network.name}'s Layer 1 ops ` +
        `(LP / MINT / FREEZE) — they were previously deployer-EOA-owned ` +
        `out of step with the other 17 mainnet chains. Sign with Safe ${cfg.safe}.`,
    },
    transactions,
  };

  if (!fs.existsSync(BATCH_DIR)) fs.mkdirSync(BATCH_DIR, { recursive: true });
  const batchPath = path.join(BATCH_DIR, `${network.name}-accept-layer1-batch.json`);
  fs.writeFileSync(batchPath, JSON.stringify(batch, null, 2) + "\n");
  console.log(`   ✓ Batch: ${batchPath}`);

  console.log(`\n── NEXT STEPS ──`);
  console.log(`1. Sign + execute the Safe batch:`);
  console.log(`     BATCH=${path.relative(process.cwd(), batchPath)} \\`);
  console.log(`       pnpm hardhat run scripts/safe/inhouse/execBatch.ts --network ${network.name}`);
  console.log(`   (For Safe Wallet UI chains: upload the JSON via app.safe.global Transaction Builder)`);
  console.log(`2. Verify post-migration:`);
  console.log(`     cast call ${cfg.gateway} "owner()(address)" --rpc-url <RPC>`);
  console.log(`     → expect ${cfg.safe}`);
  console.log(`3. Remove ${chainId} from KNOWN_LAYER1_DRIFT in the parity test:`);
  console.log(`   magneta-finance-tokens/__tests__/integration/frontendOnChainParity.test.ts`);
}

main().catch((e) => { console.error(e); process.exit(1); });
