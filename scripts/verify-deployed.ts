/**
 * Sanity-check deployed addresses.
 *
 * For every contract in deployments/<network>.json:
 *   - confirm code exists at the address (eth_getCode != "0x")
 *   - if the contract exposes owner(), check it matches `admin`
 *
 * Usage:
 *   pnpm ts-node scripts/verify-deployed.ts base
 *   pnpm ts-node scripts/verify-deployed.ts baseSepolia
 *
 * RPC URL is read from the hardhat config for the given network, so the
 * usual {BASE_RPC_URL, SEPOLIA_RPC_URL, ...} env vars apply.
 */
import { ethers } from "ethers";
import hardhatConfig from "../hardhat.config";
import { get } from "../deployments";

const OWNER_ABI = ["function owner() view returns (address)"];

async function main() {
  const network = process.argv[2];
  if (!network) {
    console.error("usage: verify-deployed.ts <network>");
    process.exit(1);
  }

  const deployment = get(network);
  const netConfig = (hardhatConfig.networks as Record<string, any>)[network];
  const rpcUrl = netConfig?.url;
  if (!rpcUrl) {
    console.error(`hardhat config has no url for network "${network}"`);
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const onChainId = (await provider.getNetwork()).chainId.toString();
  if (onChainId !== deployment.chainId) {
    console.error(
      `chainId mismatch: deployment=${deployment.chainId} rpc=${onChainId}`,
    );
    process.exit(2);
  }

  let fail = 0;
  for (const [name, addr] of Object.entries(deployment.contracts)) {
    const code = await provider.getCode(addr);
    if (code === "0x") {
      console.error(`  ✗ ${name} @ ${addr} — no code`);
      fail++;
      continue;
    }

    let ownerTag = "";
    try {
      const c = new ethers.Contract(addr, OWNER_ABI, provider);
      const owner: string = await c.owner();
      ownerTag =
        owner.toLowerCase() === deployment.admin.toLowerCase()
          ? " (admin ok)"
          : ` (owner=${owner} ≠ admin=${deployment.admin})`;
      if (owner.toLowerCase() !== deployment.admin.toLowerCase()) fail++;
    } catch {
      // No owner() — fine.
    }
    console.log(`  ✓ ${name} @ ${addr}${ownerTag}`);
  }

  if (fail > 0) {
    console.error(`\n${fail} issue(s) on ${network}`);
    process.exit(3);
  }
  console.log(`\nAll good on ${network}.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
