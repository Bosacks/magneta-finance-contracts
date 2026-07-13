/**
 * Sprint B — Generate a Safe Transaction Builder batch that configures
 * 2-DVN required security on a single CreateTokenDispatcher (one source
 * chain). Standalone script (not a Hardhat task) so the LZ DevTools dep
 * conflict (see SPRINT_B_2DVN.md) doesn't block us.
 *
 * Strategy
 *   - Read dispatcher + safe + lzEid from deployments-dispatcher/<chain>.json.
 *   - Pull DVN registry + Library addresses from LayerZero's metadata API.
 *   - For each remote chain (the 18 OTHER CreateTokenDispatchers in our
 *     mesh), pick the 2 required DVNs: LayerZero Labs (always) + the best
 *     available alternative present on BOTH chains (Polyhedra > Google >
 *     Chainlink > Nansen > first-non-LZ-Labs match).
 *   - Encode SendUlnConfig + ReceiveUlnConfig via viem.
 *   - Write ONE Safe batch JSON: 1 setConfig call to the source's SendLib
 *     (with 18 ULN + 18 Executor params) + 1 setConfig call to the source's
 *     ReceiveLib (with 18 ULN params).
 *
 * Usage
 *   pnpm tsx scripts/2dvn/generate-2dvn-batch.ts polygon
 *
 * Output
 *   scripts/safe/2dvn-<chain>-batch.json
 *
 * Verify before signing
 *   - Open the JSON in https://app.safe.global → Apps → Transaction Builder
 *   - Each setConfig param should encode a UlnConfig with
 *     requiredDVNCount: 2, requiredDVNs: [<sorted addresses>]
 *   - DVN addresses must be in ASCENDING order (sorted ascending) per
 *     LZ ULN spec, else the lib reverts.
 */

import fs from "node:fs";
import path from "node:path";
import { encodeAbiParameters, encodeFunctionData, type Hex } from "viem";

const REPO_ROOT = path.join(__dirname, "..", "..");
const DISPATCHER_DIR = path.join(REPO_ROOT, "deployments-dispatcher");
const OUTPUT_DIR = path.join(REPO_ROOT, "scripts", "safe");

// LZ V2 endpoint address — DIFFERS PER CHAIN. Three clusters in our mesh:
//   Cluster A (standard): polygon/base/arbitrum/optimism/avalanche/bsc/
//     mantle/celo/gnosis/sei/flare/linea → 0x1a44…E728c
//   Cluster B: monad/unichain/sonic/plasma/katana/berachain → 0x6F47…DD5B
//   Custom: abstract → 0x5c6c…4AE7
// We fetch the real address from LZ /deployments metadata per chain — never
// hardcode here, that's the trap that bricked the first round of batches
// for Cluster B + Abstract (2026-06-04).

const ULN_CONFIG_TYPE = 2;
const EXECUTOR_CONFIG_TYPE = 1;

// Block confirmations to require on both Send + Receive. 15 is the LZ
// default for most EVMs; matches Stargate's production setting.
const CONFIRMATIONS = 15n;

// Max message size cap for the Executor (in bytes). 10000 is the LZ default.
const MAX_MESSAGE_SIZE = 10_000;

// Preferred alternative DVNs in priority order. First match present on
// BOTH source + dest is picked.
const PREFERRED_ALT_DVNS = [
    "Polyhedra",
    "Google Cloud",
    "Chainlink",
    "Nansen",
    "P2P",
    "Horizen",
    "Deutsche Telekom",
];

// LayerZero metadata API endpoints.
const META_BASE = "https://metadata.layerzero-api.com/v1/metadata";

/** Our deployment file names → key used by the LZ /dvns endpoint.
 *  Most chains match 1:1, but a few use shortened keys (e.g. berachain → bera).
 *  Chains entirely missing from /dvns (currently: linea) are flagged with
 *  null and skipped with a clear warning at runtime. */
