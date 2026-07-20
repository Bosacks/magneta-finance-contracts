# Native-fee / completion redeploy — runbook (2026-07-20)

_Scope determined from the repo on 2026-07-20 (post site-audit session). Supersedes
nothing — this is a NEW wave, distinct from `redeploy-wave-runbook-2026-06-30.md`
(that wave is already deployed 2026-07-03 and Safe-owned 2026-07-09). **Nothing here
is executed yet.**_

> Deployer EOA `0x620684F822da9adF36F41e3554791D889947e25E` (ends `7e25E`) — funded by
> owner 2026-07-20. `DEPLOYER_PRIVATE_KEY` present in local `.env` (len 66). Gas seen:
> Base 0.017 ETH, BSC 0.0006 BNB, Arb 0.0006 ETH; **per-chain top-up verification still
> required** (see §3).

---

## 0. Why this wave exists

The 2026-07-03 hardened wave was deployed BEFORE the native-fee work merged to `main`
(commit `a0751a1`, 2026-07-13). So the live/wave contracts do **not** carry the fee
logic. `pnpm export:abis` shows 3/3 DRIFT (deployed ≠ source). This wave ships the
delta.

## 1. Exact scope (verified via git diff since the deployed wave)

Production contracts changed since 2026-07-03 that are LIVE (present in `deployments/*.json`):

| Contract | Commit | Change | Redeploy? |
|---|---|---|---|
| **MagnetaServiceFee** (NEW) | `a0751a1` | native fee collector for OFF-CHAIN ops (wallet-gen, vanity, snapshots) | **new deploy** (standalone, no cascade) |
| **MagnetaGateway** | `a0751a1` | `opServiceFeeNative` skim of on-chain op fee → FeeVault | **redeploy (immutable, not a proxy)** |
| **LPModule** | `a0751a1` | fee interaction | redeploy (bound to Gateway) |
| **TokenOpsModule** | `a0751a1` | autoFreeze feed + fee | redeploy (`immutable gateway`, ctor asserts `requiredDVNCount`) |
| **MagnetaFactory** | `9f4b042` | factory gate fix | redeploy |
| **MagnetaCurveFactory/Pool** | `9f4b042` | curve fund-lock H-1 | redeploy (pool = per-launch template via factory) |
| **MagnetaProxy** (swap 0.3% proxy) | `f05ff23` | emergency pause | redeploy |

**Out of scope (NOT live — absent from `deployments/*.json`, backlog):** MagnetaMultiPool,
MagnetaMasterChef, MagnetaStakingFactory/Rewards, MagnetaDLMM. AMM V2 sources
(`imports/`, `uniswap/`) and mocks: source-versioning only, already-deployed / test-only.

Completion-wave items folded in (per project notes): CCTP-V2 gap Linea/Sonic (separate
adapter deploy — see `deployCctpV2Adapter.ts`), autoFreeze feed (TokenOpsModule above),
MM boost (config, not a contract).

## 2. THE KEY CONSTRAINT — Gateway is immutable

`MagnetaGateway` has a `constructor(endpoint, delegate, feeVault)` — **no proxy/UUPS**.
Adding the skim = new bytecode = **new Gateway address**. Modules bind to the Gateway at
construction (`TokenOpsModule.gateway` is `immutable`; LPModule/SwapModule are wired to it
by `deployAll`), so a Gateway redeploy **cascades**: redeploy Gateway → redeploy the
modules → re-wire → re-add pauser → transfer to Safe → **frontend cutover** (gatewayChains.ts
+ DEX v2Constants point at the new addresses). This is a Gateway-class wave, per chain,
across ~20 chains. It is NOT a one-shot script.

## 3. Two separable workstreams

**Workstream A — MagnetaServiceFee (LIGHT, low-risk, independent).**
A brand-new standalone contract with **no cascade**: deploy it, set `feeVault`, set
`opFee[opId]` per off-chain op, transfer ownership to Safe, wire the Terminal/listener
reconciliation to its `ServiceFeePaid` events. Does NOT touch Gateway/modules/frontend
swap paths. **No deploy script exists yet — must be written** (`scripts/deploy/deployServiceFee.ts`).
Recommend doing A first, alone, as the low-risk pilot of the whole session.

