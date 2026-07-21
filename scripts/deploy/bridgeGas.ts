/**
 * Bridge native gas from the CONNECTED chain to another chain via LI.FI, to the
 * same deployer address. Source = --network. Dest + amount via env.
 *
 *   TO_CHAIN=<dstChainId> AMOUNT=<srcNativeAmount> \
 *     pnpm hardhat run scripts/deploy/bridgeGas.ts --network base
 *
 * Waits for the destination to credit (LI.FI status poll). Amounts are in the
 * SOURCE chain's native units.
 */
import { ethers, network } from "hardhat";

const NATIVE = "0x0000000000000000000000000000000000000000";
const TO_CHAIN = Number(process.env.TO_CHAIN || "");
const AMOUNT = process.env.AMOUNT || process.env.POL_AMOUNT || "";

async function main() {
  if (!TO_CHAIN || !AMOUNT) throw new Error("Set TO_CHAIN and AMOUNT env vars");
  const [signer] = await ethers.getSigners();
  const dep = signer.address;
  const FROM_CHAIN = Number((await ethers.provider.getNetwork()).chainId);
  const fromAmount = ethers.parseEther(AMOUNT).toString();

  console.log(`Bridge   : ${AMOUNT} native (chain ${FROM_CHAIN} / ${network.name}) → chain ${TO_CHAIN}  [${dep}]`);

  const url = `https://li.quest/v1/quote?fromChain=${FROM_CHAIN}&toChain=${TO_CHAIN}` +
    `&fromToken=${NATIVE}&toToken=${NATIVE}&fromAmount=${fromAmount}` +
    `&fromAddress=${dep}&toAddress=${dep}&integrator=magneta-finance`;
  const q: any = await (await fetch(url)).json();
  if (!q.transactionRequest) throw new Error(`No route chain ${FROM_CHAIN}->${TO_CHAIN}: ${q.message ?? JSON.stringify(q).slice(0, 300)}`);

  const est = q.estimate;
  console.log(`Route    : ${q.tool} | expect ~${(Number(est.toAmount) / 1e18).toFixed(5)} native on ${TO_CHAIN} (min ${(Number(est.toAmountMin) / 1e18).toFixed(5)})`);

  const tr = q.transactionRequest;
  const tx = await signer.sendTransaction({
    to: tr.to, data: tr.data, value: BigInt(tr.value ?? "0"),
    gasLimit: tr.gasLimit ? (BigInt(tr.gasLimit) * 12n) / 10n : undefined,
  });
  console.log(`Source tx: ${tx.hash} — waiting…`);
  await tx.wait();

  const statusUrl = `https://li.quest/v1/status?fromChain=${FROM_CHAIN}&toChain=${TO_CHAIN}&txHash=${tx.hash}${q.tool ? `&bridge=${q.tool}` : ""}`;
  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
  for (let i = 0; i < 60; i++) {
    await sleep(5000);
    try {
      const s: any = await (await fetch(statusUrl)).json();
      if (s.status === "DONE") {
        const recv = s.receiving?.amount ? Number(s.receiving.amount) / 1e18 : undefined;
        console.log(`✓ DONE. Received ~${recv?.toFixed(5) ?? "?"} native on chain ${TO_CHAIN}. Dest tx: ${s.receiving?.txHash ?? "?"}`);
        return;
      }
      if (s.status === "FAILED") throw new Error(`Bridge FAILED: ${JSON.stringify(s).slice(0, 300)}`);
      console.log(`  [${i}] ${s.status} ${s.substatus ?? ""}`);
    } catch (e: any) { console.log(`  [${i}] poll error: ${e.message}`); }
  }
  console.log(`⚠ status still pending after ~5min — check dest balance manually.`);
}

main().catch((e) => { console.error(e); process.exit(1); });
