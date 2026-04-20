/**
 * Deploy OpenZeppelin TimelockController with the given Gnosis Safe as sole proposer.
 *
 * Usage:
 *   GNOSIS_SAFE=0x... pnpm hardhat run scripts/deploy/deployTimelock.ts --network base
 *
 * After deploy, add the timelock address to deployments/<network>.json under `timelock`
 * and transfer ownership of Class-A contracts via transferOwnership.ts.
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const MIN_DELAY_SECONDS = 48 * 60 * 60; // 48h

async function main() {
  const safe = process.env.GNOSIS_SAFE;
  if (!safe || !ethers.isAddress(safe)) {
    throw new Error("Set GNOSIS_SAFE=<address> (the Safe that will propose timelock ops)");
  }

  const [deployer] = await ethers.getSigners();
  console.log(`Network:  ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Safe:     ${safe}`);
  console.log(`Delay:    ${MIN_DELAY_SECONDS}s (${MIN_DELAY_SECONDS / 3600}h)`);

  const Timelock = await ethers.getContractFactory("TimelockController");
  const timelock = await Timelock.deploy(
    MIN_DELAY_SECONDS,
    [safe],
    [safe, ethers.ZeroAddress],
    ethers.ZeroAddress
  );
  await timelock.waitForDeployment();
  const addr = await timelock.getAddress();
  console.log(`\nTimelockController deployed at: ${addr}`);

  const depFile = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  if (fs.existsSync(depFile)) {
    const dep = JSON.parse(fs.readFileSync(depFile, "utf8"));
    dep.timelock = addr;
    dep.gnosisSafe = safe;
    fs.writeFileSync(depFile, JSON.stringify(dep, null, 2));
    console.log(`Recorded in ${depFile}`);
  } else {
    console.warn(`No ${depFile} found — add timelock address manually.`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