**Workstream B — Gateway-skim wave redeploy (HEAVY, cascading).**
Gateway + LPModule + TokenOpsModule + Factory + CurveFactory + Proxy, per chain, then
re-wire + pauser + Safe transfer (211-acceptOwnership pattern from the 07-08/09 wave) +
frontend cutover. Mirror `redeploy-wave-runbook-2026-06-30.md` §2–§7 with THIS contract
set. Reuse `deployAll.ts` (conditional per-chain skips), `configureOnly.ts`,
`wirePauserGap.ts`, `transferOwnership.ts`, and the `scripts/safe/wave-accept/` batch
generator.

## 4. Pre-flight (before ANY tx)

- [x] Deployer funded (owner, 2026-07-20) — **but per-chain balances must be re-checked** (§ below).
- [x] `DEPLOYER_PRIVATE_KEY` in local `.env`.
- [ ] **Guardian key rotation** (flagged 2026-07-09: both 2/2 signers transited one machine) — do BEFORE new Safe ops.
- [ ] `npx hardhat compile` clean; changed-contract tests green.
- [ ] Per-chain gas top-up verified (script: extend `preflight.ts`; deploy set is ~5-7 contracts/chain, est. tiny per 06-30 runbook §8 but re-measure — Ethereum/Rootstock excluded).
- [ ] DRY_RUN of `deployAll`/`transferOwnership` per chain (both support DRY_RUN).
- [ ] Native-fee FRONTEND (Ch3) readiness confirmed (Tokens/Terminal) — cutover depends on it.

## 5. Per-chain execution order (Workstream B)

1. `deployAll` (or a scoped deploy) → new Gateway + modules + Factory + CurveFactory + Proxy. Record addresses.
2. `configureOnly` → wire modules ↔ gateway, set peers if Gateway/BridgeOApp changed.
3. Verify on-chain: module `.gateway()` == new Gateway; `requiredDVNCount` OK; opServiceFeeNative unset (default 0 = fee off until explicitly set).
4. `wirePauserGap` → addPauser(guardian) on all new pausables.
5. `transferOwnership` (EOA→Safe) + generate accept batch; owner accepts; verify `owner()==Safe`.
6. Set `opServiceFeeNative[op]` (Safe tx) — fees start OFF (0), enable deliberately after cutover.
7. **Cutover**: update `gatewayChains.ts` (Tokens) + `v2Constants.ts`/bridge maps (DEX) to new addresses; redeploy the 2 frontends; smoke-test.

Do it **one chain at a time**, verifying each step on-chain before the next (project rule).
Keep OLD addresses until the new chain is fully verified + cutover smoke-tested — the
cutover (frontend re-point) is the reversible safety valve; the contracts themselves are not.

## 6. Rollback / safety

- Contracts are immutable — no rollback of a deploy; the reversible control is the
  **frontend cutover** (keep pointing at the old, already-Safe-owned wave until the new
  one is verified per chain).
- Fees ship **OFF** (`opServiceFeeNative` defaults 0) — enabling is a separate, deliberate
  Safe tx after cutover + smoke test. No user pays a fee until then.

## 7. Open decisions for the owner

1. **Do A first, alone?** (recommended — proves the pipeline with a non-cascading contract.)
2. **B scope**: full Gateway wave now, or defer B until the native-fee frontend (Ch3) is
   confirmed ready (cutover needs it)?
3. Guardian rotation before B's Safe transfers — do it first?
4. Pilot chain for B (one cheap chain, full deploy→cutover, verify end-to-end before the other 19)?

---

# APPENDIX — Plan B detail (Gateway skim redeploy) + Ch3 gate

_Added 2026-07-20 after (1) executing Workstream A, (2) verifying the Ch3 frontend._

## B.0 — Ch3 frontend readiness: NOT READY (verified 2026-07-20). B IS GATED ON IT.

The native-fee FRONTEND has not been started (only scaffolding: `lib/constants/serviceFee.ts`
types/ABI, `app/api/service-fee/verify/route.ts`, listener indexing `magneta-listener/src/feesIndexer.ts`,
and the Terminal reconciliation dashboard in `magneta-finance-MagnetaTerminal`). Missing:
1. No `usePayFee` hook / no UI call to `MagnetaServiceFee.payFee(opId)` for the 5 off-chain ops.
2. No frontend caller of `/api/service-fee/verify` (dead from the UI).
3. `MAGNETA_SERVICE_FEE_<chainId>` env vars unset (verify route fails closed) — the 20 addresses
   just deployed (Workstream A) are recorded in `deployments/*.json` but not wired to any frontend.
4. Off-chain op UIs still gated by the legacy `PaymentService`/`TaskQueuePanel` lump-sum flow — must be
   replaced/bridged to the per-op contract.