const DVN_API_KEY_BY_CHAIN: Record<string, string | null> = {
    polygon: "polygon",
    base: "base",
    arbitrum: "arbitrum",
    optimism: "optimism",
    avalanche: "avalanche",
    bsc: "bsc",
    mantle: "mantle",
    celo: "celo",
    gnosis: "gnosis",
    sei: "sei",
    monad: "monad",
    unichain: "unichain",
    sonic: "sonic",
    plasma: "plasma",
    katana: "katana",
    flare: "flare",
    abstract: "abstract",
    berachain: "bera",      // ← LZ key short form
    linea: null,            // ← not exposed in /dvns metadata as of 2026-06-02
    // Linea is also missing from /deployments — see 2dvn-linea-batch.json
    // for the manual minimal batch (setDelegate only, because Linea's default
    // ULN config is already 2-DVN, so the security baseline is met without
    // explicit setConfig calls).
};

/** Our deployment file names → key used by the LZ /deployments endpoint.
 *  Mostly `<name>-mainnet`, except a few chains use the same shortened form
 *  as DVN_API_KEY_BY_CHAIN (e.g. berachain → bera-mainnet). */
function deployKey(chainName: string): string {
    const short = DVN_API_KEY_BY_CHAIN[chainName];
    const base = (short && short !== chainName) ? short : chainName;
    return `${base}-mainnet`;
}

// ────────────────────── LZ metadata types ─────────────────────────

interface DvnInfo {
    canonicalName?: string;
    deprecated?: boolean;
    lzReadCompatible?: boolean;
}

interface ChainDvns {
    dvns: Record<string, DvnInfo>;
}

/** /deployments shape: per-chain there's an array, one entry per LZ version.
 *  The version=2 entry exposes endpointV2 / sendUln302 / receiveUln302 /
 *  executor as plain { address: "0x..." } objects. */
interface LzAddrRef {
    address: string;
}
interface ChainDeploymentV2 {
    eid: number;
    version: number;
    endpointV2?: LzAddrRef;
    sendUln302?: LzAddrRef;
    receiveUln302?: LzAddrRef;
    executor?: LzAddrRef;
}
interface ChainDeploymentBundle {
    chainKey: string;
    deployments: ChainDeploymentV2[];
}

// ────────────────────── helpers ──────────────────────────────────

