/**
 * Sprint C — Deploy CctpV2Adapter on Linea or Sonic.
 *
 * CCTP V2 chains (Linea domain 11, Sonic domain 13) use a 7-arg
 * `depositForBurn(...)` signature that the immutable MagnetaGateway can't
 * call directly. The adapter wraps it to the V1 4-arg ABI the Gateway
 * already speaks; after deploy, the Safe wires the adapter as the
 * Gateway's `cctpMessenger` via setup-cctp-v2-batch.json.
 *
 * V2 TokenMessenger is at the SAME unified address on all V2 chains:
 *   0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/deployCctpV2Adapter.ts --network linea
 *   pnpm hardhat run scripts/deploy/deployCctpV2Adapter.ts --network sonic
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const V2_TOKEN_MESSENGER = "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d";

// chainId → CCTP V2 domain (per Circle docs)
const V2_DOMAINS: Record<number, number> = {
  59144: 11, // Linea
  146:   13, // Sonic
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const domain = V2_DOMAINS[chainId];
  if (domain === undefined) {
    throw new Error(`Sprint C only supports Linea (59144) and Sonic (146); got chainId ${chainId}`);
  }

  // Sanity: V2 messenger must have code on this chain
  const code = await ethers.provider.getCode(V2_TOKEN_MESSENGER);
  if (code === "0x") {
    throw new Error(
      `V2 TokenMessenger ${V2_TOKEN_MESSENGER} has no code on ${network.name}. ` +
      `Check Circle's docs — the V2 unified address may differ on this chain.`,
    );
  }

  console.log(`\n── Sprint C — CctpV2Adapter ──`);
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
