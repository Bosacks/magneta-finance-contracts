# Magneta redeploy wave — runbook (2026-06-30)

_Supersedes the partial `contract-redeploy-runbook.md` (2026-06-25). This covers the
**full** wave: multipauser + A1 atomic LP + A2/A3 fan-out + Sentinelle Tier-1 & Tier-2.
All code is on `security/pause-hardening` (both repos), pushed. **Nothing here is
executed yet** — run it in a dedicated session with the deployer key + gas + Safe access._

> Contracts are immutable: every fix below is INERT until new bytecode is deployed and
> pointed to. The estimated gas for the whole wave is **~$20–40 total** across ~20 chains
> (Ethereum/Rootstock excluded — not deployed). See §8.

---

## 0. What ships in this wave (contract → why)

| Contract (redeploy) | Changes folded in |
|---|---|
| **MagnetaGateway** | multipauser; A2/A3 op `AUTO_FREEZE_RULE_SET=16`; Tier-2 **F38** (per-op fulfillValueOp) |
| **MagnetaBridgeOApp** | multipauser; Tier-2 **F92/F93** (FoT delta, pause `_lzReceive`); Tier-1 **F22** (canonical token map) |
| **MagnetaSwap** | multipauser; Tier-2 **F112** (FoT delta) |
| **MagnetaFactory** | multipauser; EIP-170 compiler override (`runs:1`+strip) |
| **MagnetaPool, MagnetaBundler, MagnetaProxy, MagnetaRouterRegistry** | multipauser |
| **LPModule** | Tier-2 **F7/F52/F53** (dust refund, allowance reset, on-chain fee floor) |
| **TokenOpsModule** | A2/A3 `_setAutoFreezeRule` fan-out |
| **LPAtomicModule / MagnetaLpAtomicHelper** | A1 (new — atomic LP) |
| **MagnetaCurveFactory** | Tier-2 **F80** (graduation ceiling) |
| **MagnetaCurvePool** | Tier-2 **F82/F83/F84** (graduation mins/ETH/monotonic) |
| **ERC20Token** (token template, tokens repo) | Tier-2 **F107** (freeze-revocation) — reaches users via the OFT factories |
| **MAGCronosToken** (Cronos only) | Tier-1 **F113** (replay key) + **F36** (mint cap fail-closed) |

**Excluded from the wave:** MagnetaLending, MagnetaMultiPool, MagnetaFarm, MagnetaDLMM
(marked NOT-FOR-PRODUCTION — their 40 deferred findings are pre-launch backlog), and
**MagnetaXChainLpReceiver** (deprecated — see §7).

---

## 1. Pre-flight (before any tx)

- [ ] Deployer EOA funded on all ~20 target chains (gas is tiny — see §8; keep ~2× buffer).
- [ ] Safe access confirmed per chain: most = `0xC4c9…717a`; Arb/Polygon = `0x4AeA…EC2F`;
      in-house Safe `0x40ea…b297` for Cronos/Abstract/Flare/Sei/Dexalot/Rootstock.
- [ ] **Pauser addresses ready**: the human guardian EOA `0x92F4…4260` AND the OpenZeppelin
      Defender Relayer address (create it first — see `defender-auto-pause-runbook.md`).
- [ ] RPC health green (`@magneta/rpc-proxy` up; `scripts/deploy/preflight.ts`).
- [ ] `git checkout security/pause-hardening` in BOTH repos; `npx hardhat compile` clean.
- [ ] Run the changed-contract tests once green: contracts 123+54, tokens 24+14.

---

## 2. Per-chain deploy (record every address)

Run per chain (full-feature chains; minimal chains skip LP/Swap/Bridge per their existing
deployment profile — see the `infra_*_deployment` notes). Use `scripts/deploy/chainConfig.ts`
as the source of truth for chain params.

1. **Core stack** — `scripts/deploy/deployAll.ts` (Gateway + Swap + Factory + Bundler +
   Pool + Proxy + RouterRegistry). It already calls `addPauser` for the canonical guardian.
