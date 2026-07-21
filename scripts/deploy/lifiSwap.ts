/**
 * Same-chain token swap via LI.FI on the CONNECTED chain (deployer wallet).
 *   FROM_TOKEN=<addr> TO_TOKEN=<addr> AMOUNT_WEI=<int> \
 *     pnpm hardhat run scripts/deploy/lifiSwap.ts --network celo
 * Approves the LI.FI spender then executes the swap. For converting a stranded
 * bridged token (e.g. agEUR) into native-gas token (CELO).
 */
import { ethers, network } from "hardhat";

const FROM = process.env.FROM_TOKEN!;
const TO = process.env.TO_TOKEN!;
const AMOUNT_WEI = process.env.AMOUNT_WEI!;
const ERC20 = ["function approve(address,uint256) returns (bool)", "function allowance(address,address) view returns (uint256)", "function balanceOf(address) view returns (uint256)"];

async function main() {
  if (!FROM || !TO || !AMOUNT_WEI) throw new Error("Set FROM_TOKEN, TO_TOKEN, AMOUNT_WEI");
  const [signer] = await ethers.getSigners();
  const dep = signer.address;
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  console.log(`LI.FI swap on ${network.name} (${chainId}): ${AMOUNT_WEI} of ${FROM} -> ${TO}  [${dep}]`);

  const url = `https://li.quest/v1/quote?fromChain=${chainId}&toChain=${chainId}&fromToken=${FROM}&toToken=${TO}&fromAmount=${AMOUNT_WEI}&fromAddress=${dep}&toAddress=${dep}&integrator=magneta-finance`;
  const q: any = await (await fetch(url)).json();
  if (!q.transactionRequest) throw new Error(`No route: ${q.message ?? JSON.stringify(q).slice(0, 300)}`);
  const spender = q.estimate.approvalAddress ?? q.transactionRequest.to;
  console.log(`Route: ${q.tool} | expect ~${(Number(q.estimate.toAmount) / 1e18).toFixed(3)} out | spender ${spender}`);

  const token = new ethers.Contract(FROM, ERC20, signer);
  const bal = await token.balanceOf(dep);
  if (bal < BigInt(AMOUNT_WEI)) throw new Error(`Insufficient FROM balance: have ${bal}, need ${AMOUNT_WEI}`);
  // Tight EXPLICIT gasPrice — ethers otherwise pads maxFeePerGas ~10x, and some
  // sequencers (Celo, 202 gwei) reject on gasLimit*maxFee > balance even though
  // actual usage is far less. Use the live gasPrice + a small buffer, legacy type.
  const live = (await ethers.provider.getFeeData()).gasPrice ?? 202_000_000_000n;
  const gasPrice = (live * 11n) / 10n;
  console.log(`gasPrice: ${gasPrice / 1_000_000_000n} gwei`);

  const cur = await token.allowance(dep, spender);
  if (cur < BigInt(AMOUNT_WEI)) {
    console.log(`Approving ${spender}…`);
    await (await token.approve(spender, AMOUNT_WEI, { gasLimit: 90000n, gasPrice, type: 0 })).wait();
  }

  const tr = q.transactionRequest;
  const tx = await signer.sendTransaction({
    to: tr.to, data: tr.data, value: BigInt(tr.value ?? "0"),
    gasLimit: tr.gasLimit ? BigInt(tr.gasLimit) : 600000n,
    gasPrice, type: 0,
  });
  console.log(`Swap tx: ${tx.hash} — waiting…`);
  const r = await tx.wait();
  console.log(`✓ swapped (block ${r?.blockNumber}).`);
}
main().catch((e) => { console.error(e); process.exit(1); });
