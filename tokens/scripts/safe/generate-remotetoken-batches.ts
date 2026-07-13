/**
 * Bridge canonical-token routes (Sentinelle F22) — Safe batch GENERATOR.
 *
 * Emits, per chain, a Safe batch of `MagnetaBridgeOApp.setRemoteToken(eid,
 * localToken, remote)` calls. F22: the bridge encodes the DESTINATION-chain token
 * address in the payload and rejects any inbound token without a configured route,
 * so EVERY supported (route, token) pair needs a mapping in BOTH directions before
 * the bridge can move that token:
 *   - on the SOURCE chain:      setRemoteToken(dstEid, srcToken, dstToken)
 *   - on the DESTINATION chain: setRemoteToken(srcEid, dstToken, srcToken)
 * Until both exist the bridge reverts ("no canonical token for route" /
 * "unmapped token from source"). Required before opening bridge liquidity.
 *
 * ABI: `function setRemoteToken(uint32,address,address)` — onlyOwner (Safe).
 *
 * USAGE
 *   cd contracts/solidity
 *   cp scripts/safe/remotetoken-routes.template.json scripts/safe/remotetoken-routes.json
 *   # fill per chain: safe, bridge, and one entry per (eid, localToken, remote)
 *   npx hardhat run scripts/safe/generate-remotetoken-batches.ts
 * OUTPUT
 *   scripts/safe/<network>-remotetoken-batch.json
 * No on-chain calls are made.
 */
import { ethers } from "ethers";
import * as fs from "node:fs";
import * as path from "node:path";

const SAFE_DIR = __dirname;
const CONFIG_PATH = path.join(SAFE_DIR, "remotetoken-routes.json");
const TEMPLATE_PATH = path.join(SAFE_DIR, "remotetoken-routes.template.json");
const ZERO = "0x0000000000000000000000000000000000000000";

const bridgeIface = new ethers.Interface([
  "function setRemoteToken(uint32 endpointId, address localToken, address remote)",
]);

interface Route { eid: number; localToken: string; remote: string }
interface ChainEntry { network: string; safe: string; bridge: string; routes: Route[] }
interface SafeTx { to: string; value: string; data: string; contractMethod: null; contractInputsValues: null; }

const isSet = (a?: string) => !!a && ethers.isAddress(a) && a.toLowerCase() !== ZERO;

function loadConfig() {
  const used = fs.existsSync(CONFIG_PATH) ? CONFIG_PATH : TEMPLATE_PATH;
  if (!fs.existsSync(used)) throw new Error(`No routes table at ${CONFIG_PATH} or ${TEMPLATE_PATH}.`);
  return { source: used, chains: JSON.parse(fs.readFileSync(used, "utf-8")).chains as Record<string, ChainEntry> };
}

function main() {
  const { source, chains } = loadConfig();
  console.log(`\n── Bridge setRemoteToken (F22) Safe-batch generator ──`);
  console.log(`Routes table: ${path.relative(process.cwd(), source)}`);
  const generated: string[] = [];
  const skipped: { network: string; chainId: string; reason: string }[] = [];

  for (const [chainId, e] of Object.entries(chains)) {
    const net = e.network ?? `chain-${chainId}`;
    if (!isSet(e.safe)) { skipped.push({ network: net, chainId, reason: "safe blank" }); continue; }
    if (!isSet(e.bridge)) { skipped.push({ network: net, chainId, reason: "bridge blank" }); continue; }

    const txs: SafeTx[] = [];
    for (const r of e.routes ?? []) {
      if (!r || !Number.isInteger(r.eid) || r.eid <= 0) continue;
      if (!isSet(r.localToken) || !isSet(r.remote)) continue; // remote=0 would unmap; require explicit set here
      txs.push({
        to: e.bridge,
        value: "0",
        data: bridgeIface.encodeFunctionData("setRemoteToken", [r.eid, r.localToken, r.remote]),
        contractMethod: null,
        contractInputsValues: null,
      });
    }

    if (txs.length === 0) { skipped.push({ network: net, chainId, reason: "no valid route filled" }); continue; }

    const batch = {
      version: "1.0",
      chainId: String(chainId),
      createdAt: Math.floor(Date.now() / 1000),
      meta: {
        name: `Magneta bridge canonical tokens (F22) — ${net}`,
        description:
          `setRemoteToken on bridge ${e.bridge} for ${txs.length} (eid, localToken) ` +
          `route(s). Remember the REVERSE direction on each peer chain. Sign with Safe ${e.safe}.`,
      },
      transactions: txs,
    };
    const out = path.join(SAFE_DIR, `${net}-remotetoken-batch.json`);
    fs.writeFileSync(out, JSON.stringify(batch, null, 2));
    generated.push(`${net}: ${txs.length} route(s)`);
  }

  console.log(`\nGenerated:\n  ${generated.join("\n  ") || "(none)"}`);
  if (skipped.length) console.log(`\nSkipped:\n  ${skipped.map((s) => `${s.network}: ${s.reason}`).join("\n  ")}`);
}

main();
