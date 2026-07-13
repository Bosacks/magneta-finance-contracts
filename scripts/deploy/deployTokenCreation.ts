/**
 * Sprint 3 Step 2 — Deploy TokenCreationModule + EOA-wire + emit Safe batch.
 *
 * Prerequisite: Step 1 already executed on this chain (factories deployed
 * via `magneta-finance-tokens/contracts/solidity/scripts/deploy-oft-factories.ts`).
 *
 * What this script does:
 *   1. Reads the OFT factory addresses from the tokens repo
 *      (deployments-oft/<network>.json).
 *   2. Reads the existing chain deployment (deployments/<network>.json) to
 *      get the Gateway address + the chain's Safe address.
 *   3. Deploys `TokenCreationModule(gateway, factoryStd, factoryAl)`.
 *   4. EOA-wires what the deployer can do alone:
 *        - factoryStd.setCrossChainCreator(module)
 *        - factoryAl.setCrossChainCreator(module)
 *        - factoryStd.transferOwnership(safe)   [pending — Safe must accept]
 *        - factoryAl.transferOwnership(safe)    [pending — Safe must accept]
 *        - module.transferOwnership(safe)        [single-step — instant]
 *   5. Generates a Safe Tx Builder batch JSON for the Safe-required steps:
 *        - factoryStd.acceptOwnership()
 *        - factoryAl.acceptOwnership()
 *        - gateway.setModule(CREATE_TOKEN, module)
 *      → written to scripts/safe/<network>-OFTSetup-batch.json
 *   6. Updates deployments/<network>.json with the 3 new addresses
 *      (MagnetaOFTStandardFactory, MagnetaOFTAutoLiquidityFactory,
 *      TokenCreationModule).
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployTokenCreation.ts --network base
 *
 * Skip Cronos automatically (no LZ endpoint = no Gateway = nothing to wire).
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";
import { CHAIN_CONFIG } from "./chainConfig";

// OpType.CREATE_TOKEN = index 13 in the enum (0-indexed, last entry as of Sprint 2)
const OP_CREATE_TOKEN = 13;

// Path to the tokens repo's OFT deployments folder (sibling repo)
const OFT_DEPLOYMENTS_DIR = path.resolve(
  __dirname, "..", "..", "..",
  "magneta-finance-tokens", "contracts", "solidity", "deployments-oft",
);

const REPO_ROOT      = path.join(__dirname, "..", "..");
const DEPLOY_DIR     = path.join(REPO_ROOT, "deployments");
const SAFE_BATCH_DIR = path.join(REPO_ROOT, "scripts", "safe");

interface OFTRecord {
  network: string;
  chainId: string;
  factories: {
    MagnetaOFTStandardFactory: string;
    MagnetaOFTAutoLiquidityFactory: string;
  };
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n── Sprint 3 Step 2 — TokenCreationModule + wiring ──`);
  console.log(`Network    : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer   : ${deployer.address}`);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No chain config for chainId ${chainId}`);
  if (cfg.lzEndpoint === null) {
    console.log(`\n⚠ Skipping ${network.name} — no LZ V2 endpoint. Use Sprint 5 Relayer instead.`);
    return;
  }

  // ─── Load OFT factory addresses from Step 1 ─────────────────────────────
  const oftPath = path.join(OFT_DEPLOYMENTS_DIR, `${network.name}.json`);
  if (!fs.existsSync(oftPath)) {
    throw new Error(
      `Missing ${oftPath}. Run Step 1 first:\n` +
      `  cd ../magneta-finance-tokens/contracts/solidity\n` +
      `  pnpm hardhat run scripts/deploy-oft-factories.ts --network ${network.name}`,
    );
  }
  const oft: OFTRecord = JSON.parse(fs.readFileSync(oftPath, "utf-8"));
  const factoryStdAddr = oft.factories.MagnetaOFTStandardFactory;
  const factoryAlAddr  = oft.factories.MagnetaOFTAutoLiquidityFactory;
  console.log(`OFT Std    : ${factoryStdAddr}`);
  console.log(`OFT Al     : ${factoryAlAddr}`);

  // ─── Load chain deployment (gateway + safe + tokenOpsModule) ────────────
  const chainPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  if (!fs.existsSync(chainPath)) {
    throw new Error(`Missing ${chainPath}. Run deployAll.ts first.`);
  }
  const chainDeploy = JSON.parse(fs.readFileSync(chainPath, "utf-8"));
  const gatewayAddr  = chainDeploy.contracts?.MagnetaGateway;
  const safeAddr     = chainDeploy.gnosisSafe;
  const tokenOpsAddr = chainDeploy.contracts?.TokenOpsModule;
  if (!gatewayAddr) throw new Error(`No MagnetaGateway in ${chainPath}`);
  if (!safeAddr)    throw new Error(`No gnosisSafe in ${chainPath}`);
  if (!tokenOpsAddr) {
    console.warn(`⚠ No TokenOpsModule in ${chainPath} — tokens will be created but MINT/FREEZE etc. will revert with TokenNotRegistered until a registerByTokenOwner call lands.`);
  }
  console.log(`Gateway    : ${gatewayAddr}`);
  console.log(`Safe       : ${safeAddr}`);
  console.log(`TokenOps   : ${tokenOpsAddr ?? '(missing — see warning)'}\n`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance    : ${ethers.formatEther(balance)} native\n`);
  if (balance === 0n) throw new Error("Deployer balance is 0");

  // ─── Deploy TokenCreationModule ─────────────────────────────────────────
  console.log("Deploying TokenCreationModule...");
  const Module = await ethers.getContractFactory("TokenCreationModule");
  const module_ = await Module.deploy(gatewayAddr, factoryStdAddr, factoryAlAddr);
  await module_.waitForDeployment();
  const moduleAddr = await module_.getAddress();
  console.log(`  → ${moduleAddr}\n`);

  // ─── EOA-wire factories (deployer still owns them) ──────────────────────
  // We're talking to the factory contracts in the sibling repo via ABI only.
  const stdFactoryAbi = [
    "function setCrossChainCreator(address) external",
    "function setTokenOpsModule(address) external",
    "function transferOwnership(address) external",
    "function owner() view returns (address)",
  ];
  // AutoLiquidity factory has no tokenOpsModule (no MINT/FREEZE surface) —
  // restrict its ABI to keep accidental calls out.
  const alFactoryAbi = [
    "function setCrossChainCreator(address) external",
    "function transferOwnership(address) external",
    "function owner() view returns (address)",
  ];

  const stdFactory = new ethers.Contract(factoryStdAddr, stdFactoryAbi, deployer);
  const alFactory  = new ethers.Contract(factoryAlAddr,  alFactoryAbi, deployer);

  // Sanity: deployer owns both factories
  const stdOwner = await stdFactory.owner();
  const alOwner  = await alFactory.owner();
  if (stdOwner !== deployer.address) throw new Error(`StdFactory owner is ${stdOwner}, not deployer`);
  if (alOwner  !== deployer.address) throw new Error(`AlFactory owner is ${alOwner}, not deployer`);

  console.log("Wiring StdFactory.setCrossChainCreator(module)...");
  let tx = await stdFactory.setCrossChainCreator(moduleAddr);
  await tx.wait();
  console.log(`  ✓ tx ${tx.hash}`);

  // Sprint 9.5 — bake TokenOpsModule into every future Standard OFT. Without
  // this, tokens created cross-chain are owned by the user but the module
  // can't call mint/blacklist/etc on them, breaking Sprint 7 wallet flows.
  if (tokenOpsAddr) {
    console.log("Wiring StdFactory.setTokenOpsModule(...)...");
    tx = await stdFactory.setTokenOpsModule(tokenOpsAddr);
    await tx.wait();
    console.log(`  ✓ tx ${tx.hash}`);
  }

  console.log("Wiring AlFactory.setCrossChainCreator(module)...");
  tx = await alFactory.setCrossChainCreator(moduleAddr);
  await tx.wait();
  console.log(`  ✓ tx ${tx.hash}`);
  // AutoLiquidity tokens have no MINT/FREEZE surface — no tokenOpsModule to wire.

  console.log("Transferring StdFactory ownership to Safe (pending — Safe must accept)...");
  tx = await stdFactory.transferOwnership(safeAddr);
  await tx.wait();
  console.log(`  ✓ tx ${tx.hash}`);

  console.log("Transferring AlFactory ownership to Safe (pending — Safe must accept)...");
  tx = await alFactory.transferOwnership(safeAddr);
  await tx.wait();
  console.log(`  ✓ tx ${tx.hash}`);

  // Wire tokenOpsModule BEFORE transferring ownership — once Safe owns it,
  // any further setter requires a multisig batch. Single-step Ownable here
  // (not Ownable2Step), so transferOwnership is final.
  if (tokenOpsAddr) {
    console.log("Wiring TokenCreationModule.setTokenOpsModule(...)...");
    tx = await module_.setTokenOpsModule(tokenOpsAddr);
    await tx.wait();
    console.log(`  ✓ tx ${tx.hash}`);
  }

  console.log("Transferring TokenCreationModule ownership to Safe (instant)...");
  tx = await module_.transferOwnership(safeAddr);
  await tx.wait();
  console.log(`  ✓ tx ${tx.hash}\n`);

  // ─── Generate Safe batch for the steps the EOA can't do ─────────────────
  const batch = {
    version: "1.0",
    chainId: chainId.toString(),
    createdAt: Date.now(),
    meta: {
      name: `Magneta — OFT setup batch (${network.name})`,
      description:
        `Sprint 3 wiring: accept ownership of MagnetaOFTStandardFactory + ` +
        `MagnetaOFTAutoLiquidityFactory (Ownable2Step) and register ` +
        `TokenCreationModule with the Gateway under OpType.CREATE_TOKEN. ` +
        `After this batch, users can call Gateway.executeOperation(CREATE_TOKEN, ...) ` +
        `or sendFanOut to deploy OFT tokens cross-chain.`,
      txBuilderVersion: "1.17.0",
      createdFromSafeAddress: safeAddr,
      createdFromOwnerAddress: "",
    },
    transactions: [
      {
        to: factoryStdAddr,
        value: "0",
        data: null,
        contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
        contractInputsValues: {},
      },
      {
        to: factoryAlAddr,
        value: "0",
        data: null,
        contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
        contractInputsValues: {},
      },
      {
        to: gatewayAddr,
        value: "0",
        data: null,
        contractMethod: {
          inputs: [
            { internalType: "uint8",   name: "op",     type: "uint8"   },
            { internalType: "address", name: "module", type: "address" },
          ],
          name: "setModule",
          payable: false,
        },
        contractInputsValues: {
          op:     String(OP_CREATE_TOKEN),
          module: moduleAddr,
        },
      },
    ],
  };

  fs.mkdirSync(SAFE_BATCH_DIR, { recursive: true });
  const batchPath = path.join(SAFE_BATCH_DIR, `${network.name}-OFTSetup-batch.json`);
  fs.writeFileSync(batchPath, JSON.stringify(batch, null, 2) + "\n");
  console.log(`Safe batch : ${path.relative(REPO_ROOT, batchPath)} (3 tx)\n`);

  // ─── Update deployments/<chain>.json with the new addresses ─────────────
  chainDeploy.contracts.MagnetaOFTStandardFactory = factoryStdAddr;
  chainDeploy.contracts.MagnetaOFTAutoLiquidityFactory = factoryAlAddr;
  chainDeploy.contracts.TokenCreationModule = moduleAddr;
  chainDeploy.tokenCreationDeployedAt = new Date().toISOString();
  fs.writeFileSync(chainPath, JSON.stringify(chainDeploy, null, 2) + "\n");
  console.log(`Updated    : ${path.relative(REPO_ROOT, chainPath)}\n`);

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`Gas spent  : ${ethers.formatEther(spent)} native\n`);

  console.log("─── NEXT STEPS ───");
  console.log("1. Sign + execute the Safe batch:");
  console.log(`   ${path.relative(REPO_ROOT, batchPath)}`);
  console.log("   - Canonical/legacy Safes: drag-drop in Safe Tx Builder");
  console.log("   - In-house Safe (abstract/flare/sei): use scripts/safe/inhouse/execBatch.ts");
  console.log("2. Verify contracts on Etherscan:");
  console.log(`   pnpm hardhat verify --network ${network.name} ${moduleAddr} ${gatewayAddr} ${factoryStdAddr} ${factoryAlAddr}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
