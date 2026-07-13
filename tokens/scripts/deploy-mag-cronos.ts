/**
 * Phase-3 deploy — MAGCronosToken on Cronos (chainId 25).
 *
 * Ships Sentinelle HIGH-1 (replay protection + epoch mint cap + pausable mint),
 * see docs/contract-redeploy-runbook.md §"Phase 3 — MAGCronos".
 *
 * The constructor changed to the 4-arg form:
 *   MAGCronosToken(address admin, address relayer, uint256 mintCapPerEpoch, uint256 epochLength)
 *
 * It grants DEFAULT_ADMIN_ROLE + PAUSER_ROLE to `admin`, MINTER_ROLE to
 * `relayer`, sets `currentRelayer`, and sets `mintCapPerEpoch`/`epochLength`.
 *
 * IMPORTANT — the cap binds from block 0:
 *   On Cronos `admin` is the in-house Safe (no Safe UI on Cronos). The deployer
 *   EOA does NOT hold DEFAULT_ADMIN_ROLE, so it CANNOT call `setMintCap` after
 *   deploy. We therefore pass a non-zero `mintCapPerEpoch` IN THE CONSTRUCTOR so
 *   the cap is enforced from the very first mint. Any later cap change must be a
 *   Safe batch calling `setMintCap(capPerEpoch, epochLength)`.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy-mag-cronos.ts --network cronos
 *
 * Env (all optional except where the default is flagged below):
 *   CRONOS_ADMIN_SAFE          admin (default: in-house Safe 0x40ea…b297)
 *   CRONOS_RELAYER             relayer (default: known relayer 0x2B89…6aC2)
 *   CRONOS_MINT_CAP_PER_EPOCH  cap in whole MAG tokens (default: 1_000_000)
 *   CRONOS_EPOCH_LENGTH        epoch in seconds (default: 86400 = 1 day)
 *
 * Output:
 *   deployments-mag/<network>.json with deployer/admin/relayer/cap/epoch/address.
 *
 * Does NOT enable outbound. Does NOT fund the treasury. Those are separate,
 * deliberate steps (see NEXT STEPS printed at the end).
 */
import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const CRONOS_CHAIN_ID = 25;

// ── Documented defaults (confirmed; do not invent) ──────────────────────────
// In-house Safe used on chains without a Safe Wallet UI (Cronos/Abstract/Flare/
// Sei). Source: memory infra_safe_inhouse.md + infra_cronos_deployment.md.
const DEFAULT_ADMIN_SAFE = "0x40ea2908Ea490d58E62D1Fd3364464D8A857b297";
// Cronos relayer wallet. Source: lib/relayer/cronosRelayer.ts.
const DEFAULT_RELAYER = "0x2B898219Ce1dbEb3ECd3956223b9Ff0C0B126aC2";
// Sensible cap so the control binds from block 0 — 1M MAG / day. The Safe can
// retune via setMintCap once real bridge throughput is known.
const DEFAULT_MINT_CAP_TOKENS = "1000000";
const DEFAULT_EPOCH_LENGTH = 86400; // 1 day, in seconds

