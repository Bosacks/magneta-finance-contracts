/**
 * Full mainnet deployment of the Magneta DeFi + Cross-Chain stack.
 *
 * Deploys in order:
 *   1. Core DeFi (Pool, Swap, Lending, Factory, Bundler)
 *   2. Cross-chain (Gateway, BridgeOApp)
 *   3. Gateway modules (LP, Swap, TokenOps, TaxClaim)
 *   4. On-chain configuration (setModule, setFeeVault, addPauser, feeExempt)
 *
 * Peer registration and CCTP config require all chains deployed first —
 * use scripts/deploy/configPeers.ts after running this on every chain.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployAll.ts --network base
 *   pnpm hardhat run scripts/deploy/deployAll.ts --network arbitrum
 *   pnpm hardhat run scripts/deploy/deployAll.ts --network polygon
 *
 * Writes the result to deployments/<network>.json.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG, ChainConfig, FEE_VAULT, PAUSE_GUARDIAN, RELAYER_PAUSER } from "./chainConfig";

interface DeployResult {
  network: string;
  chainId: string;
  deployer: string;
  feeVault: string;
  pauseGuardian: string;
  timestamp: string;
  chainConfig: ChainConfig;
  contracts: Record<string, string>;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\nDeployer       : ${deployer.address}`);
  console.log(`Network        : ${network.name} (chainId ${chainId})`);
  console.log(`Balance        : ${ethers.formatEther(balance)} native`);
  console.log(`FeeVault       : ${FEE_VAULT}`);
  console.log(`PauseGuardian  : ${PAUSE_GUARDIAN}\n`);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) {
    throw new Error(`No chain config for chainId ${chainId}. Add it to CHAIN_CONFIG.`);
  }
  if (balance === 0n) {
    throw new Error("Deployer has 0 balance — fund it first");
  }

  // Deploy capability flags — each gates a group of dependent contracts.
  const deployCrossChain = cfg.lzEndpoint !== null && cfg.lzEid !== null;
  const deployRouterModules = cfg.defaultRouter !== null && cfg.usdc !== null;
  const deployTokenOps = cfg.usdc !== null;

  console.log("Deploy plan:");
  console.log(`  core DeFi        : yes`);
  console.log(`  Gateway + Bridge : ${deployCrossChain ? "yes" : "NO (no LZ endpoint)"}`);
  console.log(`  LP/Swap/TaxClaim : ${deployRouterModules ? "yes" : "NO (no router or USDC)"}`);
  console.log(`  TokenOps module  : ${deployTokenOps ? "yes" : "NO (no USDC)"}`);
  console.log("");

  const contracts: Record<string, string> = {};
  let step = 0;

  const log = (label: string, addr: string) => {
    step++;
    console.log(`  [${step}] ${label}: ${addr}`);
  };

  // ═══════════════════════════ CORE DEFI ═══════════════════════════════
  console.log("── Core DeFi ──");

  const Pool = await ethers.getContractFactory("MagnetaPool");
  const pool = await Pool.deploy(deployer.address);
  await pool.waitForDeployment();
  contracts.MagnetaPool = await pool.getAddress();
  log("MagnetaPool", contracts.MagnetaPool);

  const Swap = await ethers.getContractFactory("MagnetaSwap");
  const swap = await Swap.deploy(FEE_VAULT, contracts.MagnetaPool);
  await swap.waitForDeployment();
  contracts.MagnetaSwap = await swap.getAddress();
  log("MagnetaSwap", contracts.MagnetaSwap);

  const Lending = await ethers.getContractFactory("MagnetaLending");
  const lending = await Lending.deploy();
  await lending.waitForDeployment();
  contracts.MagnetaLending = await lending.getAddress();
  log("MagnetaLending", contracts.MagnetaLending);

  const Factory = await ethers.getContractFactory("MagnetaFactory");
  const factory = await Factory.deploy(contracts.MagnetaPool, deployer.address);
  await factory.waitForDeployment();
  contracts.MagnetaFactory = await factory.getAddress();
  log("MagnetaFactory", contracts.MagnetaFactory);

  // Bundler batches swaps through a UniV2 router (IUniswapV2Router02.WETH() /
  // swapExact*), so its router MUST be the chain's V2 router, NOT MagnetaSwap
  // (which is IMagnetaSwap, a different interface). feeRecipient = FeeVault.
  // Skip on router-less minimal chains (e.g. Berachain) — Bundler needs a V2 router.
  if (cfg.defaultRouter) {
    const Bundler = await ethers.getContractFactory("MagnetaBundler");
    const bundler = await Bundler.deploy(cfg.defaultRouter, FEE_VAULT);
    await bundler.waitForDeployment();
    contracts.MagnetaBundler = await bundler.getAddress();
    log("MagnetaBundler", contracts.MagnetaBundler);
  } else {
    console.log("  MagnetaBundler: SKIPPED (no V2 router on this chain)");
  }

  // ═══════════════════════ CROSS-CHAIN INFRA ══════════════════════════

  let gateway: any = null;

  if (deployCrossChain) {
    console.log("\n── Cross-chain (LayerZero) ──");

    let lzEndpoint: string;
    if (chainId === 31337) {
      const MockEndpoint = await ethers.getContractFactory("MockLayerZeroEndpoint");
      const mockEp = await MockEndpoint.deploy(cfg.lzEid!);
      await mockEp.waitForDeployment();
      lzEndpoint = await mockEp.getAddress();
      console.log(`  (hardhat) MockLayerZeroEndpoint: ${lzEndpoint}`);
    } else {
      lzEndpoint = ethers.getAddress(cfg.lzEndpoint!);
      console.log(`  LZ endpoint (from CHAIN_CONFIG): ${lzEndpoint}`);
    }

    const Gateway = await ethers.getContractFactory("MagnetaGateway");
    gateway = await Gateway.deploy(lzEndpoint, deployer.address, FEE_VAULT);
    await gateway.waitForDeployment();
    contracts.MagnetaGateway = await gateway.getAddress();
    log("MagnetaGateway", contracts.MagnetaGateway);

    const BridgeOApp = await ethers.getContractFactory("MagnetaBridgeOApp");
    const bridge = await BridgeOApp.deploy(lzEndpoint, deployer.address, FEE_VAULT, cfg.lzEid!);
    await bridge.waitForDeployment();
    contracts.MagnetaBridgeOApp = await bridge.getAddress();
    log("MagnetaBridgeOApp", contracts.MagnetaBridgeOApp);
  } else {
    console.log("\n── Cross-chain: SKIPPED (no LZ endpoint configured) ──");
  }

  // ═══════════════════════ GATEWAY MODULES ════════════════════════════

  if (gateway !== null) {
    console.log("\n── Gateway modules ──");

    // LPModule's constructor requires gateway.requiredDVNCount() >= MIN_DVN_QUORUM(2)
    // (anti single-DVN policy). Set the policy on the fresh Gateway BEFORE deploying
    // the modules, while the deployer is still owner.
    const setDvnTx = await gateway.setRequiredDVNCount(2);
    await setDvnTx.wait();
    console.log(`  ✓ Gateway requiredDVNCount = 2`);

    if (deployRouterModules) {
      const LPMod = await ethers.getContractFactory("LPModule");
      const lpModule = await LPMod.deploy(
        contracts.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!, contracts.MagnetaSwap
      );
      await lpModule.waitForDeployment();
      contracts.LPModule = await lpModule.getAddress();
      log("LPModule", contracts.LPModule);

      const SwapMod = await ethers.getContractFactory("SwapModule");
      const swapModule = await SwapMod.deploy(contracts.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!);
      await swapModule.waitForDeployment();
      contracts.SwapModule = await swapModule.getAddress();
      log("SwapModule", contracts.SwapModule);

      const TaxClaimMod = await ethers.getContractFactory("TaxClaimModule");
      const taxClaimModule = await TaxClaimMod.deploy(contracts.MagnetaGateway, cfg.defaultRouter!, cfg.usdc!);
      await taxClaimModule.waitForDeployment();
      contracts.TaxClaimModule = await taxClaimModule.getAddress();
      log("TaxClaimModule", contracts.TaxClaimModule);
    } else {
      console.log("  LPModule/SwapModule/TaxClaimModule: SKIPPED (no router or USDC)");
    }

    if (deployTokenOps) {
      const TokenOpsMod = await ethers.getContractFactory("TokenOpsModule");
      const tokenOpsModule = await TokenOpsMod.deploy(contracts.MagnetaGateway, cfg.usdc!);
      await tokenOpsModule.waitForDeployment();
      contracts.TokenOpsModule = await tokenOpsModule.getAddress();
      log("TokenOpsModule", contracts.TokenOpsModule);
    } else {
      console.log("  TokenOpsModule: SKIPPED (no USDC)");
    }
  }

  // ═══════════ SAVE ADDRESSES BEFORE CONFIG (resume-safe) ═════════════
  // If the config phase crashes (nonce lag, RPC hiccup), we still have the
  // deployed addresses on disk and can finish via scripts/deploy/configureOnly.ts.
  {
    const resumeResult: DeployResult = {
      network: network.name,
      chainId: chainId.toString(),
      deployer: deployer.address,
      feeVault: FEE_VAULT,
      pauseGuardian: PAUSE_GUARDIAN,
      timestamp: new Date().toISOString(),
      chainConfig: cfg,
      contracts,
    };
    const outPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(resumeResult, null, 2) + "\n");
    console.log(`\n  (addresses checkpointed to ${outPath})`);
  }

  // ═══════════════════════ ON-CHAIN CONFIG ════════════════════════════

  if (gateway !== null) {
    console.log("\n── Configuring Gateway ──");

    // OpType enum: 0=CREATE_LP, 1=REMOVE_LP, 2=BURN_LP, 3=CREATE_LP_AND_BUY,
    //   4=MINT, 5=UPDATE_METADATA, 6=FREEZE_ACCOUNT, 7=UNFREEZE_ACCOUNT,
    //   8=AUTO_FREEZE, 9=REVOKE_PERMISSION, 10=CLAIM_TAX_FEES, 11=SWAP_LOCAL, 12=SWAP_OUT
    const moduleMap: [number, string | undefined][] = [
      [0,  contracts.LPModule],
      [1,  contracts.LPModule],
      [2,  contracts.LPModule],
      [3,  contracts.LPModule],
      [4,  contracts.TokenOpsModule],
      [5,  contracts.TokenOpsModule],
      [6,  contracts.TokenOpsModule],
      [7,  contracts.TokenOpsModule],
      [8,  contracts.TokenOpsModule],
      [9,  contracts.TokenOpsModule],
      [10, contracts.TaxClaimModule],
      [11, contracts.SwapModule],
      [12, contracts.SwapModule],
      // 16 = AUTO_FREEZE_RULE_SET (A2/A3) → TokenOpsModule. Ops 13 (CREATE_TOKEN →
      // TokenCreationModule) and 14/15 (POOL_FEE_COMPOUND/MIGRATE_LP → LPAtomicModule)
      // are wired by their own deploy scripts (deployTokenCreation.ts / the atomic
      // module deploy), since deployAll does not deploy those modules.
      [16, contracts.TokenOpsModule],
    ];

    let registered = 0;
    for (const [op, mod] of moduleMap) {
      if (!mod) continue;
      const tx = await gateway.setModule(op, mod);
      await tx.wait();
      registered++;
    }
    console.log(`  ✓ ${registered} modules registered on Gateway`);

    if (cfg.usdc) {
      const setUsdcTx = await gateway.setUsdc(cfg.usdc);
      await setUsdcTx.wait();
      console.log(`  ✓ Gateway USDC set: ${cfg.usdc}`);
    } else {
      console.log(`  · Gateway USDC: SKIPPED (none configured)`);
    }

    const setGuardianGw = await gateway.addPauser(PAUSE_GUARDIAN);
    await setGuardianGw.wait();
    console.log(`  ✓ Gateway pauser added: ${PAUSE_GUARDIAN}`);
    if (RELAYER_PAUSER) {
      await (await gateway.addPauser(RELAYER_PAUSER)).wait();
      console.log(`  ✓ Gateway pauser added (Defender Relayer): ${RELAYER_PAUSER}`);
    }

    if (contracts.LPModule) {
      const setExemptTx = await swap.setFeeExempt(contracts.LPModule, true);
      await setExemptTx.wait();
      console.log(`  ✓ MagnetaSwap: LPModule fee-exempt`);
    }
  }

  const setGuardianSwap = await swap.addPauser(PAUSE_GUARDIAN);
  await setGuardianSwap.wait();
  console.log(`  ✓ MagnetaSwap pauser added: ${PAUSE_GUARDIAN}`);
  if (RELAYER_PAUSER) {
    await (await swap.addPauser(RELAYER_PAUSER)).wait();
    console.log(`  ✓ MagnetaSwap pauser added (Defender Relayer): ${RELAYER_PAUSER}`);
  }

  if (cfg.usdc) {
    const whitelistTx = await swap.setWhitelistedToken(cfg.usdc, true);
    await whitelistTx.wait();
    console.log(`  ✓ MagnetaSwap: USDC whitelisted`);
  }

  // ═══════════════════════ WRITE DEPLOYMENT ═══════════════════════════

  const result: DeployResult = {
    network: network.name,
    chainId: chainId.toString(),
    deployer: deployer.address,
    feeVault: FEE_VAULT,
    pauseGuardian: PAUSE_GUARDIAN,
    timestamp: new Date().toISOString(),
    chainConfig: cfg,
    contracts,
  };

  const outPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + "\n");

  console.log(`\nDeployment saved to ${outPath}`);
  console.log("\nAll contracts:");
  for (const [name, addr] of Object.entries(contracts)) {
    console.log(`  ${name}: ${addr}`);
  }

  const spent = balance - (await ethers.provider.getBalance(deployer.address));
  console.log(`\nGas spent: ${ethers.formatEther(spent)} native`);

  console.log("\n══════════════════════════════════════════════════");
  console.log("NEXT STEPS (after deploying on ALL chains):");
  console.log("══════════════════════════════════════════════════");
  console.log("1. Run configPeers.ts to register LZ peers between all gateways");
  console.log("2. Run configCctp.ts to set CCTP messenger + domain mappings");
  console.log("3. Verify contracts:");
  console.log(`   pnpm hardhat verify --network ${network.name} <ADDRESS> <ARGS>`);
  console.log("4. Whitelist tokens on MagnetaSwap: setWhitelistedToken()");
  console.log("5. Set gatewayLive: true in chain-service chains.ts");
  console.log("6. Fund relayer: 0x2B898219Ce1dbEb3ECd3956223b9Ff0C0B126aC2");
  console.log("══════════════════════════════════════════════════\n");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
