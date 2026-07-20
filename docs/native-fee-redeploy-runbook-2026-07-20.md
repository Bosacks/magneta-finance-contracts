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
