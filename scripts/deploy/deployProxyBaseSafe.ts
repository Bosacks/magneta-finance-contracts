/**
 * Base-safe MagnetaProxy deploy: explicit per-tx nonce + propagation waits, to
 * survive Base's EIP-7702-delegated deployer where ethers' NonceManager sends
 * the next tx with a stale nonce ("Nonce too low"). Deploys → whitelists the
 * chain defaultRouter → transfers to the Safe → records to deployments-b.
 *   pnpm hardhat run scripts/deploy/deployProxyBaseSafe.ts --network base
 */
import { ethers, network } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

async function main() {
  const depPath = path.join(__dirname, "..", "..", "deployments-b", `${network.name}.json`);
  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  if (dep.contracts?.MagnetaProxy) { console.log(`MagnetaProxy already ${dep.contracts.MagnetaProxy} — skip`); return; }

  const feeVault: string = dep.feeVault;
  const safe: string = dep.gnosisSafe;
  const router: string = dep.chainConfig?.defaultRouter;
  if (!ethers.isAddress(feeVault) || !ethers.isAddress(safe) || !ethers.isAddress(router))
    throw new Error(`bad feeVault/safe/router: ${feeVault} ${safe} ${router}`);

  const [signer] = await ethers.getSigners();
  const prov = ethers.provider;
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  // Send one tx with a freshly-read nonce, wait for the receipt, then pause so
  // the sequencer's nonce reflects it before the next read.
  const send = async (label: string, txReq: any) => {
    for (let attempt = 1; attempt <= 6; attempt++) {
      try {
        const nonce = await prov.getTransactionCount(signer.address, "pending");
        const tx = await signer.sendTransaction({ ...txReq, nonce });
        const r = await tx.wait();
        console.log(`  ✓ ${label} (nonce ${nonce}, block ${r?.blockNumber})`);
        await sleep(6000);
        return r;
      } catch (e: any) {
        if (attempt === 6) throw e;
        console.log(`  ${label} retry ${attempt}/6 (${(e.message || "").slice(0, 40)})`);
        await sleep(6000);
      }
    }
  };

  console.log(`Deploying MagnetaProxy(${feeVault}) on ${network.name}…`);
  const Factory = await ethers.getContractFactory("MagnetaProxy", signer);
  const nonce0 = await prov.getTransactionCount(signer.address, "pending");
  const proxy = await Factory.deploy(feeVault, { nonce: nonce0 });
  await proxy.waitForDeployment();
  const addr = await proxy.getAddress();
  console.log(`  ✓ MagnetaProxy deployed: ${addr} (nonce ${nonce0})`);
  await sleep(6000);

  const iface = new ethers.Interface([
    "function setAllowedSwapTarget(address,bool)",
    "function setAllowedSpender(address,bool)",
    "function transferOwnership(address)",
  ]);
  await send("setAllowedSwapTarget(router)", { to: addr, data: iface.encodeFunctionData("setAllowedSwapTarget", [router, true]) });
  await send("setAllowedSpender(router)", { to: addr, data: iface.encodeFunctionData("setAllowedSpender", [router, true]) });
  await send("transferOwnership(Safe)", { to: addr, data: iface.encodeFunctionData("transferOwnership", [safe]) });

  dep.contracts.MagnetaProxy = addr;
  fs.writeFileSync(depPath, JSON.stringify(dep, null, 2) + "\n");
  console.log(`  ✓ recorded MagnetaProxy=${addr}. Ownable2Step → Safe must acceptOwnership.`);
}
main().catch((e) => { console.error(e); process.exit(1); });