interface MagCronosDeployment {
  network: string;
  chainId: number;
  contract: "MAGCronosToken";
  address: string;
  deployer: string;
  admin: string;
  relayer: string;
  mintCapPerEpoch: string; // wei (18 decimals)
  mintCapPerEpochTokens: string; // human-readable
  epochLength: number; // seconds
  timestamp: string;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n── Phase 3 — MAGCronosToken deploy ──`);
  console.log(`Network    : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer   : ${deployer.address}`);

  // ─── Network guard: Cronos only ──────────────────────────────────────────
  if (chainId !== CRONOS_CHAIN_ID) {
    throw new Error(
      `Refusing to deploy: connected to chainId ${chainId} (${network.name}), ` +
        `but MAGCronosToken is Cronos-only (chainId ${CRONOS_CHAIN_ID}). ` +
        `Re-run with --network cronos.`,
    );
  }

  // ─── Resolve constructor args ────────────────────────────────────────────
  const admin = ethers.getAddress(process.env.CRONOS_ADMIN_SAFE || DEFAULT_ADMIN_SAFE);
  const relayer = ethers.getAddress(process.env.CRONOS_RELAYER || DEFAULT_RELAYER);

  const capTokens = process.env.CRONOS_MINT_CAP_PER_EPOCH || DEFAULT_MINT_CAP_TOKENS;
  const mintCapPerEpoch = ethers.parseEther(capTokens);
  if (mintCapPerEpoch === 0n) {
    throw new Error(
      "Refusing to deploy with mintCapPerEpoch == 0 (uncapped). " +
        "admin is the Safe, so the deployer EOA cannot fix this afterwards — " +
        "the cap MUST be set in the constructor. Set CRONOS_MINT_CAP_PER_EPOCH.",
    );
  }

  const epochLength = Number(process.env.CRONOS_EPOCH_LENGTH || DEFAULT_EPOCH_LENGTH);
  if (!Number.isInteger(epochLength) || epochLength < 0) {
    throw new Error(`Invalid CRONOS_EPOCH_LENGTH: ${process.env.CRONOS_EPOCH_LENGTH}`);
  }

  const usingDefaultAdmin = !process.env.CRONOS_ADMIN_SAFE;
  const usingDefaultRelayer = !process.env.CRONOS_RELAYER;

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance    : ${ethers.formatEther(balance)} CRO`);
  console.log(
    `Admin      : ${admin}${usingDefaultAdmin ? "  (default in-house Safe)" : "  (from CRONOS_ADMIN_SAFE)"}`,
  );
  console.log(
    `Relayer    : ${relayer}${usingDefaultRelayer ? "  (default known relayer)" : "  (from CRONOS_RELAYER)"}`,
  );
  console.log(`Mint cap   : ${capTokens} MAG / epoch  (${mintCapPerEpoch} wei)`);
  console.log(`Epoch len  : ${epochLength}s${epochLength === 0 ? "  (0 → contract defaults to 1 day)" : ""}\n`);

  if (balance === 0n) {
    throw new Error("Deployer has 0 CRO balance — fund it first");
  }

  // ─── Deploy ──────────────────────────────────────────────────────────────
  console.log("Deploying MAGCronosToken...");
  const Mag = await ethers.getContractFactory("MAGCronosToken");
  const mag = await Mag.deploy(admin, relayer, mintCapPerEpoch, epochLength);
  await mag.waitForDeployment();
  const addr = await mag.getAddress();
  console.log(`  → ${addr}`);

  // ─── Sanity read-back (the cap must bind from block 0) ───────────────────
  const onChainCap = await mag.mintCapPerEpoch();
  const onChainEpoch = await mag.epochLength();
  const onChainRelayer = await mag.currentRelayer();
  console.log(`\nRead-back:`);
  console.log(`  mintCapPerEpoch : ${ethers.formatEther(onChainCap)} MAG`);
  console.log(`  epochLength     : ${onChainEpoch}s`);
  console.log(`  currentRelayer  : ${onChainRelayer}`);
  if (onChainCap === 0n) {
    throw new Error("Post-deploy check failed: on-chain mintCapPerEpoch is 0 (uncapped)");
  }

  // ─── Persist ─────────────────────────────────────────────────────────────
  const result: MagCronosDeployment = {
    network: network.name,
    chainId,
    contract: "MAGCronosToken",
    address: addr,
    deployer: deployer.address,
    admin,
    relayer,
    mintCapPerEpoch: mintCapPerEpoch.toString(),
    mintCapPerEpochTokens: capTokens,
    epochLength,
    timestamp: new Date().toISOString(),
  };

  const outDir = path.join(__dirname, "..", "deployments-mag");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n");
  console.log(`\nDeployment record: ${outPath}`);

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`Gas spent  : ${ethers.formatEther(spent)} CRO\n`);

  // ─── Next steps ──────────────────────────────────────────────────────────
  console.log("─── NEXT STEPS (do NOT enable outbound yet) ───");
  console.log(`1. Repoint the relayer to the new token address:`);
  console.log(`   - set MAG_CRONOS_TOKEN=${addr} in the relayer env`);
  console.log(`   - lib/relayer/magCronosBridge.ts already uses the 5-arg relayerMint ABI`);
  console.log(`2. Fund the outbound treasury with MAG BEFORE enabling outbound`);
  console.log(`   (inbound mint works now; outbound release needs treasury liquidity).`);
  console.log(`3. If old MAGCronos had real supply: snapshot holders → migrate (confirm w/ owner).`);
  console.log(`4. Any cap change is a Safe batch (admin=Safe, deployer EOA cannot setMintCap):`);
  console.log(`   setMintCap(capPerEpoch, epochLength)`);
  console.log(`5. Verify on Cronoscan (4 constructor args):`);
  console.log(
    `   pnpm hardhat verify --network ${network.name} ${addr} ${admin} ${relayer} ${mintCapPerEpoch} ${epochLength}`,
  );
  console.log(`\nadmin=${admin}  relayer=${relayer}  cap=${mintCapPerEpoch}  epoch=${epochLength}\n`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
