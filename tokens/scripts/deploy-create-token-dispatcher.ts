/**
 * Sprint 9.6 — Deploy CreateTokenDispatcher on a single chain.
 *
 * Reads the OFT factory addresses from the local `deployments-oft/<network>.json`
 * (written by `deploy-oft-factories.ts`), deploys the dispatcher with both
 * factories baked in at construction, then re-points the factories'
 * `crossChainCreator` slot to the dispatcher (replacing the now-orphaned
 * TokenCreationModule from the original Sprint 9.5 plan).
 *
 *   Usage:
 *     pnpm hardhat run scripts/deploy-create-token-dispatcher.ts --network polygon
 *
 *   After running on every chain:
 *     1. Generate peer-wiring batches with the standalone helper
 *        (one batch per chain — pattern mirrors the Gateway peer wires).
 *     2. Sign each batch via Safe Tx Builder.
 *     3. Update `lib/constants/gatewayChains.ts` with the deployed addresses.
 */
import { ethers, network, run } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { CHAIN_CONFIG } from "./chainConfig";

interface OFTRecord {
  network: string;
  chainId: string;
  factories: {
    MagnetaOFTStandardFactory: string;
    MagnetaOFTAutoLiquidityFactory: string;
  };
}

interface DispatcherDeployment extends OFTRecord {
  deployer: string;
  lzEndpoint: string;
  timestamp: string;
  createTokenDispatcher: string;
  safe: string;
  /** crossChainCreator setter calls executed by the deployer. */
  crossChainCreatorWired: { stdFactory: string; alFactory: string };
}

/**
 * Reads the per-chain Safe address from the sibling contracts repo's
 * `deployments/<chain>.json`. Magneta uses 3 different Safes:
 *   - 0x4AeA…EC2F   on Polygon + Arbitrum
 *   - 0xC4c96aF…   on 14 standard chains
 *   - 0x40ea29…b297 on 4 in-house Safes (Abstract, Cronos, Flare, Sei)
 * Hardcoding any one of these blanket-style breaks 2/3 of the chains
 * (lesson learned 2026-04-30 on Gnosis canary — bricked dispatcher).
 */
