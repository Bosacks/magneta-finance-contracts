/**
 * Preflight safety check — run BEFORE deployAll.ts on every chain.
 *
 * Validates that the CHAIN_CONFIG entry for the current network matches
 * on-chain reality. Motivated by the Arbitrum incident where a typo-d
 * LZ endpoint produced 5 orphan contracts (no bytecode check caught it).
 *
 * Checks (in order, short-circuits on fatal):
 *   1. CHAIN_CONFIG entry exists for the current chainId.
 *   2. Deployer balance > 0 (logs it — user decides if it's enough).
 *   3. If lzEndpoint set: code exists at that address (non-empty bytecode).
 *   4. If usdc set: code exists + decimals() returns 6.
 *   5. If defaultRouter set: code exists + factory() returns non-zero.
 *
 * Prints a human-readable plan showing what deployAll will deploy and
 * what it will skip. Non-fatal warnings print in yellow; fatals throw.
 *
 * Usage:
 *   pnpm hardhat run scripts/deploy/preflight.ts --network base
 */
import { ethers, network } from "hardhat";
import { CHAIN_CONFIG } from "./chainConfig";

const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const RESET = "\x1b[0m";

const ok = (msg: string) => console.log(`  ${GREEN}✓${RESET} ${msg}`);
const warn = (msg: string) => console.log(`  ${YELLOW}⚠${RESET}  ${msg}`);
const fail = (msg: string) => console.log(`  ${RED}✗${RESET} ${msg}`);

async function main() {
  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);

  console.log(`\nPreflight check`);
  console.log(`Network  : ${network.name} (chainId ${chainId})`);
  console.log(`Deployer : ${deployer.address}\n`);

  // 1. Config must exist.
  const cfg = CHAIN_CONFIG[chainId];
  if (!cfg) {
    fail(`No CHAIN_CONFIG entry for chainId ${chainId}. Add it to scripts/deploy/chainConfig.ts.`);
    process.exit(1);
  }
  ok(`CHAIN_CONFIG entry found`);

  let fatal = 0;

  // 2. Deployer balance.
  const balance = await ethers.provider.getBalance(deployer.address);
  if (balance === 0n) {
    fail(`Deployer balance is 0 — fund it before deploying.`);
    fatal++;
  } else {
    ok(`Deployer balance: ${ethers.formatEther(balance)} native`);
  }

  // 3. LZ endpoint (only checked if configured).
  if (cfg.lzEndpoint) {
    try {
      const addr = ethers.getAddress(cfg.lzEndpoint);
      const code = await ethers.provider.getCode(addr);
      if (code === "0x" || code === "0x0") {
        fail(`LZ endpoint ${addr} has NO bytecode on this chain. Wrong cluster? Check chainConfig.ts.`);
        fatal++;
      } else {
        ok(`LZ endpoint ${addr} has bytecode (${(code.length - 2) / 2} bytes)`);
      }
    } catch (e: any) {
      fail(`LZ endpoint check failed: ${e?.message ?? e}`);
      fatal++;
    }
    if (cfg.lzEid === null) {
      fail(`lzEndpoint is set but lzEid is null — deploy will fail.`);
      fatal++;
    } else {
      ok(`lzEid: ${cfg.lzEid}`);
    }
  } else {
    warn(`No LZ endpoint — Gateway + BridgeOApp will be SKIPPED`);
  }

  // 4. USDC.
  if (cfg.usdc) {
    try {
      const addr = ethers.getAddress(cfg.usdc);
      const code = await ethers.provider.getCode(addr);
      if (code === "0x" || code === "0x0") {
        fail(`USDC ${addr} has NO bytecode. Wrong address?`);
        fatal++;
      } else {
        const erc20 = new ethers.Contract(
          addr,
          ["function decimals() view returns (uint8)", "function symbol() view returns (string)"],
          ethers.provider,
        );
        const [decimals, symbol] = await Promise.all([erc20.decimals(), erc20.symbol().catch(() => "?")]);
        if (Number(decimals) !== 6) {
          fail(`USDC ${addr} has decimals=${decimals} (expected 6). Wrong token?`);
          fatal++;
        } else {
          ok(`USDC ${addr} ok — symbol=${symbol}, decimals=${decimals}`);
        }
      }
    } catch (e: any) {
      fail(`USDC check failed: ${e?.message ?? e}`);
      fatal++;
    }
  } else {
    warn(`No USDC — TokenOps/TaxClaim modules will be SKIPPED and Swap USDC whitelist will be SKIPPED`);
  }

  // 5. Default router.
  if (cfg.defaultRouter) {
    try {
      const addr = ethers.getAddress(cfg.defaultRouter);
      const code = await ethers.provider.getCode(addr);
      if (code === "0x" || code === "0x0") {
        fail(`Router ${addr} has NO bytecode.`);
        fatal++;
      } else {
        const router = new ethers.Contract(
          addr,
          ["function factory() view returns (address)"],
          ethers.provider,
        );
        try {
          const factoryAddr: string = await router.factory();
          if (factoryAddr === ethers.ZeroAddress) {
            fail(`Router ${addr} factory() returns zero. Probably not a V2 router.`);
            fatal++;
          } else {
            ok(`Router ${addr} ok — factory=${factoryAddr}`);
          }
        } catch {
          warn(`Router ${addr} has code but no factory() — not Uni-V2 compatible. LP/Swap/TaxClaim modules may not work.`);
        }
      }
    } catch (e: any) {
      fail(`Router check failed: ${e?.message ?? e}`);
      fatal++;
    }
  } else {
    warn(`No default router — LP/Swap/TaxClaim modules will be SKIPPED`);
  }

  // ─── Deploy plan summary ───────────────────────────────────────────
  const deployCrossChain = cfg.lzEndpoint !== null && cfg.lzEid !== null;
  const deployRouterModules = cfg.defaultRouter !== null && cfg.usdc !== null;
  const deployTokenOps = cfg.usdc !== null;

  console.log("\nDeploy plan for this network:");
  console.log(`  Core DeFi          : yes (always)`);
  console.log(`  Gateway + Bridge   : ${deployCrossChain ? "yes" : "SKIP (no LZ endpoint)"}`);
  console.log(`  LP/Swap/TaxClaim   : ${deployRouterModules ? "yes" : "SKIP (no router or USDC)"}`);
  console.log(`  TokenOps module    : ${deployTokenOps ? "yes" : "SKIP (no USDC)"}`);
  console.log(`  CCTP config        : ${cfg.cctpDomain !== null ? "yes" : "SKIP (no CCTP domain)"}`);

  console.log();
  if (fatal > 0) {
    console.log(`${RED}${fatal} fatal check(s) failed. Do NOT run deployAll until fixed.${RESET}`);
    process.exit(1);
  }
  console.log(`${GREEN}All checks passed. Safe to run deployAll.ts on ${network.name}.${RESET}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
