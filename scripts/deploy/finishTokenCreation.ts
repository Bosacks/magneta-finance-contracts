/**
 * Sprint 9.5 recovery — finish a partial deployTokenCreation.ts run.
 *
 * Use case: deployTokenCreation.ts hit a "nonce too low" mid-run after the
 * module + 3 wirings landed but before the 3 transferOwnership calls. This
 * script picks up from there using addresses passed as env vars (so we don't
 * re-deploy the module and orphan it):
 *
 *   FINISH_MODULE=0x...   (TokenCreationModule address from the failed run)
 *   FINISH_STD=0x...      (Standard factory)
 *   FINISH_AL=0x...       (AutoLiquidity factory)
 *
 * Steps performed:
 *   1. factory.transferOwnership(safe) on both factories (Ownable2Step pending)
 *   2. module.transferOwnership(safe) (single-step Ownable, instant)
 *   3. Generate Safe batch JSON (3 tx: 2× acceptOwnership + setModule(13, m))
 *   4. Update deployments/<chain>.json with the 3 addresses
 *
 * Usage:
 *   FINISH_MODULE=0x... FINISH_STD=0x... FINISH_AL=0x... \
 *     pnpm hardhat run scripts/deploy/finishTokenCreation.ts --network polygon
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

const OP_CREATE_TOKEN = 13;
const REPO_ROOT      = path.join(__dirname, "..", "..");
const DEPLOY_DIR     = path.join(REPO_ROOT, "deployments");
const SAFE_BATCH_DIR = path.join(REPO_ROOT, "scripts", "safe");

async function main() {
  const moduleAddr     = process.env.FINISH_MODULE;
  const factoryStdAddr = process.env.FINISH_STD;
  const factoryAlAddr  = process.env.FINISH_AL;
  if (!moduleAddr || !factoryStdAddr || !factoryAlAddr) {
    throw new Error("Set FINISH_MODULE, FINISH_STD, FINISH_AL env vars");
  }

  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n── Sprint 9.5 — finish deployTokenCreation ──`);
  console.log(`Network    : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer   : ${deployer.address}`);
  console.log(`Module     : ${moduleAddr}`);
  console.log(`StdFactory : ${factoryStdAddr}`);
  console.log(`AlFactory  : ${factoryAlAddr}`);

  const chainPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  if (!fs.existsSync(chainPath)) throw new Error(`Missing ${chainPath}`);
  const chainDeploy = JSON.parse(fs.readFileSync(chainPath, "utf-8"));
  const gatewayAddr = chainDeploy.contracts?.MagnetaGateway;
  const safeAddr    = chainDeploy.gnosisSafe;
  if (!gatewayAddr || !safeAddr) throw new Error("Missing gateway or safe in deployments");

  console.log(`Gateway    : ${gatewayAddr}`);
  console.log(`Safe       : ${safeAddr}\n`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance    : ${ethers.formatEther(balance)} native\n`);

  // Wait a few seconds to let the node's nonce catch up to chain state.
  console.log("Waiting 5s for nonce sync...");
  await new Promise((r) => setTimeout(r, 5000));

  // ─── transferOwnership on both factories + module ────────────────────────
  const ownableAbi = [
    "function transferOwnership(address) external",
    "function owner() view returns (address)",
  ];
  const stdFactory = new ethers.Contract(factoryStdAddr, ownableAbi, deployer);
  const alFactory  = new ethers.Contract(factoryAlAddr,  ownableAbi, deployer);
  const module_    = new ethers.Contract(moduleAddr,     ownableAbi, deployer);

  // Sanity: are these still owned by deployer? (idempotency check)
  const stdOwner = await stdFactory.owner();
  const alOwner  = await alFactory.owner();
  const modOwner = await module_.owner();

  if (stdOwner === deployer.address) {
    console.log("Transferring StdFactory ownership to Safe...");
    let tx = await stdFactory.transferOwnership(safeAddr);
    await tx.wait();
    console.log(`  ✓ tx ${tx.hash}`);
  } else {
    console.log(`StdFactory ownership already transferred (current owner: ${stdOwner})`);
  }

  if (alOwner === deployer.address) {
    console.log("Transferring AlFactory ownership to Safe...");
    let tx = await alFactory.transferOwnership(safeAddr);
    await tx.wait();
    console.log(`  ✓ tx ${tx.hash}`);
  } else {
    console.log(`AlFactory ownership already transferred (current owner: ${alOwner})`);
  }

  if (modOwner === deployer.address) {
    console.log("Transferring TokenCreationModule ownership to Safe (instant)...");
    let tx = await module_.transferOwnership(safeAddr);
    await tx.wait();
    console.log(`  ✓ tx ${tx.hash}\n`);
  } else {
    console.log(`Module ownership already transferred (current owner: ${modOwner})\n`);
  }

  // ─── Generate Safe batch ────────────────────────────────────────────────
  const batch = {
    version: "1.0",
    chainId: chainId.toString(),
    createdAt: Date.now(),
    meta: {
      name: `Magneta — OFT setup batch (${network.name})`,
      description:
        `Sprint 9.5 wiring: accept ownership of MagnetaOFTStandardFactory + ` +
        `MagnetaOFTAutoLiquidityFactory and register TokenCreationModule with ` +
        `the Gateway under OpType.CREATE_TOKEN.`,
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

  // ─── Update deployments JSON ────────────────────────────────────────────
  chainDeploy.contracts.MagnetaOFTStandardFactory = factoryStdAddr;
  chainDeploy.contracts.MagnetaOFTAutoLiquidityFactory = factoryAlAddr;
  chainDeploy.contracts.TokenCreationModule = moduleAddr;
  chainDeploy.tokenCreationDeployedAt = new Date().toISOString();
  fs.writeFileSync(chainPath, JSON.stringify(chainDeploy, null, 2) + "\n");
  console.log(`Updated    : ${path.relative(REPO_ROOT, chainPath)}\n`);

  console.log("─── NEXT STEPS ───");
  console.log("1. Sign + execute the Safe batch:");
  console.log(`   ${path.relative(REPO_ROOT, batchPath)}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
