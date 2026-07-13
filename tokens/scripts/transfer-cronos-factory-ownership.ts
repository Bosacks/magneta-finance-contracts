/**
 * Sprint D #2 — Transfer the Cronos MagnetaTokenFactory ownership to the
 * in-house Safe (Ownable2Step first leg).
 *
 * The factory is deployed by the deployer EOA but must be owned by the
 * Magneta in-house Safe so that crossChainCreator setup goes through the
 * multisig. The Safe accepts ownership as the FIRST tx of the
 * setup-cronos-receiver-batch.json.
 *
 * Usage:
 *   pnpm hardhat run scripts/transfer-cronos-factory-ownership.ts --network cronos
 *
 * Reads the factory address from deployments/cronos-factory.json so this
 * stays in sync with the deploy step output.
 */
import { ethers, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const CRONOS_INHOUSE_SAFE = "0x40ea2908Ea490d58E62D1Fd3364464D8A857b297";

async function main() {
  const recordPath = path.join(__dirname, "..", "deployments", `${network.name}-factory.json`);
  if (!fs.existsSync(recordPath)) {
    throw new Error(`No factory deployment at ${recordPath} — run deploy-token-factory.ts first.`);
  }
  const factoryAddr = JSON.parse(fs.readFileSync(recordPath, "utf-8")).address as string;

  const [signer] = await ethers.getSigners();
  console.log(`Network    : ${network.name}`);
  console.log(`Factory    : ${factoryAddr}`);
  console.log(`Current owner caller (must be deployer): ${signer.address}`);
  console.log(`New owner  : ${CRONOS_INHOUSE_SAFE} (in-house Safe)`);

  const factory = await ethers.getContractAt("MagnetaTokenFactory", factoryAddr);
  const currentOwner = await factory.owner();
  console.log(`\nOn-chain owner: ${currentOwner}`);
  if (currentOwner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(
      `Signer ${signer.address} is not the current owner. transferOwnership requires the current owner.`,
    );
  }

  const tx = await factory.transferOwnership(CRONOS_INHOUSE_SAFE);
  console.log(`\nTx submitted: ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`Mined in block ${receipt!.blockNumber}, gas ${receipt!.gasUsed.toString()}`);

  const pending = await factory.pendingOwner();
  console.log(`\nPending owner now: ${pending}`);
  console.log(`\n✅ Done. Next: run setup-cronos-receiver-batch.json via the in-house Safe;`);
  console.log(`   the batch's first tx (acceptOwnership) finalises the transfer.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
