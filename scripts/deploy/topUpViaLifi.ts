/**
 * One-off: top up the deployer's CRO gas on Cronos by bridging a small amount
 * of POL from Polygon via LI.FI (Relay). Needed to finish wirePauserGap.ts on
 * cronos (Bundler + BridgeOApp) — the deployer ran out of CRO there.
 *
 * Run ON POLYGON (the source chain):
 *   pnpm hardhat run scripts/deploy/topUpCronosViaLifi.ts --network polygon
 *
 * Amount via env POL_AMOUNT (default 5). Idempotent-ish: safe to re-run, it just
 * bridges again — check CRO balance first if unsure.
 */
import { ethers, network } from "hardhat";

const FROM_CHAIN = 137;   // Polygon
const TO_CHAIN = Number(process.env.TO_CHAIN || "25");
const NATIVE = "0x0000000000000000000000000000000000000000";
const POL_AMOUNT = process.env.POL_AMOUNT || "5";

async function main() {
  if (network.name !== "polygon") throw new Error(`Run with --network polygon (got ${network.name})`);
  const [signer] = await ethers.getSigners();
  const dep = signer.address;
  const fromAmount = ethers.parseEther(POL_AMOUNT).toString();

  console.log(`Deployer : ${dep}`);
  console.log(`Bridging : ${POL_AMOUNT} POL (Polygon) → CRO (Cronos) via LI.FI\n`);

  const url = `https://li.quest/v1/quote?fromChain=${FROM_CHAIN}&toChain=${TO_CHAIN}` +
    `&fromToken=${NATIVE}&toToken=${NATIVE}&fromAmount=${fromAmount}` +
    `&fromAddress=${dep}&toAddress=${dep}&integrator=magneta-finance`;
  const q: any = await (await fetch(url)).json();
  if (!q.transactionRequest) throw new Error(`No route: ${q.message ?? JSON.stringify(q).slice(0, 300)}`);

  const est = q.estimate;
  console.log(`Route    : ${q.tool}`);
  console.log(`Expected : ~${(Number(est.toAmount) / 1e18).toFixed(3)} CRO (min ${(Number(est.toAmountMin) / 1e18).toFixed(3)})`);

  const tr = q.transactionRequest;
  const tx = await signer.sendTransaction({
    to: tr.to,
    data: tr.data,
    value: BigInt(tr.value ?? "0"),
    // Let ethers/provider populate EIP-1559 fees; keep LI.FI's gasLimit with buffer.
    gasLimit: tr.gasLimit ? (BigInt(tr.gasLimit) * 12n) / 10n : undefined,
  });
  console.log(`\nSource tx: ${tx.hash}`);
  const rcpt = await tx.wait();
  console.log(`Confirmed on Polygon (block ${rcpt?.blockNumber}). Polling destination…\n`);

  // Poll LI.FI status until the bridge completes on Cronos.
  const statusUrl = `https://li.quest/v1/status?fromChain=${FROM_CHAIN}&toChain=${TO_CHAIN}&txHash=${tx.hash}${q.tool ? `&bridge=${q.tool}` : ""}`;
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  for (let i = 0; i < 40; i++) {
    await sleep(6000);
    try {
      const s: any = await (await fetch(statusUrl)).json();
      const st = s.status;
      const sub = s.substatus ?? "";
      console.log(`  [${i}] status=${st} ${sub}`);
      if (st === "DONE") {
        const recv = s.receiving?.amount ? Number(s.receiving.amount) / 1e18 : undefined;
        console.log(`\n✓ Bridge DONE. Received ${recv ?? "?"} CRO on Cronos. Dest tx: ${s.receiving?.txHash ?? "?"}`);
        return;
      }
      if (st === "FAILED") throw new Error(`Bridge FAILED: ${JSON.stringify(s).slice(0, 300)}`);
    } catch (e: any) {
      console.log(`  [${i}] status check retry (${e?.message ?? e})`);
    }
  }
  console.log("\n⚠ Timed out polling status — source tx is confirmed; check CRO balance on Cronos directly.");
}

main().catch((e) => { console.error(e); process.exit(1); });
