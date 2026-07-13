/**
 * Sweep remaining native balance from Deployer to Relayer.
 * Reserves gas for the transfer itself (2× safety margin on base fee).
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/fundRelayer.ts --network arbitrum
 */
import { ethers, network } from "hardhat";

const RELAYER = "0x2B898219Ce1dbEb3ECd3956223b9Ff0C0B126aC2";

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();

  const balance = await ethers.provider.getBalance(deployer.address);

  const gasLimit = 21000n;
  const feeData = await ethers.provider.getFeeData();
  const maxFee = feeData.maxFeePerGas ?? feeData.gasPrice ?? 1n;
  const gasReserve = gasLimit * maxFee * 3n;

  const amount = balance - gasReserve;

  console.log(`Network   : ${network.name} (chainId ${net.chainId})`);
  console.log(`Deployer  : ${deployer.address}`);
  console.log(`Relayer   : ${RELAYER}`);
  console.log(`Balance   : ${ethers.formatEther(balance)} native`);
  console.log(`Gas res.  : ${ethers.formatEther(gasReserve)} native (${gasLimit} × ${ethers.formatUnits(maxFee, "gwei")} gwei × 3)`);
  console.log(`To send   : ${ethers.formatEther(amount)} native`);

  if (amount <= 0n) throw new Error("Balance too low to cover gas reserve");

  const tx = await deployer.sendTransaction({ to: RELAYER, value: amount });
  console.log(`\nTx sent   : ${tx.hash}`);
  await tx.wait();

  const newDeployer = await ethers.provider.getBalance(deployer.address);
  const newRelayer = await ethers.provider.getBalance(RELAYER);
  console.log(`\nDeployer remaining : ${ethers.formatEther(newDeployer)} native`);
  console.log(`Relayer new total  : ${ethers.formatEther(newRelayer)} native`);
}

main().catch((e) => { console.error(e); process.exit(1); });