2. **BridgeOApp** — its deploy path (LZ OApp; same endpoint `0x1a44…728c`).
3. **Modules** — LPModule (`deployLPModuleSafe.ts`), TokenOpsModule (`deploySeiTokenOps.ts`
   pattern / the module deploy), SwapModule, TaxClaimModule, TokenCreationModule
   (`deployTokenCreation.ts`).
4. **Atomic LP helper (A1)** — `magneta-finance-tokens/contracts/solidity/scripts/deploy-lp-atomic-helper.ts`
   (stateless/ownerless; just deploy + record). Print line for the SDK map (§5).
5. **Curve launchpad** — `scripts/deploy/deployCurveLaunchpad.ts` (CurveFactory + wiring).
6. **Token factories** — `magneta-finance-tokens/.../scripts/batchDeployMagOft.sh` (OFT
   standard factory with the F107 template) + dispatchers
   (`deploy-create-token-dispatcher.ts` / `-v3.ts`).
7. **Adapter** (chain-specific, only where a UniV2 façade is needed): Bex/DragonSwap/Moe/
   TraderJoe/Ubeswap deploy scripts.

→ **Record all new addresses** into `phase1-addresses.template.json`,
`phase2-addresses.template.json`, and the frontend maps (§5). Do NOT lose them — every
wiring step keys off them.

---

## 3. Wiring (Safe batches + owner txs) — the order matters

Generate batches from the recorded addresses, then execute via the Safe (or the in-house
Safe script on no-UI chains).

1. **Multipauser** — on EVERY pausable contract (Gateway, BridgeOApp, Swap, Factory, Pool,
   Bundler, Proxy, modules, CurveFactory, CurvePool): `addPauser(guardian 0x92F4…4260)`
   AND `addPauser(<Defender Relayer>)`. `deployAll.ts` does the guardian for the core it
   deploys; add the Defender Relayer + cover modules/curve. Verify `unpause()` stays Safe-only.
2. **Factory gating (H-2/L-2)** — `dispatcher.setStandardFactory(<new OFT factory>)` per chain.
   Generator + address template live in the **tokens repo**:
   `magneta-finance-tokens/contracts/solidity/scripts/safe/generate-phase1-batches.ts`
   (fill `phase1-addresses.template.json` first; correct selector `0x005fa939`).
3. **Gateway modules** — `Gateway.setModule(opType, module)` for EACH op, **including the new
   `AUTO_FREEZE_RULE_SET = 16`** (A2/A3) and the redeployed LPModule/TokenOpsModule/etc.
4. **LZ peer-wiring** — `setPeer` mesh for Gateway / BridgeOApp / CreateTokenDispatcher.
   Core/bridge peers: `magneta-finance-contracts/scripts/deploy/generatePeerWiringBatches.ts`.
   Dispatcher peers (tokens repo): `contracts/solidity/scripts/safe/generate-phase2-peer-batches.ts`
   (fill `phase2-addresses.template.json`; V2 mesh = 19 chains / 342 wires; V3 = arb/base/polygon).
5. **Bridge canonical tokens (F22 — NEW)** — for each supported bridge route + token:
   `setRemoteToken(eid, localToken, remoteAddress)` **in BOTH directions** (source→dst and
   dst→source), plus the existing `setSupportedToken` / `setBridgeableToken`. **The bridge
   will revert every transfer until these mappings exist** — required before opening liquidity.
6. **Token registration** — confirm the factory auto-`registerToken` works (the gap fix); for
   any token created via the workaround, `registerByTokenOwner` / Safe `registerToken`.
7. **MAGCronos** — see §4.

---

## 4. MAGCronos (Cronos-specific)

- [ ] Deploy `MAGCronosToken` via `magneta-finance-tokens/.../scripts/deploy-mag-cronos.ts`
      (4-arg ctor: admin Safe, relayer, **mintCapPerEpoch > 0** — now enforced, pick a real
      bound — , epochLength).
