/**
 * Deploy the Magneta Safe (2/2 multisig) on the current Hardhat network.
 *
 * Idempotent: if a Safe already exists at the predicted address (saltNonce=0),
 * verifies its owners + threshold match expected and skips deploy.
 *
 * Usage:
 *   pnpm hardhat run scripts/safe/inhouse/createMagnetaSafe.ts --network cronos
 *   SALT_NONCE=42 pnpm hardhat run ... --network cronos   # only if you need a different one
 *
 * After deploy, updates deployments/<network>.json with the new `gnosisSafe` address.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import {
  SAFE_PROXY_FACTORY,
  SAFE_L2_SINGLETON,
  SAFE_OWNERS,
  SAFE_THRESHOLD,
  DEFAULT_SALT_NONCE,
  encodeSetupInitializer,
  computeSafeAddress,
} from "./lib/safe";

const PROXY_FACTORY_ABI = [
  "function createProxyWithNonce(address singleton, bytes initializer, uint256 saltNonce) external returns (address proxy)",
  "function proxyCreationCode() external view returns (bytes)",
];

const SAFE_ABI = [
  "function getOwners() external view returns (address[])",
  "function getThreshold() external view returns (uint256)",
  "function VERSION() external view returns (string)",
];

async function main() {
  const saltNonce = process.env.SALT_NONCE ? BigInt(process.env.SALT_NONCE) : DEFAULT_SALT_NONCE;
  const initializer = encodeSetupInitializer();
  const predicted = computeSafeAddress(initializer, saltNonce);

  console.log(`Network    : ${network.name}`);
  console.log(`Singleton  : ${SAFE_L2_SINGLETON} (SafeL2 v1.4.1)`);
  console.log(`Factory    : ${SAFE_PROXY_FACTORY}`);
  console.log(`Owners     : [${SAFE_OWNERS.join(", ")}]`);
  console.log(`Threshold  : ${SAFE_THRESHOLD}`);
  console.log(`SaltNonce  : ${saltNonce}`);
  console.log(`Predicted  : ${predicted}`);
  console.log();

  // Check if already deployed at predicted address
  const provider = ethers.provider;
  const code = await provider.getCode(predicted);
  if (code !== "0x") {
    console.log(`✅ Safe already deployed at ${predicted}`);
    const safe = await ethers.getContractAt(SAFE_ABI, predicted);
    const owners = await safe.getOwners();
    const threshold = await safe.getThreshold();
    const version = await safe.VERSION().catch(() => "(no VERSION fn)");
    console.log(`   Version    : ${version}`);
    console.log(`   Threshold  : ${threshold}`);
    console.log(`   Owners     : ${owners.join(", ")}`);

    const ownersMatch =
      owners.length === SAFE_OWNERS.length &&
      owners.every((o: string, i: number) => o.toLowerCase() === SAFE_OWNERS[i].toLowerCase());
    if (!ownersMatch || threshold !== SAFE_THRESHOLD) {
      console.error(`\n❌ Existing Safe params DIFFER from expected. Bailing out.`);
      process.exit(1);
    }
    updateDeploymentFile(predicted);
    return;
  }

  // Verify factory + singleton are deployed on this chain
  const factoryCode = await provider.getCode(SAFE_PROXY_FACTORY);
  const singletonCode = await provider.getCode(SAFE_L2_SINGLETON);
  if (factoryCode === "0x") {
    console.error(`❌ SafeProxyFactory not deployed at ${SAFE_PROXY_FACTORY}.`);
    console.error(`   Run scripts/safe/inhouse/deploySafeInfra.ts first.`);
    process.exit(1);
  }
  if (singletonCode === "0x") {
    console.error(`❌ SafeL2 singleton not deployed at ${SAFE_L2_SINGLETON}.`);
    console.error(`   Run scripts/safe/inhouse/deploySafeInfra.ts first.`);
    process.exit(1);
  }

  // Deploy
  const [signer] = await ethers.getSigners();
  console.log(`Signer     : ${signer.address}`);
  const balance = await provider.getBalance(signer.address);
  console.log(`Balance    : ${ethers.formatEther(balance)}`);
  console.log();

  const factory = await ethers.getContractAt(PROXY_FACTORY_ABI, SAFE_PROXY_FACTORY, signer);
  console.log(`Calling createProxyWithNonce(${SAFE_L2_SINGLETON}, <initializer>, ${saltNonce})...`);
  const tx = await factory.createProxyWithNonce(SAFE_L2_SINGLETON, initializer, saltNonce);
  console.log(`Tx hash    : ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`Mined in block ${receipt!.blockNumber}, gas used ${receipt!.gasUsed}`);

  // Verify
  const codeAfter = await provider.getCode(predicted);
  if (codeAfter === "0x") {
    console.error(`❌ Safe not deployed at predicted address ${predicted}. Address mismatch?`);
    process.exit(1);
  }
  console.log(`\n✅ Safe deployed at ${predicted}`);

  updateDeploymentFile(predicted);
}

function updateDeploymentFile(safeAddress: string) {
  const depPath = path.join(__dirname, "..", "..", "..", "deployments", `${network.name}.json`);
  if (!fs.existsSync(depPath)) {
    console.log(`\n(no deployments/${network.name}.json yet — Safe address not persisted)`);
    return;
  }
  const dep = JSON.parse(fs.readFileSync(depPath, "utf-8"));
  if (dep.gnosisSafe && dep.gnosisSafe.toLowerCase() === safeAddress.toLowerCase()) {
    console.log(`\n(deployments/${network.name}.json already has gnosisSafe = ${safeAddress})`);
    return;
  }
  dep.gnosisSafe = safeAddress;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`\n✏️  Updated deployments/${network.name}.json with gnosisSafe = ${safeAddress}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
