/**
 * Deploy the LP-atomic stack on a chain where it is missing:
 *   1. MagnetaRouterRegistry(admin = deployer) + allowRouter(cfg.defaultRouter)
 *   2. LPAtomicModule(gateway, helper, registry)
 *   3. gateway.setModule(14, module) + setModule(15, module)
 *      (14 = POOL_FEE_COMPOUND, 15 = MIGRATE_LP)
 *
 * The helper (MagnetaLpAtomicHelper, tokens workspace) must already be
 * deployed on the chain — pass it via HELPER_ADDR. The gateway is read from
 * deployments/<network>.json (so run deployAll first).
 *
 * On mainnets the registry admin should be the chain Safe — this script uses
 * the deployer, which is only acceptable on TESTNETS. It refuses to run on a
 * chain whose config has no MockV2Router-style testnet marker unless
 * ALLOW_MAINNET=1 is set explicitly.
 *
 * Usage:
 *   HELPER_ADDR=0x... pnpm hardhat run scripts/deploy/deployLpAtomicStack.ts --network baseSepolia
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG } from "./chainConfig";

const REPO = path.join(__dirname, "..", "..");

async function main() {
  const [deployer] = await ethers.getSigners();
  const mgr = new ethers.NonceManager(deployer);
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No chain config for chainId ${chainId}`);
  if (!cfg.defaultRouter) throw new Error(`${network.name}: no defaultRouter configured`);

  const helper = (process.env.HELPER_ADDR || "").trim();
  if (!ethers.isAddress(helper)) throw new Error("HELPER_ADDR missing or invalid");
  if ((await ethers.provider.getCode(helper)) === "0x") {
    throw new Error(`HELPER_ADDR ${helper} has no code on ${network.name}`);
  }

  const livePath = path.join(REPO, "deployments", `${network.name}.json`);
  const live = JSON.parse(fs.readFileSync(livePath, "utf8"));
  const gateway = live.contracts.MagnetaGateway;
  if (!gateway) throw new Error(`No MagnetaGateway in ${livePath}`);

  const isTestnet = network.name.toLowerCase().includes("sepolia") || network.name.toLowerCase().includes("testnet");
  if (!isTestnet && process.env.ALLOW_MAINNET !== "1") {
    throw new Error("Refusing mainnet run: registry admin would be the deployer EOA. Set ALLOW_MAINNET=1 only with a Safe-handoff plan.");
  }

  console.log(`Deployer: ${deployer.address} on ${network.name} (chainId ${chainId})`);
  console.log(`Gateway : ${gateway}`);
  console.log(`Helper  : ${helper}`);
  console.log(`Router  : ${cfg.defaultRouter}`);

  const Registry = await ethers.getContractFactory("MagnetaRouterRegistry", mgr);
  const registry = await Registry.deploy(deployer.address);
  await registry.waitForDeployment();
  const registryAddr = await registry.getAddress();
  console.log(`MagnetaRouterRegistry: ${registryAddr}`);

  await (await registry.setRouter(cfg.defaultRouter, true)).wait();
  console.log(`  ✓ router allowlisted`);

  const Module = await ethers.getContractFactory("LPAtomicModule", mgr);
  const mod = await Module.deploy(gateway, helper, registryAddr);
  await mod.waitForDeployment();
  const modAddr = await mod.getAddress();
  console.log(`LPAtomicModule: ${modAddr}`);

  const gw = await ethers.getContractAt("MagnetaGateway", gateway, mgr);
  await (await gw.setModule(14, modAddr)).wait();
  await (await gw.setModule(15, modAddr)).wait();
  console.log(`  ✓ gateway ops 14/15 wired`);

  live.contracts.MagnetaRouterRegistry = registryAddr;
  live.contracts.MagnetaLpAtomicHelper = helper;
  live.contracts.LPAtomicModule = modAddr;
  fs.writeFileSync(livePath, JSON.stringify(live, null, 2) + "\n");
  console.log(`Manifest updated: ${livePath}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