- [ ] Repoint the off-chain Cronos relayer (`lib/relayer/cronosRelayer.ts`) to the new address.
- [ ] Confirm the relayer holds `MINTER_ROLE`; admin Safe holds `DEFAULT_ADMIN_ROLE`.
- [ ] F36 reminder: a zero cap now = minting DISABLED (kill-switch), never uncapped — never
      deploy/set with 0 unless you intend to halt minting.

---

## 5. Frontend / SDK address updates (post-deploy, then redeploy sites)

- [ ] `magneta-finance-tokens/lib/sdk/lpAtomicSdk.ts` → fill `LP_ATOMIC_HELPER_BY_CHAIN`
      (A1) — until filled, the UI falls back to the V1 sequential flow (safe).
- [ ] `lib/constants/contracts.ts`, `lib/constants/gatewayChains.ts` → new core/module/
      dispatcher addresses (Gateway, Bundler, factories, dispatcher per chain).
- [ ] `lib/sdk/tokenOpsFanoutSdk.ts` already declares `OP_AUTO_FREEZE_RULE_SET = 16` — verify
      it matches the deployed Gateway enum.
- [ ] Bridge route table (whichever config the bridge UI reads) → reflect `setRemoteToken` routes.
- [ ] Redeploy the 3 sites (`deploy.sh` per the VPS pattern). The maintenance-banner UX reads
      the new `paused()` automatically; no extra wiring.

---

## 6. Verification per chain (before declaring done)

- [ ] `paused()` reads false on each core contract; `isPauser(guardian)` and
      `isPauser(relayer)` both true; a `pause()` from the Relayer succeeds on testnet-fork,
      `unpause()` from a non-owner reverts.
- [ ] `Gateway.module(16)` == new TokenOpsModule (A2/A3).
- [ ] One **create-token** (factory → auto-registered → Mint works), one **swap**, one
      **add-LP** (atomic helper path), and — if bridge open — one **bridge** round-trip with
      a mapped token.
- [ ] MAGCronos: a `relayerMint` with a fresh source event succeeds; a re-keyed duplicate
      (same chain/tx/logIndex, different to/amount) reverts.

---

## 7. Ops cleanup (no deploy)

- [ ] **Decommission MagnetaXChainLpReceiver** (gnosis): confirm zero balance, then abandon
      (do NOT redeploy). Remove the dead `lifiLpKeeper` refs from the listener if desired.
- [ ] **OpenZeppelin Defender**: finish the auto-pause wiring (`defender-auto-pause-runbook.md`)
      — Relayer is now a pauser (step 3.1), add Monitor + Action.
- [ ] **Blockaid allowlist + explorer verification** (D1) — kills the MetaMask "deceptive
      request" warning on the LPModule approval. Pure ops, anytime.
- [ ] Regenerate any stale Safe batch JSON with the NEW addresses (the old hand-edited
      `polygon-d3-redeploy-batch.json` had a wrong selector — regenerate, don't reuse).

---

## 8. Cost (estimate, 2026-06-30 gas snapshot)

Whole wave ≈ **$20–40 of gas total** across ~20 chains. Per-chain deploy is ~$0–5
(L2s/alt-L1s); the only would-be-expensive chain (Ethereum ~$67) is **not** deployed.
Wiring txs (addPauser, setModule, setPeer, setRemoteToken) add a modest amount on top.
Re-pull live gas on the deploy day (some chains showed momentary spikes). Monad native (MON)
price was unresolved — budget ~$5–15 there.

---

## Appendix — deferred backlog (NOT this wave)

The 40 DEFERRED findings (MagnetaLending ×10, MultiPool ×9, ETFPool ×8, Farm ×7, ETF/
Factory ×3, StakingRewards ×2, DLMM ×1) and the 21 governance findings (→ Safe **3/5 +
24h timelock**, one project) are tracked in `docs/sentinelle-triage-2026-06-29.md`. They
gate the V1.1 product launches (lending, multi-asset pools, ETF, staking), not this wave.