function readChainSafe(networkName: string): string | null {
  const contractsDeployPath = path.resolve(
    __dirname, "..", "..", "..", "..",
    "magneta-finance-contracts", "deployments", `${networkName}.json`,
  );
  if (!fs.existsSync(contractsDeployPath)) return null;
  const j = JSON.parse(fs.readFileSync(contractsDeployPath, "utf-8"));
  return j.gnosisSafe || null;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n── Sprint 9.6 — CreateTokenDispatcher ──`);
  console.log(`Network    : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer   : ${deployer.address}`);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No chain config for chainId ${chainId}`);
  if (cfg.lzEndpoint === null) {
    console.log(`\n⚠ Skipping ${network.name} — no LZ V2 endpoint (Cronos pattern).`);
    return;
  }

  // Load OFT factory addresses produced by deploy-oft-factories.ts
  const oftDir = path.join(__dirname, "..", "deployments-oft");
  const oftPath = path.join(oftDir, `${network.name}.json`);
  if (!fs.existsSync(oftPath)) {
    throw new Error(
      `Missing ${oftPath}. Run deploy-oft-factories.ts on this network first.`,
    );
  }
  const oft: OFTRecord = JSON.parse(fs.readFileSync(oftPath, "utf-8"));
  const stdFactoryAddr = oft.factories.MagnetaOFTStandardFactory;
  const alFactoryAddr  = oft.factories.MagnetaOFTAutoLiquidityFactory;
  console.log(`OFT Std    : ${stdFactoryAddr}`);
  console.log(`OFT Al     : ${alFactoryAddr}`);
  console.log(`LZ endpoint: ${cfg.lzEndpoint}\n`);

  // Per-chain Safe — CRITICAL: do not hardcode globally.
  const safe = readChainSafe(network.name);
  if (!safe) {
    throw new Error(
      `No gnosisSafe in magneta-finance-contracts/deployments/${network.name}.json. ` +
      `Cannot transfer ownership to a known Safe — aborting to avoid bricking the dispatcher.`,
    );
  }
  console.log(`Safe       : ${safe}\n`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance    : ${ethers.formatEther(balance)} native`);
  if (balance === 0n) throw new Error("Deployer balance is 0");

  // ─── Deploy dispatcher ──────────────────────────────────────────────────
  console.log("\nDeploying CreateTokenDispatcher...");
  const Dispatcher = await ethers.getContractFactory("CreateTokenDispatcher");
  const dispatcher = await Dispatcher.deploy(
    cfg.lzEndpoint,
    deployer.address,         // initial owner — transferred to Safe later via setter or 2step
    stdFactoryAddr,
    alFactoryAddr,
  );
  await dispatcher.waitForDeployment();
  const dispatcherAddr = await dispatcher.getAddress();
  console.log(`  → ${dispatcherAddr}`);

  // ─── Re-point factories' crossChainCreator to the dispatcher ─────────────
  // Factories are still owned by the deployer at this point on chains where
  // Sprint 9.5 Step 2 finished cleanly (see infra_sprint_9_5_deploy_runbook.md).
  // If the Safe already accepted ownership, the deployer call reverts and
  // the user must re-issue this from the Safe instead (Tx Builder).
  // ABI must include `transferOwnership` — used in the next section. Forgetting
  // it crashed the parallel rollout 2026-04-30 with a TypeError after the
  // setCrossChainCreator txs already landed (recovery via finish script).
  const factoryAbi = [
    "function setCrossChainCreator(address) external",
    "function crossChainCreator() view returns (address)",
    "function owner() view returns (address)",
    "function transferOwnership(address) external",
  ];
  const stdFactory = new ethers.Contract(stdFactoryAddr, factoryAbi, deployer);
  const alFactory  = new ethers.Contract(alFactoryAddr,  factoryAbi, deployer);

  // Sequential nonce-explicit sender for fast chains (arbitrum, optimism, base
  // saw `nonce too low` races when ethers' built-in nonce manager fell behind
  // the chain head — see 2026-04-30 rollout logs). Fetching the latest nonce
  // before each tx and passing it explicitly serializes everything.
  const sendOwned = async (label: string, fn: (nonce: number) => Promise<any>) => {
    const nonce = await deployer.getNonce("latest");
    const tx = await fn(nonce);
    await tx.wait();
    console.log(`  ✓ ${label} tx ${tx.hash}`);
    return tx.hash;
  };

  let stdTxHash = "";
  let alTxHash = "";

  const stdOwner = await stdFactory.owner();
  const stdCcc = await stdFactory.crossChainCreator();
  if (stdCcc.toLowerCase() === dispatcherAddr.toLowerCase()) {
    console.log(`\n✓ StdFactory.crossChainCreator already = dispatcher`);
    stdTxHash = "(already wired)";
  } else if (stdOwner === deployer.address) {
    console.log("\nWiring StdFactory.setCrossChainCreator(dispatcher)...");
    stdTxHash = await sendOwned("StdFactory.setCrossChainCreator",
      (n) => stdFactory.setCrossChainCreator(dispatcherAddr, { nonce: n }));
  } else {
    console.log(`\n⚠ StdFactory owner is ${stdOwner} (not deployer).`);
    console.log(`  → Add a Safe batch tx: stdFactory.setCrossChainCreator(${dispatcherAddr})`);
    stdTxHash = "(pending Safe)";
  }

  const alOwner = await alFactory.owner();
  const alCcc = await alFactory.crossChainCreator();
  if (alCcc.toLowerCase() === dispatcherAddr.toLowerCase()) {
    console.log(`✓ AlFactory.crossChainCreator already = dispatcher`);
    alTxHash = "(already wired)";
  } else if (alOwner === deployer.address) {
    console.log("Wiring AlFactory.setCrossChainCreator(dispatcher)...");
    alTxHash = await sendOwned("AlFactory.setCrossChainCreator",
      (n) => alFactory.setCrossChainCreator(dispatcherAddr, { nonce: n }));
  } else {
    console.log(`⚠ AlFactory owner is ${alOwner} (not deployer).`);
    console.log(`  → Add a Safe batch tx: alFactory.setCrossChainCreator(${dispatcherAddr})`);
    alTxHash = "(pending Safe)";
  }

  // ─── Re-route factory ownership to the correct Safe ─────────────────────
  // The deployer owns the factories at this point (Sprint 9.5 pattern). We
  // transfer pendingOwner directly so the Safe batch v2 can accept it.
  let stdOwnerTxHash = "(skipped — not deployer)";
  let alOwnerTxHash  = "(skipped — not deployer)";
  if ((await stdFactory.owner()) === deployer.address) {
    console.log("\nTransferring StdFactory ownership to Safe (Ownable2Step pending)...");
    stdOwnerTxHash = await sendOwned("StdFactory.transferOwnership",
      (n) => stdFactory.transferOwnership(safe, { nonce: n }));
  }
  if ((await alFactory.owner()) === deployer.address) {
    console.log("Transferring AlFactory ownership to Safe (Ownable2Step pending)...");
    alOwnerTxHash = await sendOwned("AlFactory.transferOwnership",
      (n) => alFactory.transferOwnership(safe, { nonce: n }));
  }

  // ─── Transfer dispatcher ownership to Safe (single-step, instant) ───────
  // Wrap in ethers.Contract with a minimal ABI: the typechain-typed instance
  // returned by ContractFactory.deploy() doesn't expose `owner` to the
  // host project's tsc (typechain-types is only built inside the hardhat
  // workspace, not the Next.js root).
  const dispatcherAsCtl = new ethers.Contract(
    dispatcherAddr,
    ["function owner() view returns (address)", "function transferOwnership(address) external"],
    deployer,
  );
  let dispOwnerHash = "(already Safe-owned)";
  const dispCurrentOwner = await dispatcherAsCtl.owner();
  if (dispCurrentOwner === deployer.address) {
    console.log("\nTransferring CreateTokenDispatcher ownership to Safe (single-step)...");
    dispOwnerHash = await sendOwned("Dispatcher.transferOwnership",
      (n) => dispatcherAsCtl.transferOwnership(safe, { nonce: n }));
  }

  // ─── Persist deployment record ──────────────────────────────────────────
  const result: DispatcherDeployment = {
    ...oft,
    deployer: deployer.address,
    lzEndpoint: cfg.lzEndpoint,
    timestamp: new Date().toISOString(),
    createTokenDispatcher: dispatcherAddr,
    safe,
    crossChainCreatorWired: {
      stdFactory: stdTxHash,
      alFactory:  alTxHash,
    },
  };

  const outDir = path.join(__dirname, "..", "deployments-dispatcher");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n");
  console.log(`\nDeployment record: ${outPath}`);

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`Gas spent : ${ethers.formatEther(spent)} native\n`);

  console.log("─── NEXT STEPS ───");
  console.log("1. Transfer dispatcher ownership to Safe (single-step Ownable):");
  console.log(`   cast send --rpc-url $RPC --private-key $PK \\`);
  console.log(`     ${dispatcherAddr} 'transferOwnership(address)' <SAFE_ADDRESS>`);
  console.log("2. Once all chains are deployed, generate peer wiring batches.");
  console.log("3. Update lib/constants/gatewayChains.ts with the dispatcher address:");
  console.log(`     ${chainId}: { ..., createTokenDispatcher: '${dispatcherAddr}', ... }`);
  console.log("4. Verify on the block explorer (chainid prefix in apiURL):");
  console.log(`   pnpm hardhat verify --network ${network.name} ${dispatcherAddr} \\`);
  console.log(`     ${cfg.lzEndpoint} ${deployer.address} ${stdFactoryAddr} ${alFactoryAddr}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
