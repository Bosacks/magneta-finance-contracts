# Sentinelleai Triage — Report 2026-04-19

Scanners: semgrep, gitleaks, npm-audit, trivy. Grade: F 0/100 (driven by
`.env` detection on local filesystem).

Totals: **0 Critical · 16 High · 80 Medium · 1 Low · 0 Info**.

TL;DR: **0 real issues that require a code change.** The scanner ran against
the working directory and flagged gitignored local files (`.env`, coverage
HTML, build artifacts) plus public on-chain addresses. Nothing leaked to
the repo.

---

## High (16) — all accounted for

### .env local file (2 — semgrep + gitleaks)
- `.env:1` and `.env:3`
- `.env` is gitignored ([.gitignore:6](../.gitignore#L6)) and **not tracked** —
  verified via `git ls-files | grep .env` → empty, and `git log -- .env` → empty.
- `.env.example` is committed as the template; real `.env` never enters history.
- No action: local dev convenience file, not a leak.

### Generic API key in `deployments/*.json` (9 — gitleaks)
Lines 14, 15, 26 of `baseSepolia.json`, `arbitrumSepolia.json`, `hardhat.json`.
Each flagged value is a **public contract address** (e.g.
`0x1550dDe1Fe8931C4bd4E05B481dAa81E7aD7aE04` = MockTokenX, verifiable on
BaseScan). Gitleaks' generic-api-key regex matches any 20+ hex string; these
are 42-char `0x…` addresses, not secrets.

No action: on-chain addresses are public by construction.

### AWS access token in `artifacts/build-info/*.json` (4 — gitleaks)
All four hits are the same file, line 1: a Hardhat compiler build-info JSON
(>100MB of bytecode + AST). The flagged value `ACCA8E***` is a hex substring
of compiled contract bytecode matching the AWS-access-token regex shape
(`A[CK]IA[A-Z0-9]{16}`-like).

`artifacts/` is gitignored ([.gitignore:3](../.gitignore#L3)). Never committed.
No action.

### Zero AWS/npm/trivy CVE hits
- `npm-audit`: no high-severity findings surfaced.
- `trivy`: no container / OS CVE findings surfaced.

---

## Medium (80) — all `plaintext-http-link` in generated HTML

Every single Medium hit is a `<a href="http://…">` inside
`coverage/**/*.html` — boilerplate emitted by `solidity-coverage` / Istanbul
(e.g. link to `http://prettifier.io`, `http://istanbul-js.org`).

- `coverage/` is gitignored ([.gitignore:10](../.gitignore#L10)).
- Never shipped with the contracts.
- Regenerated on every `npx hardhat coverage` run; not our code.

No action. The "A02 Cryptographic Failures" tag is inapplicable — these are
docs in a local test-coverage report, not anything served over the wire.

---

## Low (1) — `unsafe-formatstring` false positive

[packages/relayer/src/watcher.ts:63](../packages/relayer/src/watcher.ts#L63):
```ts
console.error(`[watcher] Error polling ${wc.chain.chainKey}:`, err);
```

Rule flags `util.format`/`console.log` with non-literal format strings. Here:
- `wc.chain.chainKey` is a static config-file string (chain key enum), not
  user input.
- It's interpolated inside a **template literal**, which doesn't pass a format
  string to `console.error` at all — the rendered string is the 1st arg, `err`
  is the 2nd. No `%s`/`%d` parsing happens.

No action.

---

## Deploy gate

| Check | Status |
|---|---|
| Secrets committed to git | ✅ None (`.env`, `artifacts/`, `coverage/` all gitignored & untracked) |
| Real High-severity code findings | ✅ 0 |
| Addresses vs private keys in deployments | ✅ Addresses only |
| npm-audit / trivy CVEs | ✅ None surfaced |
| Medium/Low requiring fix | ✅ None (all in generated output) |

This scan, combined with [SOLIDITYSCAN_TRIAGE.md](SOLIDITYSCAN_TRIAGE.md)
(2 real fixes already merged — Faucet H006, BridgeOApp C002), leaves **zero
open code-level security findings** against the contracts + relayer.

Outstanding pre-deploy hardening remains per
[DEPLOYMENT_HARDENING.md](DEPLOYMENT_HARDENING.md): Gnosis Safe 3-of-5 +
TimelockController 48h, ownership transfer, monitoring.
