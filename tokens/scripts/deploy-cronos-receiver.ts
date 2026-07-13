/**
 * Sprint D #2 — Deploy CronosCreateTokenReceiver on Cronos.
 *
 * Prereqs:
 *   - MagnetaTokenFactory (legacy) must already be deployed on Cronos. Its
 *     address is read from CRONOS_MAGNETA_TOKEN_FACTORY env var (the same
 *     env var the off-chain Relayer uses, so the two stay in sync).
 *   - The deployer EOA must be the current factory owner OR can hand off
 *     the `crossChainCreator` slot via a Safe batch after this script.
 *
 * Usage:
 *   CRONOS_MAGNETA_TOKEN_FACTORY=0x...  \
 *   RELAYER_WALLET=0x2B898219Ce1dbEb3ECd3956223b9Ff0C0B126aC2  \
 *     pnpm hardhat run scripts/deploy-cronos-receiver.ts --network cronos
 *
 * Post-deploy ops (NOT automated here — keep human-in-the-loop):
 *   1. factory.setCrossChainCreator(receiver) — done via in-house Safe
 *      batch (the factory owner on Cronos is the Magneta in-house Safe
 *      0x40ea29…b297). See setup-cronos-receiver-batch.ts for the
 *      generator.
 *   2. receiver.setTrustedSource(sourceChainId, sourceGateway) × 19
 *      chains — also via Safe batch (the receiver's owner is the same
 *      in-house Safe). See setup-cronos-receiver-batch.ts.
 *   3. Update lib/relayer/cronosRelayer.ts env var
 *      CRONOS_CREATE_TOKEN_RECEIVER to the deployed address; the relayer
 *      then routes calls through receiver.executeCreate() with on-chain
 *      EIP-712 verification.
 */
import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// In-house Safe used on chains where Safe Wallet UI doesn't support the
// chain (Cronos, Abstract, Flare, Sei). Becomes the receiver's owner so
// the Magneta multisig can rotate the relayer + manage trusted sources.
const CRONOS_INHOUSE_SAFE = "0x40ea2908Ea490d58E62D1Fd3364464D8A857b297";

interface ReceiverDeployment {
  network: string;
  chainId: string;
  deployer: string;
  timestamp: string;
  factory: string;
  receiver: string;
  relayer: string;
  owner: string;
}

async function main() {
  if (network.name !== "cronos") {
    console.warn(
      `⚠ Deploying on ${network.name} — this script targets Cronos (chainId 25). ` +
      `Run with --network cronos for the canonical case.`,
    );
  }

  const factoryAddr = process.env.CRONOS_MAGNETA_TOKEN_FACTORY;
  if (!factoryAddr || !ethers.isAddress(factoryAddr)) {
    throw new Error("CRONOS_MAGNETA_TOKEN_FACTORY env var must be a valid address");
  }

  const relayerAddr = process.env.RELAYER_WALLET ?? "0x2B898219Ce1dbEb3ECd3956223b9Ff0C0B126aC2";
  if (!ethers.isAddress(relayerAddr)) {
    throw new Error("RELAYER_WALLET env var must be a valid address");
  }

  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\n── Sprint D #2 — CronosCreateTokenReceiver ──`);
  console.log(`Network    : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer   : ${deployer.address}`);
  console.log(`Factory    : ${factoryAddr}`);
  console.log(`Relayer    : ${relayerAddr}`);
  console.log(`Owner      : ${CRONOS_INHOUSE_SAFE} (in-house Safe)`);

  // Sanity-check the factory has code at the given address.
  const code = await ethers.provider.getCode(factoryAddr);
  if (code === "0x") {
    throw new Error(`No code at ${factoryAddr} — factory not deployed on this network`);
  }

  const ReceiverC = await ethers.getContractFactory("CronosCreateTokenReceiver");
  console.log(`\nDeploying CronosCreateTokenReceiver…`);
  const receiver = await ReceiverC.deploy(
    factoryAddr,
    relayerAddr,
    CRONOS_INHOUSE_SAFE,
  );
  await receiver.waitForDeployment();
  const receiverAddr = await receiver.getAddress();

  console.log(`✅ Receiver deployed: ${receiverAddr}`);

  // Write the deployment record so the setup-batch generator + Relayer env
  // bootstrap have a single source of truth.
  const outDir = path.join(__dirname, "..", "deployments-cronos-receiver");
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });
  const outPath = path.join(outDir, `${network.name}.json`);
  const record: ReceiverDeployment = {
    network: network.name,
    chainId: String(chainId),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    factory: factoryAddr,
    receiver: receiverAddr,
    relayer: relayerAddr,
    owner: CRONOS_INHOUSE_SAFE,
  };
  fs.writeFileSync(outPath, JSON.stringify(record, null, 2));
  console.log(`📝 Deployment record written: ${outPath}`);

  console.log(`\n── Next steps ──`);
  console.log(`1. Generate setup batch:`);
  console.log(`     pnpm tsx scripts/2dvn/setup-cronos-receiver-batch.ts`);
  console.log(`2. Sign + execute the batch via in-house Safe (execBatch.ts).`);
  console.log(`3. Set the relayer env var:`);
  console.log(`     CRONOS_CREATE_TOKEN_RECEIVER=${receiverAddr}`);
  console.log(`4. Restart magneta-tokens systemd; the off-chain Relayer will`);
  console.log(`   now route calls through the on-chain receiver.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
