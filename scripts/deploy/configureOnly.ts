/**
 * Resume post-deploy configuration from an existing deployments/<network>.json.
 *
 * Use this when deployAll.ts deployed all 11 contracts but crashed during the
 * config phase (nonce lag, RPC hiccup, etc.). Reads addresses from the
 * checkpointed JSON and runs only the on-chain configuration steps.
 *
 * Idempotent: each step reads current state and skips if already applied.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/configureOnly.ts --network polygon
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";
import { CHAIN_CONFIG, FEE_VAULT, PAUSE_GUARDIAN } from "./chainConfig";

const GATEWAY_ABI = [
  "function setModule(uint8 op, address module) external",
  "function moduleFor(uint8 op) view returns (address)",
  "function setUsdc(address) external",
  "function usdc() view returns (address)",
  "function addPauser(address) external",
  "function isPauser(address) view returns (bool)",
];

const SWAP_ABI = [
  "function addPauser(address) external",
  "function isPauser(address) view returns (bool)",
  "function setFeeExempt(address, bool) external",
  "function feeExempt(address) view returns (bool)",
  "function setWhitelistedToken(address, bool) external",
  "function whitelistedTokens(address) view returns (bool)",
];

async function main() {
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) throw new Error(`No CHAIN_CONFIG for chainId ${chainId}`);

  const depFile = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  if (!fs.existsSync(depFile)) throw new Error(`No deployment file: ${depFile}`);
  const dep = JSON.parse(fs.readFileSync(depFile, "utf8"));
  const c = dep.contracts;

  console.log(`Network : ${network.name} (chainId ${chainId})`);
  console.log(`Signer  : ${signer.address}`);
  console.log(`Gateway : ${c.MagnetaGateway ?? "(not deployed)"}`);
  console.log(`Swap    : ${c.MagnetaSwap}\n`);

  const gateway = c.MagnetaGateway ? new ethers.Contract(c.MagnetaGateway, GATEWAY_ABI, signer) : null;
  const swap = new ethers.Contract(c.MagnetaSwap, SWAP_ABI, signer);

  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  const call = async (label: string, fn: () => Promise<any>, skipIf: () => Promise<boolean>) => {
    if (await skipIf()) {
      console.log(`  ✓ ${label} — already set, skip`);
      return;
    }
    // Retry loop — Polygon public RPCs frequently return stale nonces under load.
    let lastErr: any;
    for (let attempt = 1; attempt <= 6; attempt++) {
      try {
        const tx = await fn();
        await tx.wait();
        console.log(`  ✓ ${label} — tx=${tx.hash}`);
        return;
      } catch (e: any) {
        lastErr = e;
        const msg: string = e?.message ?? String(e);
        if (/nonce too low|replacement transaction underpriced|already known/i.test(msg)) {
          const backoff = 2000 * attempt;
          console.log(`  … ${label} — nonce race, retry ${attempt}/6 in ${backoff}ms`);
          await sleep(backoff);
          continue;
        }
        throw e;
      }
    }
    throw lastErr;
  };

  if (gateway) {
    console.log("── Configuring Gateway ──");
    const moduleMap: [number, string | undefined][] = [
      [0,  c.LPModule], [1,  c.LPModule], [2,  c.LPModule], [3,  c.LPModule],
      [4,  c.TokenOpsModule], [5,  c.TokenOpsModule], [6,  c.TokenOpsModule],
      [7,  c.TokenOpsModule], [8,  c.TokenOpsModule], [9,  c.TokenOpsModule],
      [10, c.TaxClaimModule],
      [11, c.SwapModule], [12, c.SwapModule],
    ];

    for (const [op, mod] of moduleMap) {
      if (!mod) continue;
      await call(
        `setModule(${op}, ${mod})`,
        () => gateway.setModule(op, mod),
        async () => {
          const current: string = await gateway.moduleFor(op);
          return current.toLowerCase() === mod.toLowerCase();
        },
      );
    }

    if (cfg.usdc) {
      await call(
        `Gateway.setUsdc(${cfg.usdc})`,
        () => gateway.setUsdc(cfg.usdc!),
        async () => {
          const current: string = await gateway.usdc();
          return current.toLowerCase() === cfg.usdc!.toLowerCase();
        },
      );
    }

    await call(
      `Gateway.addPauser(${PAUSE_GUARDIAN})`,
      () => gateway.addPauser(PAUSE_GUARDIAN),
      async () => gateway.isPauser(PAUSE_GUARDIAN),
    );

    if (c.LPModule) {
      await call(
        `Swap.setFeeExempt(LPModule, true)`,
        () => swap.setFeeExempt(c.LPModule, true),
        async () => swap.feeExempt(c.LPModule),
      );
    }
  }

  console.log("\n── Configuring Swap ──");
  await call(
    `Swap.addPauser(${PAUSE_GUARDIAN})`,
    () => swap.addPauser(PAUSE_GUARDIAN),
    async () => swap.isPauser(PAUSE_GUARDIAN),
  );

  if (cfg.usdc) {
    await call(
      `Swap.setWhitelistedToken(USDC, true)`,
      () => swap.setWhitelistedToken(cfg.usdc!, true),
      async () => swap.whitelistedTokens(cfg.usdc!),
    );
  }

  console.log("\nDone.");
  console.log("Next: run transferOwnership.ts + configPeers.ts + configCctp.ts");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
