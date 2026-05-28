/**
 * Finish a cross-chain LP value op end-to-end on the destination chain.
 *
 * Two steps, both broadcast from the deployer wallet (same one the SDK
 * already authorized for the source-chain dispatch):
 *
 *   1. Circle MessageTransmitter.receiveMessage(message, attestation)
 *      Mints the bridged USDC to the destination Gateway. Reads the
 *      Iris API for the `message` + `attestation` hex strings using the
 *      source-chain tx hash provided via env.
 *
 *   2. MagnetaGateway.fulfillValueOp(guid)
 *      Routes the pending value op (already stored on the destination
 *      Gateway via _lzReceive) through the registered module — LP add,
 *      mint, freeze, etc. depending on op.
 *
 * Usage (run on the DESTINATION network):
 *   SRC_TX_HASH=0x059faa07…  \
 *   SRC_CCTP_DOMAIN=7        \  # Polygon → see CCTP_DOMAIN table
 *   GUID=0xcb440417…         \  # from CrossChainOpSent event on source
 *   pnpm hardhat run scripts/deploy/claimAndFulfillCctp.ts --network base
 *
 * SRC_CCTP_DOMAIN reference:
 *   0=Ethereum, 1=Avalanche, 2=Optimism, 3=Arbitrum, 6=Base, 7=Polygon
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const DEPLOY_DIR = path.join(__dirname, "..", "..", "deployments");

const MESSAGE_TRANSMITTER: Record<number, string> = {
  1:     "0x0a992d191DEeC32aFe36203Ad87D7d289a738F81", // Ethereum
  43114: "0x8186359aF5F57FbB40c6b14A588d2A59C0C29880", // Avalanche
  10:    "0x4D41f22c5a0e5c74090899E5a8Fb597a8842b3e8", // Optimism
  42161: "0xC30362313FBBA5cf9163F0bb16a0e01f01A896ca", // Arbitrum
  8453:  "0xAD09780d193884d503182aD4588450C416D6F9D4", // Base
  137:   "0xF3be9355363857F3e001be68856A2f96b4C39Ba9", // Polygon
};

function need(env: string): string {
  const v = process.env[env];
  if (!v) throw new Error(`Missing env var: ${env}`);
  return v;
}

async function main() {
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  const transmitter = MESSAGE_TRANSMITTER[chainId];
  if (!transmitter) throw new Error(`No MessageTransmitter for chainId ${chainId}`);

  const srcTxHash = need("SRC_TX_HASH");
  const srcCctpDomain = Number(need("SRC_CCTP_DOMAIN"));
  const guid = need("GUID");

  console.log(`\n── claim + fulfill on ${network.name} (chainId ${chainId}) ──`);
  console.log(`   signer        : ${signer.address}`);
  console.log(`   MessageTransmitter: ${transmitter}`);
  console.log(`   Source tx     : ${srcTxHash}`);
  console.log(`   Source domain : ${srcCctpDomain}`);
  console.log(`   GUID          : ${guid}`);

  // ─── 1. Pull message + attestation from Circle Iris ───────────────────
  const irisUrl = `https://iris-api.circle.com/v1/messages/${srcCctpDomain}/${srcTxHash}`;
  console.log(`\n── 1. GET ${irisUrl}`);
  const res = await fetch(irisUrl);
  if (!res.ok) throw new Error(`Iris API returned ${res.status}: ${await res.text()}`);
  const body = await res.json() as { messages: Array<{ attestation: string; message: string; eventNonce: string }> };
  if (!body.messages || body.messages.length === 0) {
    throw new Error(`No messages found for tx ${srcTxHash}`);
  }
  const msg = body.messages[0];
  if (!msg.attestation || msg.attestation === "PENDING") {
    throw new Error(`Attestation not ready yet (status: ${msg.attestation}). Wait ~13-20 min from the source-chain dispatch.`);
  }
  console.log(`   ✓ attestation ready (eventNonce ${msg.eventNonce})`);

  // ─── 2. receiveMessage on MessageTransmitter ──────────────────────────
  // Check first if it's already been received (idempotent shortcut).
  const usedNonceSig = "usedNonces(bytes32)(uint256)";
  // Some MessageTransmitter versions expose this as a public mapping;
  // we'll skip the read and just rely on the call reverting cleanly if
  // the message has already been processed.
  console.log(`\n── 2. receiveMessage on MessageTransmitter`);
  const transmitterAbi = [
    "function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool)",
  ];
  const transmitterContract = new ethers.Contract(transmitter, transmitterAbi, signer);
  try {
    const tx = await transmitterContract.receiveMessage(msg.message, msg.attestation);
    const receipt = await tx.wait();
    console.log(`   ✓ receiveMessage tx ${tx.hash} (block ${receipt.blockNumber})`);
  } catch (e: any) {
    const reason = e?.reason ?? e?.shortMessage ?? e?.message ?? String(e);
    if (/already processed|nonce already used|used nonce/i.test(reason)) {
      console.log(`   ✓ Already received (idempotent — moving on)`);
    } else {
      throw e;
    }
  }

  // ─── 3. fulfillValueOp on the destination MagnetaGateway ──────────────
  const deployPath = path.join(DEPLOY_DIR, `${network.name}.json`);
  if (!fs.existsSync(deployPath)) {
    throw new Error(`No deployment file at ${deployPath} — can't locate the Gateway`);
  }
  const deployment = JSON.parse(fs.readFileSync(deployPath, "utf-8"));
  const gatewayAddr = deployment.contracts.MagnetaGateway as string;
  console.log(`\n── 3. fulfillValueOp on Gateway ${gatewayAddr}`);

  const gateway = await ethers.getContractAt("MagnetaGateway", gatewayAddr);

  // Sanity: pendingValueOp.bridgedAmount > 0?
  const pending = await gateway.pendingValueOps(guid);
  if (pending.bridgedAmount === 0n) {
    throw new Error(
      `No pending value op for guid ${guid} on Gateway ${gatewayAddr}. ` +
      `Either the LayerZero message hasn't been delivered yet (check layerzeroscan.com) ` +
      `or you're on the wrong destination chain.`
    );
  }
  console.log(`   pending.bridgedAmount = ${pending.bridgedAmount} (token ${pending.bridgedToken})`);

  const tx = await gateway.fulfillValueOp(guid);
  const receipt = await tx.wait();
  console.log(`   ✓ fulfillValueOp tx ${tx.hash} (block ${receipt.blockNumber}, gasUsed ${receipt.gasUsed})`);

  console.log(`\n── DONE — cross-chain value op fulfilled on ${network.name} ──`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
