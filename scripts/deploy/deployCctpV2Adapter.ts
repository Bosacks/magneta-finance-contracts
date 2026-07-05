/**
 * Sprint C — Deploy CctpV2Adapter on a CCTP V2 chain (mainnet or testnet).
 *
 * CCTP V2 chains use a 7-arg `depositForBurn(...)` signature that the
 * immutable MagnetaGateway can't call directly. The adapter wraps it to
 * the V1 4-arg ABI the Gateway already speaks; after deploy, the Safe
 * wires the adapter as the Gateway's `cctpMessenger` via
 * setup-cctp-v2-batch.json.
 *
 * Mainnet and testnet TokenMessengerV2 live at different deterministic
 * addresses (Circle uses one CREATE2 deploy per environment). The
 * CHAIN_CONFIG table below holds both — keyed by chainId. Source for
 * new entries: https://developers.circle.com/cctp/references/contract-addresses
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployCctpV2Adapter.ts --network <name>
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

// chainId → { v2 messenger address, CCTP V2 destination domain, env }
const CHAIN_CONFIG: Record<number, { messenger: string; domain: number; env: "mainnet" | "testnet" }> = {
  // Mainnets — unified V2 messenger 0x28b5...cf5d
  59144: { messenger: "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d", domain: 11, env: "mainnet" }, // Linea
  146:   { messenger: "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d", domain: 13, env: "mainnet" }, // Sonic
  // Testnets — unified V2 messenger 0x8FE6...DAA
  84532:    { messenger: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA", domain: 6,  env: "testnet" }, // Base Sepolia
  59141:    { messenger: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA", domain: 11, env: "testnet" }, // Linea Sepolia
  11155111: { messenger: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA", domain: 0,  env: "testnet" }, // Ethereum Sepolia
  11155420: { messenger: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA", domain: 2,  env: "testnet" }, // OP Sepolia
  421614:   { messenger: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA", domain: 3,  env: "testnet" }, // Arbitrum Sepolia
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) {
    throw new Error(
      `chainId ${chainId} not in CHAIN_CONFIG. Add the V2 messenger address ` +
      `(per Circle docs) and CCTP V2 domain id, then re-run.`,
    );
  }
  const V2_TOKEN_MESSENGER = cfg.messenger;
  const domain = cfg.domain;

  // Sanity: V2 messenger must have code on this chain
  const code = await ethers.provider.getCode(V2_TOKEN_MESSENGER);
  if (code === "0x") {
    throw new Error(
      `V2 TokenMessenger ${V2_TOKEN_MESSENGER} has no code on ${network.name}. ` +
      `Check Circle's docs — the V2 unified address may differ on this chain.`,
    );
  }

  console.log(`\n── Sprint C — CctpV2Adapter (${cfg.env}) ──`);
  console.log(`Network        : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer       : ${deployer.address}`);
  console.log(`V2 messenger   : ${V2_TOKEN_MESSENGER}`);
  console.log(`Local domain   : ${domain}`);

  const Adapter = await ethers.getContractFactory("CctpV2Adapter");
  const adapter = await Adapter.deploy(V2_TOKEN_MESSENGER);
  await adapter.waitForDeployment();
  const addr = await adapter.getAddress();
  console.log(`\n✅ Deployed: ${addr}`);

  const outDir = path.join(__dirname, "..", "..", "deployments");
  const outPath = path.join(outDir, `${network.name}-cctp-v2-adapter.json`);
  fs.writeFileSync(
    outPath,
    JSON.stringify({
      network: network.name,
      chainId: String(chainId),
      adapter: addr,
      v2Messenger: V2_TOKEN_MESSENGER,
      cctpDomain: domain,
      deployer: deployer.address,
      timestamp: new Date().toISOString(),
    }, null, 2),
  );
  console.log(`📝 ${outPath}`);

  console.log(`\nNext: pnpm tsx scripts/deploy/generate-cctp-v2-setup-batches.ts`);
}

main().catch((e) => { console.error(e); process.exit(1); });
