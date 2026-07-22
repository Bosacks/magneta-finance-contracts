/**
 * Verify the deployments-b contract sources on the chain's explorer.
 * Reconstructs constructor args from deployments-b/<network>.json (same values
 * the B deploy scripts used). Failures are reported, not fatal — some
 * explorers lack API support.
 *   pnpm hardhat run scripts/deploy/verifyB.ts --network <chain>
 */
import { network, run } from "hardhat";
import * as fs from "node:fs";
import * as path from "node:path";

const DEPLOYER = "0x620684F822da9adF36F41e3554791D889947e25E";

async function main() {
  const dep = JSON.parse(
    fs.readFileSync(path.join(__dirname, "..", "..", "deployments-b", `${network.name}.json`), "utf8")
  );
  const c = dep.contracts;
  const cfg = dep.chainConfig;
  const kept = dep.keptFromLive ?? {};

  const targets: Array<[string, string | undefined, unknown[]]> = [
    ["MagnetaGateway", c.MagnetaGateway, [cfg.lzEndpoint, DEPLOYER, dep.feeVault]],
    ["LPModule", c.LPModule, [c.MagnetaGateway, cfg.defaultRouter, cfg.usdc, kept.MagnetaSwap]],
    ["SwapModule", c.SwapModule, [c.MagnetaGateway, cfg.defaultRouter, cfg.usdc]],
    ["TaxClaimModule", c.TaxClaimModule, [c.MagnetaGateway, cfg.defaultRouter, cfg.usdc]],
    ["TokenOpsModule", c.TokenOpsModule, [c.MagnetaGateway, cfg.usdc]],
    ["MagnetaFactory", c.MagnetaFactory, [kept.MagnetaPool, DEPLOYER]],
    ["MagnetaCurveFactory", c.MagnetaCurveFactory, [cfg.defaultRouter, dep.feeVault, DEPLOYER]],
    ["MagnetaProxy", c.MagnetaProxy, [dep.feeVault]],
  ];

  let ok = 0, skip = 0, fail = 0;
  for (const [name, addr, args] of targets) {
    if (!addr) { skip++; continue; }
    try {
      await run("verify:verify", { address: addr, constructorArguments: args });
      console.log(`OK    ${name} ${addr}`);
      ok++;
    } catch (e: any) {
      const msg: string = e.message ?? String(e);
      if (/already.{0,10}verified/i.test(msg)) { console.log(`OK(v) ${name} ${addr}`); ok++; }
      else { console.log(`FAIL  ${name} ${addr}: ${msg.split("\n")[0].slice(0, 120)}`); fail++; }
    }
  }
  console.log(`${network.name}: ${ok} verified, ${skip} absent, ${fail} failed`);
}
main().catch((e) => { console.error(e); process.exit(1); });
