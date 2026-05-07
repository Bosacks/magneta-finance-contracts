/**
 * Switch the MagnetaCurveFactory `router` to the locally deployed Magneta AMM
 * router (UniswapV2 fork). New curves created after this call will graduate
 * onto Magneta AMM instead of the external default (QuickSwap, SushiSwap…).
 *
 * Existing curves are unaffected — each `MagnetaCurvePool` reads `router` at
 * construction time and stores it immutably, so curves created BEFORE this
 * call keep their original graduation target.
 *
 * Usage:
 *   pnpm hardhat run scripts/util/setCurveRouterToMagnetaAMM.ts --network polygon
 *   pnpm hardhat run scripts/util/setCurveRouterToMagnetaAMM.ts --network base
 *   ...
 *
 * Reads:
 *   - deployments/{net}.json           → contracts.MagnetaCurveFactory
 *   - deployments/{net}-magneta-amm.json → router
 *
 * Caller must own MagnetaCurveFactory. On chains with Safe ownership, generate
 * a Safe batch instead (see scripts/safe/).
 */
import { ethers, network } from "hardhat";
import fs from "node:fs";
import path from "node:path";

const FACTORY_ABI = [
  "function owner() view returns (address)",
  "function router() view returns (address)",
  "function setRouter(address) external",
  "event RouterUpdated(address oldRouter, address newRouter)",
] as const;

async function main() {
  const [signer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);

  const depPath = path.join(__dirname, "..", "..", "deployments", `${network.name}.json`);
  const ammPath = path.join(__dirname, "..", "..", "deployments", `${network.name}-magneta-amm.json`);
  if (!fs.existsSync(depPath)) throw new Error(`No deployment file for ${network.name}`);
  if (!fs.existsSync(ammPath)) throw new Error(`No Magneta AMM deployment for ${network.name} — run deployMagnetaAMM.ts first`);

  const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
  const amm = JSON.parse(fs.readFileSync(ammPath, "utf8"));

  const factoryAddr: string | undefined = dep?.contracts?.MagnetaCurveFactory;
  const newRouter: string | undefined = amm?.router;
  if (!factoryAddr) throw new Error(`MagnetaCurveFactory not deployed on ${network.name}`);
  if (!newRouter) throw new Error(`Magneta AMM router missing in ${ammPath}`);

  const factory = new ethers.Contract(factoryAddr, FACTORY_ABI, signer);

  const owner: string = await factory.owner();
  const current: string = await factory.router();

  console.log(`\nSigner          : ${signer.address}`);
  console.log(`Network         : ${network.name} (${chainId})`);
  console.log(`Curve factory   : ${factoryAddr}`);
  console.log(`Factory owner   : ${owner}`);
  console.log(`Current router  : ${current}`);
  console.log(`New router (MAG): ${newRouter}\n`);

  if (current.toLowerCase() === newRouter.toLowerCase()) {
    console.log("Router already points to Magneta AMM — nothing to do.");
    return;
  }
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    console.log("Signer is NOT the owner. Generate a Safe batch instead:");
    console.log(JSON.stringify({
      version: "1.0",
      chainId: String(chainId),
      meta: { name: "set curve router to Magneta AMM" },
      transactions: [{
        to: factoryAddr,
        value: "0",
        data: factory.interface.encodeFunctionData("setRouter", [newRouter]),
      }],
    }, null, 2));
    return;
  }

  const tx = await factory.setRouter(newRouter);
  console.log(`Submitted tx: ${tx.hash}`);
  const rcpt = await tx.wait();
  console.log(`Confirmed in block ${rcpt?.blockNumber}\n`);

  const after: string = await factory.router();
  console.log(`Verified router : ${after}\n`);
}

main().catch((e) => { console.error(e); process.exit(1); });
