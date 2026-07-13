/**
 * Sprint 9.7 — Deploy CreateTokenDispatcherV3 on a single chain.
 *
 * Differs from the Sprint 9.6 v2 deploy:
 *   - Constructor signature has a 5th argument: `_feeVault` (the EVM-wide
 *     Magneta FeeVault EOA, 0x68109132…d68b on every supported chain).
 *   - Reuses the existing OFT factories from `deployments-oft/<chain>.json`
 *     (Sprint 9.5 — no need to redeploy them).
 *   - Reads the per-chain Safe from
 *     `magneta-finance-contracts/deployments/<chain>.json` `gnosisSafe`.
 *   - Re-points both factories' `crossChainCreator` from the v2 dispatcher
 *     to the v3 dispatcher when the deployer still owns them. If they're
 *     already Safe-owned (factories transferred to Safe in Sprint 9.6),
 *     the script logs the calldata for a Safe Tx Builder batch instead.
 *   - Transfers v3 ownership to the per-chain Safe at the end.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy-create-token-dispatcher-v3.ts --network polygon
 *
 * Output: deployments-dispatcher-v3/<network>.json with the v3 address.
 */
import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { CHAIN_CONFIG } from "./chainConfig";

const FEE_VAULT_EVM = "0x68109132Ecf7540A0A983e1Aaa7DebC469d9d68b";

interface OFTRecord {
  network: string;
  chainId: string;
  factories: {
    MagnetaOFTStandardFactory: string;
    MagnetaOFTAutoLiquidityFactory: string;
  };
}

interface DispatcherV3Deployment extends OFTRecord {
  deployer: string;
  lzEndpoint: string;
  feeVault: string;
  timestamp: string;
  createTokenDispatcherV3: string;
  /** v2 address kept for audit — factories' crossChainCreator was re-pointed away. */
  v2OrphanDispatcher: string | null;
  safe: string;
  crossChainCreatorWired: { stdFactory: string; alFactory: string };
  ownershipTransfer: { stdFactory: string; alFactory: string; dispatcher: string };
}