5. On-chain `opServiceFeeNative`: zero frontend presence — no ABI field, no `value` headroom added in
   `gatewaySdk.ts`/`lpHeadless.ts`. **This is why B must wait**: if B redeploys the Gateway with the skim
   AND someone sets `opServiceFeeNative>0`, live on-chain ops that don't add headroom to `msg.value`
   would REVERT. Safe only while fees stay 0 — but then B delivers no value until the frontend ships.
6. Repo ambiguity: reconciliation lives in `magneta-finance-MagnetaTerminal`, NOT `Terminal-final` —
   confirm which Terminal is live before wiring.

**Recommendation: DO NOT execute B until the Ch3 frontend is built.** B now would only mint new,
unused, fee-off contracts and a cutover with nothing to point at.

## B.1 — Scoped redeploy inventory (verified — NOT a full wave)

Only the contracts changed since the 07-03 wave, plus their forced cascade:
- **MagnetaGateway** (skim) — redeploy (immutable).
- **LPModule**, **TokenOpsModule** — redeploy (bind to Gateway; `TokenOpsModule.gateway` is `immutable`).
- **MagnetaFactory** (gate fix), **MagnetaCurveFactory/Pool** (fund-lock), **MagnetaProxy** (pause) — redeploy.
- **KEEP (unchanged, no Gateway ref — verified: MagnetaPool/Swap/Lending have no `gateway` reference):**
  MagnetaPool, MagnetaSwap, MagnetaLending, MagnetaBundler, MagnetaBridgeOApp. **Do NOT redeploy these**
  — MagnetaPool/Lending hold state/liquidity; a redeploy would orphan it. (The 07-03 wave Pool is not
  cutover — `gatewayChains.ts` doesn't reference it, 0 matches — so it likely holds no frontend liquidity
  today, but keep the rule regardless.)

There is NO built-in "redeploy only Gateway+modules" mode in `deployAll.ts` (it deploys the full set,
gated only by chain-capability flags). So B needs EITHER a new scoped script that deploys only the 6
changed contracts and re-points the Gateway's module map, OR careful use of the existing scripts with
the unchanged contracts' addresses pinned. **Write `scripts/deploy/redeployGatewayWave.ts`** (scoped),
DRY_RUN per chain.

## B.2 — Per-chain sequence (one chain at a time, verify each on-chain)

1. Deploy new Gateway (same constructor args: endpoint, delegate, feeVault) + new LPModule/TokenOpsModule
   + new Factory/CurveFactory/Proxy. Record addresses (do NOT overwrite the kept contracts' entries).
2. `configureOnly.ts` — `gateway.setModule(op, newModule)`, `setUsdc`, `addPauser(guardian)`. Re-point the
   kept Pool/Swap/Bundler at the new Gateway IF they hold a settable gateway ref (verify; they had none in
   source, so likely nothing to do).
3. Verify on-chain: `moduleFor(op)`==new modules; `TokenOpsModule.gateway()`==new Gateway;
   `opServiceFeeNative`==0 (fees off).
4. `wirePauserGap.ts` — pauser on all new pausables.
5. `transferOwnership.ts` (EOA→Safe) + generate accept batch (mirror `scripts/safe/servicefee-accept/`);
   owner accepts; verify `owner()==Safe`.
6. Cutover: update `gatewayChains.ts` (Tokens) + DEX maps to the new Gateway/module/Factory addresses;
   redeploy the 2 frontends; smoke-test. KEEP old addresses until each chain is verified + smoke-tested.
7. Enable fees LAST: `setOpServiceFeeNative[op]` via Safe, only after the frontend adds `value` headroom.

## B.3 — Tooling (reuse) & gas
- Reuse: `configureOnly.ts`, `wirePauserGap.ts`, `transferOwnership.ts`, the wave-accept batch generator.
- New: `redeployGatewayWave.ts` (scoped deploy of the 6 changed contracts), DRY_RUN support.
- Gas: 6 contracts × ~20 chains — small (the full 06-30 wave was est. $20-40; this is less). Re-measure
  per chain in pre-flight; deployer `0x6206…7e25E` is funded (Workstream A left balances; top-up thin L2s).

## B.4 — Prerequisites before executing B
1. **Ch3 frontend built** (B.0) — hard gate.
2. Guardian: history purge done 2026-07-20 (no rotation — key never externally exposed).
3. `redeployGatewayWave.ts` written + DRY_RUN clean per chain.
4. Confirm live Terminal repo (MagnetaTerminal vs Terminal-final).
