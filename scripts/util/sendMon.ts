import { ethers, network } from "hardhat";

async function main() {
  const TO = process.env.TO!;
  const AMOUNT = process.env.AMOUNT!;
  if (!TO || !AMOUNT) throw new Error("Set TO and AMOUNT env vars");

  const [signer] = await ethers.getSigners();
  const balBefore = await ethers.provider.getBalance(signer.address);
  console.log(`From   : ${signer.address}`);
  console.log(`To     : ${TO}`);
  console.log(`Amount : ${AMOUNT} ETH`);
  console.log(`Balance: ${ethers.formatEther(balBefore)}\n`);

  const tx = await signer.sendTransaction({
    to: TO,
    value: ethers.parseEther(AMOUNT),
  });
  console.log(`Tx     : ${tx.hash}`);
  const r = await tx.wait();
  console.log(`Status : ${r?.status === 1 ? "success" : "FAILED"}`);
  console.log(`Gas    : ${r?.gasUsed.toString()}`);

  const balAfter = await ethers.provider.getBalance(TO);
  console.log(`\nReceiver balance after: ${ethers.formatEther(balAfter)}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
