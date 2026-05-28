/**
 * Wire CCTP + LZ peer between two freshly redeployed MagnetaGateways
 * (Polygon ↔ Base). Run AFTER `redeployGatewayStack.ts` has succeeded
 * on BOTH chains.
 *
 * Per-chain calls (made on whichever network this is run against):
 *   1. setCctp(<this-chain Circle messenger>, <this-chain CCTP domain>)
 *   2. setEidCctpDomainBatch([<other-chain EID>], [<other-chain CCTP domain>])
 *   3. setPeer(<other-chain EID>, <other-chain Gateway as bytes32>)
 *
 * Reads both deployments[<network>].json files so it knows the OTHER
 * chain's new Gateway address. Pair is hardcoded to Polygon (137) ↔
 * Base (8453) for the MG-6 verification scope.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/wireGatewayPair.ts --network polygon
 *   pnpm hardhat run scripts/deploy/wireGatewayPair.ts --network base
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

// CCTP V1 TokenMessenger addresses (Circle official, verified on-chain).
const CCTP_MESSENGER: Record<number, string> = {
  137:  "0x9daF8c91AEFAE50b9c0E69629D3F6Ca40cA3B3FE", // Polygon
  8453: "0x1682Ae6375C4E4A97e4B583BC394c861A46D8962", // Base
};

// CCTP domain per chain.
const CCTP_DOMAIN: Record<number, number> = {
  137:  7, // Polygon
  8453: 6, // Base
};

// LZ V2 EID per chain.
const LZ_EID: Record<number, number> = {
  137:  30109, // Polygon
  8453: 30184, // Base
};

// Per-chain hardhat network name (must match deployments/<name>.json).
const NETWORK_NAME: Record<number, string> = {
  137:  "polygon",
  8453: "base",
};

// Pair scope for MG-6 verification.
const PAIR = [137, 8453] as const;

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  if (!PAIR.includes(chainId as typeof PAIR[number])) {
    throw new Error(`This script is scoped to Polygon (137) ↔ Base (8453). Got ${chainId}.`);
  }
  const otherChainId = PAIR.find((c) => c !== chainId)!;
  const otherNet = NETWORK_NAME[otherChainId];

  console.log(`\n── Wire Gateway on ${network.name} (chainId ${chainId}) ──`);
  console.log(`   Counterpart: ${otherNet} (chainId ${otherChainId})`);

  // Read this chain's new Gateway from its deployment file.
  const thisPath = path.join(DEPLOY_DIR, `${NETWORK_NAME[chainId]}.json`);
  const otherPath = path.join(DEPLOY_DIR, `${otherNet}.json`);
  for (const p of [thisPath, otherPath]) {
    if (!fs.existsSync(p)) {
      throw new Error(`Missing deployment file: ${p}. Run redeployGatewayStack on that chain first.`);
    }
  }
  const thisGateway = JSON.parse(fs.readFileSync(thisPath, "utf-8")).contracts.MagnetaGateway;
  const otherGateway = JSON.parse(fs.readFileSync(otherPath, "utf-8")).contracts.MagnetaGateway;

  console.log(`   This  Gateway: ${thisGateway}`);
  console.log(`   Other Gateway: ${otherGateway}`);

  const gateway = await ethers.getContractAt("MagnetaGateway", thisGateway);

  // ─── 1. setCctp (this chain's Circle messenger + local domain) ────────
  const messenger = CCTP_MESSENGER[chainId];
  const localDomain = CCTP_DOMAIN[chainId];
  console.log(`\n   1. setCctp(${messenger}, ${localDomain})`);
  const tx1 = await gateway.setCctp(messenger, localDomain);
  await tx1.wait();
  console.log(`      ✓ tx ${tx1.hash}`);

  // ─── 2. setEidCctpDomainBatch (map OTHER chain's EID → CCTP domain) ───
  const otherEid = LZ_EID[otherChainId];
  const otherCctpDomain = CCTP_DOMAIN[otherChainId];
  console.log(`\n   2. setEidCctpDomainBatch([${otherEid}], [${otherCctpDomain}])`);
  const tx2 = await gateway.setEidCctpDomainBatch([otherEid], [otherCctpDomain]);
  await tx2.wait();
  console.log(`      ✓ tx ${tx2.hash}`);

  // ─── 3. setPeer (LZ peer = other Gateway as bytes32) ──────────────────
  const peerB32 = ethers.zeroPadValue(otherGateway, 32);
  console.log(`\n   3. setPeer(${otherEid}, ${peerB32})`);
  const tx3 = await gateway.setPeer(otherEid, peerB32);
  await tx3.wait();
  console.log(`      ✓ tx ${tx3.hash}`);

  // ─── Sanity reads ─────────────────────────────────────────────────────
  console.log(`\n── Sanity ──`);
  console.log(`   cctpMessenger:           ${await gateway.cctpMessenger()}`);
  console.log(`   localCctpDomain:         ${await gateway.localCctpDomain()}`);
  console.log(`   eidToCctpDomain[${otherEid}]: ${await gateway.eidToCctpDomain(otherEid)}`);
  console.log(`   peers[${otherEid}]:          ${await gateway.peers(otherEid)}`);
  console.log(`\n   ✓ ${network.name} Gateway wired to ${otherNet}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