function readChainSafe(networkName: string): string | null {
  const p = path.resolve(
    __dirname, "..", "..", "..", "..",
    "magneta-finance-contracts", "deployments", `${networkName}.json`,
  );
  if (!fs.existsSync(p)) return null;
  const j = JSON.parse(fs.readFileSync(p, "utf-8"));
  return j.gnosisSafe || null;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n── Sprint 9.7 — CreateTokenDispatcherV3 ──`);
  console.log(`Network    : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer   : ${deployer.address}`);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No chain config for chainId ${chainId}`);
  if (cfg.lzEndpoint === null) {
    console.log(`\n⚠ Skipping ${network.name} — no LZ V2 endpoint.`);
    return;
  }

  // OFT factories from Sprint 9.5
  const oftPath = path.join(__dirname, "..", "deployments-oft", `${network.name}.json`);
  if (!fs.existsSync(oftPath)) {
    throw new Error(`Missing ${oftPath}. Run deploy-oft-factories.ts on this network first.`);
  }
  const oft: OFTRecord = JSON.parse(fs.readFileSync(oftPath, "utf-8"));
  const stdFactoryAddr = oft.factories.MagnetaOFTStandardFactory;
  const alFactoryAddr  = oft.factories.MagnetaOFTAutoLiquidityFactory;

  // v2 dispatcher (the orphan-to-be) — for the audit record
  const v2Path = path.join(__dirname, "..", "deployments-dispatcher", `${network.name}.json`);
  let v2OrphanDispatcher: string | null = null;
  if (fs.existsSync(v2Path)) {
    const v2 = JSON.parse(fs.readFileSync(v2Path, "utf-8"));
    v2OrphanDispatcher = v2.createTokenDispatcher || null;
  }

  console.log(`OFT Std    : ${stdFactoryAddr}`);
  console.log(`OFT Al     : ${alFactoryAddr}`);
  console.log(`LZ endpoint: ${cfg.lzEndpoint}`);
  console.log(`FeeVault   : ${FEE_VAULT_EVM}`);
  console.log(`v2 orphan  : ${v2OrphanDispatcher || "(none)"}`);

  const safe = readChainSafe(network.name);
  if (!safe) {
    throw new Error(
      `No gnosisSafe in magneta-finance-contracts/deployments/${network.name}.json. ` +
      `Cannot transfer ownership to a known Safe — aborting.`,
    );
  }
  console.log(`Safe       : ${safe}\n`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance    : ${ethers.formatEther(balance)} native`);
  if (balance === 0n) throw new Error("Deployer balance is 0");

  // ─── Deploy v3 ─────────────────────────────────────────────────────────
  console.log("\nDeploying CreateTokenDispatcherV3...");
  const Dispatcher = await ethers.getContractFactory("CreateTokenDispatcherV3");
  const dispatcher = await Dispatcher.deploy(
    cfg.lzEndpoint,
    deployer.address,         // initial owner — transferred to Safe at the end
    stdFactoryAddr,
    alFactoryAddr,
    FEE_VAULT_EVM,
  );
  await dispatcher.waitForDeployment();
  const dispatcherAddr = await dispatcher.getAddress();
  console.log(`  → ${dispatcherAddr}`);

  // Sequential nonce-explicit sender (fast L2 RPCs race the built-in nonce
  // manager — same fix as Sprint 9.6 v2 deploy script).
  const sendOwned = async (label: string, fn: (nonce: number) => Promise<any>) => {
    const nonce = await deployer.getNonce("latest");
    const tx = await fn(nonce);
    await tx.wait();
    console.log(`  ✓ ${label} tx ${tx.hash}`);
    return tx.hash;
  };

  const factoryAbi = [
    "function setCrossChainCreator(address) external",
    "function crossChainCreator() view returns (address)",
    "function owner() view returns (address)",
    "function transferOwnership(address) external",
  ];
  const stdFactory = new ethers.Contract(stdFactoryAddr, factoryAbi, deployer);
  const alFactory  = new ethers.Contract(alFactoryAddr,  factoryAbi, deployer);

  // ─── Re-point factories' crossChainCreator to v3 ───────────────────────
  let stdTxHash = "";
  let alTxHash  = "";

  const stdOwner = await stdFactory.owner();
  if (stdOwner === deployer.address) {
    console.log("\nWiring StdFactory.setCrossChainCreator(v3)...");
    stdTxHash = await sendOwned("StdFactory.setCrossChainCreator",
      (n) => stdFactory.setCrossChainCreator(dispatcherAddr, { nonce: n }));
  } else {
    console.log(`\n⚠ StdFactory owner is ${stdOwner} (not deployer).`);
    console.log(`  → Add Safe batch tx: ${stdFactoryAddr}.setCrossChainCreator(${dispatcherAddr})`);
    stdTxHash = "(pending Safe)";
  }

  const alOwner = await alFactory.owner();
  if (alOwner === deployer.address) {
    console.log("Wiring AlFactory.setCrossChainCreator(v3)...");
    alTxHash = await sendOwned("AlFactory.setCrossChainCreator",
      (n) => alFactory.setCrossChainCreator(dispatcherAddr, { nonce: n }));
  } else {
    console.log(`⚠ AlFactory owner is ${alOwner} (not deployer).`);
    console.log(`  → Add Safe batch tx: ${alFactoryAddr}.setCrossChainCreator(${dispatcherAddr})`);
    alTxHash = "(pending Safe)";
  }

  // ─── Transfer dispatcher ownership to Safe (single-step Ownable) ───────
  const dispatcherAsCtl = new ethers.Contract(
    dispatcherAddr,
    ["function owner() view returns (address)", "function transferOwnership(address) external"],
    deployer,
  );
  let dispOwnerHash = "(already Safe-owned)";
  if ((await dispatcherAsCtl.owner()) === deployer.address) {
    console.log("\nTransferring CreateTokenDispatcherV3 ownership to Safe...");
    dispOwnerHash = await sendOwned("Dispatcher.transferOwnership",
      (n) => dispatcherAsCtl.transferOwnership(safe, { nonce: n }));
  }

  // ─── Persist deployment record ─────────────────────────────────────────
  const result: DispatcherV3Deployment = {
    ...oft,
    deployer: deployer.address,
    lzEndpoint: cfg.lzEndpoint,
    feeVault: FEE_VAULT_EVM,
    timestamp: new Date().toISOString(),
    createTokenDispatcherV3: dispatcherAddr,
    v2OrphanDispatcher,
    safe,
    crossChainCreatorWired: { stdFactory: stdTxHash, alFactory: alTxHash },
    ownershipTransfer: {
      stdFactory: "(unchanged — factories were already Safe-owned post-Sprint 9.6)",
      alFactory:  "(unchanged)",
      dispatcher: dispOwnerHash,
    },
  };

  const outDir = path.join(__dirname, "..", "deployments-dispatcher-v3");
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n");
  console.log(`\nDeployment record: ${outPath}`);

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`Gas spent : ${ethers.formatEther(spent)} native\n`);

  console.log("─── NEXT STEPS ───");
  console.log("1. After deploying on all canary chains, run:");
  console.log(`   pnpm hardhat run scripts/generatePeerWiringBatchesV3.ts`);
  console.log("2. If any factory was already Safe-owned, sign a Safe batch:");
  console.log(`   stdFactory.setCrossChainCreator(${dispatcherAddr})`);
  console.log(`   alFactory.setCrossChainCreator(${dispatcherAddr})`);
  console.log("3. Update lib/constants/gatewayChains.ts:");
  console.log(`     ${chainId}: { ..., createTokenDispatcher: '${dispatcherAddr}', ... }`);
  console.log("4. Verify on the block explorer:");
  console.log(`   pnpm hardhat verify --network ${network.name} ${dispatcherAddr} \\`);
  console.log(`     ${cfg.lzEndpoint} ${deployer.address} ${stdFactoryAddr} ${alFactoryAddr} ${FEE_VAULT_EVM}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
