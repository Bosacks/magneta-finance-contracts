import { ethers } from "hardhat";

// Deploys the redeploy-wave contracts on the in-memory hardhat network and
// prints real creation gasUsed. Run: npx hardhat run scripts/estimateDeployGas.ts
async function gasOf(txResponsePromise: any): Promise<bigint> {
  const c = await txResponsePromise;
  await c.waitForDeployment();
  const receipt = await c.deploymentTransaction()!.wait();
  return receipt!.gasUsed;
}

async function main() {
  const [owner, feeVault] = await ethers.getSigners();
  const EID = 1;

  const endpoint = await (await ethers.getContractFactory("MockLayerZeroEndpoint")).deploy(EID);
  await endpoint.waitForDeployment();
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const usdc = await MockERC20.deploy("USDC", "USDC", 6, ethers.parseUnits("1000000", 6));
  const weth = await MockERC20.deploy("WETH", "WETH", 18, ethers.parseEther("1000000"));
  await usdc.waitForDeployment(); await weth.waitForDeployment();
  const router = await (await ethers.getContractFactory("MockV2Router")).deploy(await weth.getAddress());
  await router.waitForDeployment();
  const mockSwap = await (await ethers.getContractFactory("MockSwapRouter")).deploy();
  await mockSwap.waitForDeployment();

  const Gateway = await ethers.getContractFactory("MagnetaGateway");
  const gwGas = await gasOf(Gateway.deploy(await endpoint.getAddress(), owner.address, feeVault.address));
  const gateway = await Gateway.deploy(await endpoint.getAddress(), owner.address, feeVault.address);
  await gateway.waitForDeployment();
  await (await gateway.setRequiredDVNCount(2)).wait();

  const LPModule = await ethers.getContractFactory("LPModule");
  const lpGas = await gasOf(LPModule.deploy(
    await gateway.getAddress(), await router.getAddress(), await usdc.getAddress(), await mockSwap.getAddress()));

  const TokenOps = await ethers.getContractFactory("TokenOpsModule");
  const opsGas = await gasOf(TokenOps.deploy(await gateway.getAddress(), await usdc.getAddress()));

  const SvcFee = await ethers.getContractFactory("MagnetaServiceFee");
  const svcGas = await gasOf(SvcFee.deploy(feeVault.address));

  const rows: Array<[string, bigint]> = [
    ["MagnetaGateway", gwGas],
    ["LPModule", lpGas],
    ["TokenOpsModule", opsGas],
    ["MagnetaServiceFee", svcGas],
  ];
  let total = 0n;
  console.log("\n=== Deployment gasUsed (hardhat, real) ===");
  for (const [n, g] of rows) { console.log(`${n.padEnd(20)} ${g.toString().padStart(10)} gas`); total += g; }
  console.log(`${"TOTAL (contracts repo)".padEnd(20)} ${total.toString().padStart(10)} gas`);
  console.log(`\nGateway+LPModule+ServiceFee (core wave): ${(gwGas + lpGas + svcGas).toString()} gas`);
}
main().catch((e) => { console.error(e); process.exit(1); });