async function fetchJson<T>(url: string): Promise<T> {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${url} → HTTP ${res.status}`);
    return res.json() as Promise<T>;
}

function loadDispatcher(chainName: string): {
    address: string;
    safe: string;
    chainId: number;
    lzEid: number;
} {
    const file = path.join(DISPATCHER_DIR, `${chainName}.json`);
    if (!fs.existsSync(file)) throw new Error(`No dispatcher deployment at ${file}`);
    const d = JSON.parse(fs.readFileSync(file, "utf-8"));
    const chainId = Number(d.chainId);
    const lzEid = chainName === "polygon" ? 30109
        : chainName === "base" ? 30184
        : chainName === "arbitrum" ? 30110
        : chainName === "avalanche" ? 30106
        : chainName === "optimism" ? 30111
        : chainName === "bsc" ? 30102
        : chainName === "mantle" ? 30181
        : chainName === "celo" ? 30125
        : chainName === "linea" ? 30183
        : chainName === "gnosis" ? 30145
        : chainName === "sei" ? 30280
        : chainName === "monad" ? 30390
        : chainName === "unichain" ? 30320
        : chainName === "sonic" ? 30332
        : chainName === "berachain" ? 30362
        : chainName === "plasma" ? 30383
        : chainName === "katana" ? 30375
        : chainName === "flare" ? 30295
        : chainName === "abstract" ? 30324
        : NaN;
    if (!Number.isFinite(lzEid)) {
        throw new Error(`Unknown lzEid mapping for ${chainName} — extend the inline table`);
    }
    return {
        address: d.createTokenDispatcher,
        safe: d.safe,
        chainId,
        lzEid,
    };
}

function listOtherDispatchers(self: string): string[] {
    return fs.readdirSync(DISPATCHER_DIR)
        .filter((f) => f.endsWith(".json"))
        .map((f) => path.basename(f, ".json"))
        .filter((name) => !name.includes("broken") && name !== self);
}

function pickAltDvn(
    selfDvns: Record<string, DvnInfo>,
    destDvns: Record<string, DvnInfo>,
): { name: string; selfAddr: string; destAddr: string } | null {
    const selfByName = new Map<string, string>();
    for (const [addr, info] of Object.entries(selfDvns)) {
        if (info.deprecated) continue;
        if (info.canonicalName === "LayerZero Labs") continue;
        if (info.canonicalName) selfByName.set(info.canonicalName, addr);
    }
    const destByName = new Map<string, string>();
    for (const [addr, info] of Object.entries(destDvns)) {
        if (info.deprecated) continue;
        if (info.canonicalName === "LayerZero Labs") continue;
        if (info.canonicalName) destByName.set(info.canonicalName, addr);
    }

    // First try the preferred list in priority order
    for (const name of PREFERRED_ALT_DVNS) {
        if (selfByName.has(name) && destByName.has(name)) {
            return { name, selfAddr: selfByName.get(name)!, destAddr: destByName.get(name)! };
        }
    }
    // Fallback: any DVN present on both
    for (const [name, selfAddr] of selfByName) {
        if (destByName.has(name)) {
            return { name, selfAddr, destAddr: destByName.get(name)! };
        }
    }
    return null;
}

function pickLzLabsDvn(dvns: Record<string, DvnInfo>): string | null {
    for (const [addr, info] of Object.entries(dvns)) {
        if (info.deprecated) continue;
        if (info.canonicalName === "LayerZero Labs") return addr;
    }
    return null;
}

/** Encode UlnConfig as bytes for setConfig. Order: confirmations,
 *  requiredDVNCount, optionalDVNCount, optionalDVNThreshold,
 *  requiredDVNs[], optionalDVNs[]. */
function encodeUlnConfig(requiredDVNs: string[]): Hex {
    const sortedRequiredDVNs = [...requiredDVNs].sort((a, b) => a.toLowerCase() < b.toLowerCase() ? -1 : 1);
    return encodeAbiParameters(
        [
            {
                type: "tuple",
                components: [
                    { name: "confirmations", type: "uint64" },
                    { name: "requiredDVNCount", type: "uint8" },
                    { name: "optionalDVNCount", type: "uint8" },
                    { name: "optionalDVNThreshold", type: "uint8" },
                    { name: "requiredDVNs", type: "address[]" },
                    { name: "optionalDVNs", type: "address[]" },
                ],
            },
        ],
        [{
            confirmations: CONFIRMATIONS,
            requiredDVNCount: sortedRequiredDVNs.length,
            optionalDVNCount: 0,
            optionalDVNThreshold: 0,
            requiredDVNs: sortedRequiredDVNs as `0x${string}`[],
            optionalDVNs: [] as `0x${string}`[],
        }],
    );
}

function encodeExecutorConfig(executor: string): Hex {
    return encodeAbiParameters(
        [
            {
                type: "tuple",
                components: [
                    { name: "maxMessageSize", type: "uint32" },
                    { name: "executor", type: "address" },
                ],
            },
        ],
        [{
            maxMessageSize: MAX_MESSAGE_SIZE,
            executor: executor as `0x${string}`,
        }],
    );
}

const ENDPOINT_SET_CONFIG_ABI = [
    {
        type: "function",
        name: "setConfig",
        stateMutability: "nonpayable",
        inputs: [
            { name: "oapp", type: "address" },
            { name: "lib", type: "address" },
            {
                name: "params",
                type: "tuple[]",
                components: [
                    { name: "eid", type: "uint32" },
                    { name: "configType", type: "uint32" },
                    { name: "config", type: "bytes" },
                ],
            },
        ],
        outputs: [],
    },
] as const;

// OAppCore.setDelegate(address) — onlyOwner. Promotes the Safe to be the
// LZ delegate so it can call endpoint.setConfig. Must run FIRST in every
// 2-DVN batch: when the dispatcher was deployed, the EOA deployer was set
// as delegate by default; ownership was transferred to Safe but delegate
// stayed as EOA. Without this, every endpoint.setConfig reverts with
// LZ_Unauthorized. Idempotent (no-op if delegate already == Safe).
const OAPP_SET_DELEGATE_ABI = [
    {
        type: "function",
        name: "setDelegate",
        stateMutability: "nonpayable",
        inputs: [{ name: "_delegate", type: "address" }],
        outputs: [],
    },
] as const;

// ─────────────────────── main ────────────────────────────────────

async function main() {
    const target = process.argv[2];
    if (!target) {
        console.error("Usage: pnpm tsx scripts/2dvn/generate-2dvn-batch.ts <chainName>");
        console.error("       (e.g. polygon, base, arbitrum, …)");
        process.exit(1);
    }

    const self = loadDispatcher(target);
    console.log(`\n── 2-DVN batch for ${target} ──`);
    console.log(`   dispatcher: ${self.address}`);
    console.log(`   safe:       ${self.safe}`);
    console.log(`   lzEid:      ${self.lzEid}`);

    console.log(`\n── Fetching LZ metadata (DVNs + libraries) ──`);
    const allDvns = await fetchJson<Record<string, ChainDvns>>(`${META_BASE}/dvns`);
    const allDeploys = await fetchJson<Record<string, ChainDeploymentBundle>>(`${META_BASE}/deployments`);

    // API uses two different keying schemes: bare `polygon` for /dvns,
    // `polygon-mainnet` for /deployments. Translate target → both.
    const selfDvnKey = DVN_API_KEY_BY_CHAIN[target];
    if (selfDvnKey === undefined) throw new Error(`Add ${target} to DVN_API_KEY_BY_CHAIN`);
    if (selfDvnKey === null) throw new Error(`${target} has no DVN metadata in the LZ API — cannot generate as source. Run from a chain that has metadata, with ${target} on the peer side.`);
    const selfDvns = allDvns[selfDvnKey]?.dvns;
    const selfDeployBundle = allDeploys[deployKey(target)];
    if (!selfDvns) throw new Error(`No DVN metadata for ${target}`);
    if (!selfDeployBundle) throw new Error(`No deployment metadata for ${target}-mainnet`);

    const v2 = selfDeployBundle.deployments.find((d) => d.version === 2);
    if (!v2) throw new Error(`No LZ V2 deployment for ${target}-mainnet`);
    const lzEndpointV2 = v2.endpointV2?.address;
    const sendUln302 = v2.sendUln302?.address;
    const receiveUln302 = v2.receiveUln302?.address;
    const executor = v2.executor?.address;
    if (!lzEndpointV2 || !sendUln302 || !receiveUln302 || !executor) {
        throw new Error(`Missing endpoint/library/executor addresses for ${target}-mainnet`);
    }
    const lzLabsSelf = pickLzLabsDvn(selfDvns);
    if (!lzLabsSelf) throw new Error(`No LayerZero Labs DVN on ${target}`);

    console.log(`   endpointV2:    ${lzEndpointV2}`);
    console.log(`   sendUln302:    ${sendUln302}`);
    console.log(`   receiveUln302: ${receiveUln302}`);
    console.log(`   executor:      ${executor}`);
    console.log(`   LZ Labs DVN:   ${lzLabsSelf}`);

    // ─── Build per-peer configs ────────────────────────────────────
    const others = listOtherDispatchers(target);
    console.log(`\n── Building configs for ${others.length} peers ──`);

    const sendParams: { eid: number; configType: number; config: Hex }[] = [];
    const recvParams: { eid: number; configType: number; config: Hex }[] = [];
    const auditLog: { peer: string; eid: number; altDvn: string }[] = [];

    for (const peer of others) {
        let peerMeta;
        try {
            peerMeta = loadDispatcher(peer);
        } catch (e: unknown) {
            console.log(`   skip ${peer}: ${e instanceof Error ? e.message : e}`);
            continue;
        }
        const peerDvnKey = DVN_API_KEY_BY_CHAIN[peer];
        if (peerDvnKey === undefined) {
            console.log(`   skip ${peer}: not registered in DVN_API_KEY_BY_CHAIN (add it to the script)`);
            continue;
        }
        if (peerDvnKey === null) {
            console.log(`   skip ${peer}: LZ /dvns metadata gap — peer needs a manual override`);
            continue;
        }
        const peerDvns = allDvns[peerDvnKey]?.dvns;
        if (!peerDvns) {
            console.log(`   skip ${peer}: no DVN metadata (key=${peerDvnKey})`);
            continue;
        }
        const lzLabsPeer = pickLzLabsDvn(peerDvns);
        if (!lzLabsPeer) {
            console.log(`   skip ${peer}: no LZ Labs DVN on the peer side`);
            continue;
        }
        const alt = pickAltDvn(selfDvns, peerDvns);
        if (!alt) {
            console.log(`   skip ${peer}: no common alt DVN with ${target}`);
            continue;
        }

        const sendUln = encodeUlnConfig([lzLabsSelf, alt.selfAddr]);
        const recvUln = encodeUlnConfig([lzLabsSelf, alt.selfAddr]);
        const execCfg = encodeExecutorConfig(executor);

        sendParams.push(
            { eid: peerMeta.lzEid, configType: EXECUTOR_CONFIG_TYPE, config: execCfg },
            { eid: peerMeta.lzEid, configType: ULN_CONFIG_TYPE, config: sendUln },
        );
        recvParams.push({ eid: peerMeta.lzEid, configType: ULN_CONFIG_TYPE, config: recvUln });

        auditLog.push({ peer, eid: peerMeta.lzEid, altDvn: alt.name });
        console.log(`   ✓ ${peer.padEnd(12)} eid=${peerMeta.lzEid} alt=${alt.name}`);
    }

    if (sendParams.length === 0) {
        throw new Error("No peers configured — abort");
    }

    // ─── Build Safe batch JSON ─────────────────────────────────────
    const setDelegateData = encodeFunctionData({
        abi: OAPP_SET_DELEGATE_ABI,
        functionName: "setDelegate",
        args: [self.safe as `0x${string}`],
    });
    const sendData = encodeFunctionData({
        abi: ENDPOINT_SET_CONFIG_ABI,
        functionName: "setConfig",
        args: [self.address as `0x${string}`, sendUln302 as `0x${string}`, sendParams],
    });
    const recvData = encodeFunctionData({
        abi: ENDPOINT_SET_CONFIG_ABI,
        functionName: "setConfig",
        args: [self.address as `0x${string}`, receiveUln302 as `0x${string}`, recvParams],
    });

    const batch = {
        version: "1.0",
        chainId: String(self.chainId),
        createdAt: 1780500000, // fixed timestamp so replays produce identical files
        meta: {
            name: `Magneta 2-DVN config — ${target}`,
            description:
                `Sets requiredDVNCount=2 (LayerZero Labs + per-peer best alt) on the ` +
                `CreateTokenDispatcher's SendUln302 and ReceiveUln302 channels for ` +
                `${sendParams.length / 2} peers. Prepends dispatcher.setDelegate(safe) ` +
                `so the Safe is authorized as the LZ delegate (deployer EOA was the ` +
                `default delegate from constructor — this fixes that). See ` +
                `scripts/2dvn/generate-2dvn-batch.ts for the DVN selection algorithm. ` +
                `Sign with the Magneta Safe ${self.safe}.`,
        },
        transactions: [
            // Tx 1 — promote Safe to LZ delegate (idempotent if already set)
            {
                to: self.address,
                value: "0",
                data: setDelegateData,
                contractMethod: null,
                contractInputsValues: null,
            },
            // Tx 2 — configure 2-DVN on SendUln302
            {
                to: lzEndpointV2,
                value: "0",
                data: sendData,
                contractMethod: null,
                contractInputsValues: null,
            },
            // Tx 3 — configure 2-DVN on ReceiveUln302
            {
                to: lzEndpointV2,
                value: "0",
                data: recvData,
                contractMethod: null,
                contractInputsValues: null,
            },
        ],
    };

    if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });
    const outPath = path.join(OUTPUT_DIR, `2dvn-${target}-batch.json`);
    fs.writeFileSync(outPath, JSON.stringify(batch, null, 2));

    console.log(`\n── Audit log (DVN selection per peer) ──`);
    for (const a of auditLog) {
        console.log(`   ${a.peer.padEnd(12)} eid=${String(a.eid).padEnd(6)} alt=${a.altDvn}`);
    }
    console.log(`\n── DONE ──`);
    console.log(`   Batch written: ${outPath}`);
    console.log(`   Transactions:  3 (setDelegate + sendLib setConfig + receiveLib setConfig)`);
    console.log(`   Send params:   ${sendParams.length} (Executor + ULN per peer)`);
    console.log(`   Recv params:   ${recvParams.length} (ULN per peer)`);
    console.log(`\n   Next step:`);
    console.log(`     1. Upload to Safe ${self.safe} via Transaction Builder app`);
    console.log(`     2. Review each setConfig param (verify DVN addresses sorted ascending)`);
    console.log(`     3. Sign + execute (2/2 multi-sig)`);
    console.log(`     4. Verify with LayerZero Scan: each peer pathway should show 2 required DVNs`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
