/**
 * Gas top-up across chains via the LI.FI aggregator.
 *
 * Written 2026-08-03. Our own MagnetaBridgeOApp cannot do this job: it is an
 * ERC-20 bridge (`require(token != address(0))`) with a destination-liquidity
 * requirement, so it can never deliver the NATIVE gas a deployer needs — and on
 * Cronos the gas token is CRO, which no amount of bridged ETH produces.
 * LI.FI routes native->native, including the ETH->CRO swap-and-bridge.
 *
 * Deliberately one chain per invocation. Funding several in a loop is how the
 * Base fee restoration collided on nonces and half-failed in silence.
 *
 * Usage: pnpm tsx scripts/ops/gasTopUpViaLifi.ts <chain> <amountEth> [--execute]
 * Without --execute it quotes and stops.
 */
import { createWalletClient, createPublicClient, http, formatEther, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import * as fs from "fs";
import * as path from "path";

const DEST: Record<string, { id: number; rpc: string; symbol: string }> = {
  arbitrum: { id: 42161, rpc: "https://arb1.arbitrum.io/rpc", symbol: "ETH" },
  linea:    { id: 59144, rpc: "https://rpc.linea.build",      symbol: "ETH" },
  cronos:   { id: 25,    rpc: "https://evm.cronos.org",       symbol: "CRO" },
};
const BASE_RPC = "https://mainnet.base.org";
const NATIVE = "0x0000000000000000000000000000000000000000";
/** Base must keep enough to still pay for fee ops and Safe-adjacent calls. */
const BASE_FLOOR = parseEther("0.0012");

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function loadKey(): `0x${string}` {
  const env = fs.readFileSync(path.join(__dirname, "../../.env"), "utf8");
  const m = env.match(/^DEPLOYER_PRIVATE_KEY=(.+)$/m);
  if (!m?.[1]?.trim()) throw new Error("DEPLOYER_PRIVATE_KEY missing from .env");
  const k = m[1].trim();
  return (k.startsWith("0x") ? k : `0x${k}`) as `0x${string}`;
}

async function main() {
  const [chain, amountEth, ...flags] = process.argv.slice(2);
  const execute = flags.includes("--execute");
  const dest = DEST[chain];
  if (!dest) throw new Error(`unknown chain '${chain}' — expected one of ${Object.keys(DEST).join(", ")}`);

  const account = privateKeyToAccount(loadKey());
  const src = createPublicClient({ transport: http(BASE_RPC) });
  const dst = createPublicClient({ transport: http(dest.rpc) });
  const wallet = createWalletClient({ account, transport: http(BASE_RPC) });

  const amount = parseEther(amountEth);
  const srcBefore = await src.getBalance({ address: account.address });
  const dstBefore = await dst.getBalance({ address: account.address });

  console.log(`déployeur   ${account.address}`);
  console.log(`base        ${formatEther(srcBefore)} ETH`);
  console.log(`${chain.padEnd(11)} ${formatEther(dstBefore)} ${dest.symbol}  (avant)`);

  if (srcBefore - amount < BASE_FLOOR) {
    throw new Error(
      `refus : envoyer ${amountEth} laisserait Base sous son plancher de ${formatEther(BASE_FLOOR)} ETH`,
    );
  }

  const url =
    `https://li.quest/v1/quote?fromChain=8453&toChain=${dest.id}` +
    `&fromToken=${NATIVE}&toToken=${NATIVE}` +
    `&fromAddress=${account.address}&toAddress=${account.address}&fromAmount=${amount}`;
  const quote = await (await fetch(url)).json();
  if (!quote.estimate) throw new Error(`LI.FI a refusé la route : ${quote.message ?? JSON.stringify(quote).slice(0, 200)}`);

  const recv = BigInt(quote.estimate.toAmount);
  console.log(
    `\nroute       ${quote.toolDetails.name} — reçoit ~${formatEther(recv)} ${dest.symbol}` +
      ` ($${Number(quote.estimate.toAmountUSD).toFixed(2)} pour $${Number(quote.estimate.fromAmountUSD).toFixed(2)})`,
  );
  if (!execute) return console.log("\n(cotation seule — relancer avec --execute)");

  const tr = quote.transactionRequest;
  const hash = await wallet.sendTransaction({
    to: tr.to as `0x${string}`,
    data: tr.data as `0x${string}`,
    value: BigInt(tr.value),
    gas: tr.gasLimit ? BigInt(tr.gasLimit) : undefined,
    chain: null,
  });
  console.log(`\nenvoi Base  ${hash}`);
  const receipt = await src.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`la transaction source a échoué : ${hash}`);
  console.log(`            miné bloc ${receipt.blockNumber}`);

  // The source receipt only proves the funds LEFT. What matters is that they
  // ARRIVED, so settle on the destination balance rather than on LI.FI's word.
  console.log(`\nattente de l'arrivée sur ${chain}…`);
  for (let i = 0; i < 60; i++) {
    await sleep(10_000);
    const now = await dst.getBalance({ address: account.address });
    if (now > dstBefore) {
      console.log(`\n✓ arrivé : ${formatEther(dstBefore)} -> ${formatEther(now)} ${dest.symbol}`);
      console.log(`  crédité  +${formatEther(now - dstBefore)} ${dest.symbol}`);
      return;
    }
    const st = await (await fetch(`https://li.quest/v1/status?txHash=${hash}`)).json().catch(() => ({}));
    process.stdout.write(`  ${(i + 1) * 10}s — ${st.status ?? "?"}\r`);
  }
  throw new Error(
    `10 min sans crédit sur ${chain}. La source est minée (${hash}) — vérifier le statut LI.FI à la main avant de renvoyer quoi que ce soit.`,
  );
}

main().catch((e) => {
  console.error(`\n✗ ${e.message}`);
  process.exit(1);
});
