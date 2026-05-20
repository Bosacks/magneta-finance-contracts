# Security Policy — Magneta Finance

Magneta is a multi-chain DeFi protocol (20 EVM mainnets at the time of
writing) covering token issuance, bonding-curve launchpad, AMM,
cross-chain bridge and routing. The smart contracts in this repository
are deployed in production and hold real user value. We take security
seriously, even though we are pre-audit and operating on a bootstrap
budget.

If you find a vulnerability, **please disclose it to us first** and give
us a fair chance to fix it before going public.

## Reporting a vulnerability

Send your report to one of:

- **Email**: [security@magneta.finance](mailto:security@magneta.finance)
- **GitHub Security Advisory**: open a private advisory at
  https://github.com/Bosacks/magneta-finance-contracts/security/advisories/new
  (encrypted at rest, visible only to maintainers)

Please include:

1. A clear, concise description of the vulnerability.
2. Affected contract(s), chain(s), and address(es) if relevant.
3. Steps to reproduce — Foundry / Hardhat test case is ideal; a written
   walkthrough is fine if you don't have a PoC.
4. Estimated impact (funds at risk, who is affected, preconditions).
5. Suggested mitigation if you have one.
6. **Whether you want to be credited** publicly and under what name.

Please **do not**:

- Open a public GitHub Issue or pull request for security bugs.
- Post the vulnerability on Twitter, Discord, Telegram or anywhere else
  until we have shipped a fix or 90 days have elapsed (see "Disclosure
  timeline" below).
- Exploit the vulnerability beyond what is strictly necessary to prove
  it — withdraw at most one token / one position to demonstrate, then
  stop. Do not move funds you cannot return.
- Run automated scanners (mythril, slither, etc.) against the production
  RPCs — that's a denial-of-service risk and the output is generally
  noise. Run them locally and report only confirmed findings.

We will acknowledge your report **within 72 hours**. If you do not
receive an acknowledgement, ping us politely on Twitter
(`@magnetafinance` — being set up) or open a generic GitHub issue
without details.

## In-scope assets

| Repository | Path | Notes |
|------------|------|-------|
| **magneta-finance-contracts** | `contracts/core/` | MagnetaProxy, MagnetaPool, MagnetaSwap, MagnetaGateway, MagnetaBundler, MagnetaFactory, MagnetaLending, MagnetaDLMM, MagnetaBridgeOApp |
| **magneta-finance-contracts** | `contracts/curve/` | MagnetaCurveFactory, MagnetaCurvePool, MagnetaCurveToken (bonding-curve launchpad) |
| **magneta-finance-contracts** | `contracts/modules/` | LPModule, SwapModule, TokenOpsModule, TaxClaimModule, TokenCreationModule |
| **magneta-finance-contracts** | `contracts/adapters/` | MoeRouterAdapter, TraderJoeAvaxAdapter, UbeswapCeloAdapter, DragonSwapSeiAdapter |
| **deployments** | `deployments/*.json` | Live mainnet addresses are listed here — reports must include the deployed instance you observed the bug on |

## Out of scope

- **Third-party DEX contracts** (PancakeSwap, QuickSwap, Sushi, Uniswap V2/V3,
  TraderJoe, etc.) — we route through them but we don't own them. Report
  to those projects directly.
- **LayerZero V2** infrastructure — same; we deploy OApps on top of
  LayerZero, the underlying messaging is theirs.
- **OpenZeppelin Contracts** — we use them as a base. We pin exact
  versions and never modify their code; report OZ bugs to OpenZeppelin.
- **Front-end repositories** (magneta-finance-tokens, dex, scope,
  terminal) — vulnerabilities in those should go to security@magneta.finance
  too but they're tracked in different SECURITY.md files specific to
  each repo (coming soon).
- **Gas-griefing on user-paid functions** when the round-trip economics
  make the attack unprofitable for the attacker.
- **Best-practice violations without exploit** (e.g. "you could use a
  newer Solidity version") — useful to mention but not bountied.
- **Social engineering, phishing, physical attacks** — out of scope.
- **Attacks on the deployer EOA or Safe signers** off-chain — out of
  scope (their custody is their problem; on-chain consequence may be
  in scope).
- **Known issues** documented in `INCIDENT_RUNBOOK.md` or any open
  GitHub Security Advisory.

## Severity classification

We follow Immunefi's standard
[Vulnerability Severity Classification System](https://immunefi.com/severity-system/)
for smart-contract bugs:

| Severity | Examples |
|----------|----------|
| **Critical** | Direct theft of user funds; permanent freeze of user funds; protocol-wide drain via flash loan or oracle manipulation; unauthorized minting of unlimited supply; bypass of access control (owner, guardian, factory) that enables any of the above. |
| **High** | Theft / loss of user funds requiring specific preconditions; long-term DoS of a core function; bypass of fee capture (drains the FeeVault revenue without taking user funds); incorrect accounting that accumulates over time. |
| **Medium** | Theft of unclaimed yield/fees; short-term DoS; griefing that costs another user significantly more than it costs the attacker. |
| **Low** | Information disclosure of non-public-but-non-sensitive data; minor inconsistencies; griefing where attacker cost ≈ victim cost. |

If a bug straddles two tiers, we'll discuss with the reporter and assume
the higher tier if reasonable.

## Reward structure (current bootstrap phase)

Magneta is pre-token-launch and pre-revenue. We **cannot pay large cash
bounties yet**, and we want to be upfront about that rather than promise
amounts we can't fund.

In exchange for valid disclosures, we currently offer:

- **Public credit** in the fix-commit message and in this repository's
  CONTRIBUTORS / SECURITY HALL OF FAME (below) — under your real name or
  alias of choice.
- **Future MAGNETA token allocation** when the token launches. The
  allocation size will be tied to severity and impact, paid from the
  community / ecosystem allocation. Exact mechanism documented at TGE.
- **Letter of recommendation / reference** for your security CV from us
  if useful to you.
- **Small immediate cash reward** for Critical-severity reports, paid in
  stablecoins from our operating budget: target $500 - $2,000 USDC
  depending on impact and how clean the disclosure is. We will be
  transparent about what we can fund and not promise more than we have.

**Once we generate sustained revenue or complete a token launch**, this
section will be revised to align with industry standards (Immunefi
program: typically $5k - $1M Critical for active DeFi protocols). Early
contributors will be retroactively considered for the larger reward
pool — your disclosure today is not "lost value" because we couldn't
pay full market rate.

## Disclosure timeline

We follow a coordinated-disclosure model:

| Day | Action |
|-----|--------|
| **0** | Report received. Acknowledged within 72h. |
| **0 – 7** | Triage. We assign severity and confirm whether the report is in scope. |
| **7 – 30** | Fix developed. The reporter is invited to review the patch before deployment. |
| **30 – 60** | Patch deployed across affected mainnets. Migration plan if state changes are needed. |
| **60 – 75** | Public post-mortem on Mirror.xyz / blog with credit to the reporter. |
| **75 – 90** | Reporter is free to publish their own write-up after this date. |

We may **extend the embargo by another 30 days** if the fix requires a
coordinated multi-chain deployment that takes longer. We will tell the
reporter as soon as we know.

We may **shorten the embargo** if the vulnerability is actively being
exploited in the wild or if a third party publishes details independently.

If we fail to respond to your report within 14 days, or do not deploy a
fix within 90 days of confirmed receipt, you are free to publish your
findings — but please email us one final notice 48 hours before.

## Safe harbor

We will not pursue legal action against you for security research
conducted in good faith and in accordance with this policy. Specifically,
research that:

1. Stays within the scope defined above.
2. Does not exploit the vulnerability beyond what is necessary to prove
   it.
3. Returns any funds withdrawn from production contracts within 7 days
   of disclosure.
4. Does not publicly disclose the vulnerability before we have shipped
   a fix or the embargo expires.
5. Does not target real user accounts you do not control.

If you accidentally cause a service disruption, downtime or fund movement
while testing in good faith, contact us immediately at
security@magneta.finance — we will work with you to resolve it without
adversarial action.

This safe-harbor language is non-binding outside our jurisdiction; if
you are in a country with strict computer-fraud laws (US CFAA, UK CMA,
EU Cybercrime Convention, etc.), consult counsel before testing.

## Security architecture summary (for researchers)

A few things worth knowing before you start:

- **Access control** flows from a Safe multisig (`gnosisSafe` in each
  `deployments/*.json`) → contract `owner`. A `PauseGuardian` EOA can
  pause but not unpause. See `INCIDENT_RUNBOOK.md` for the operational
  model.
- **Fee capture** runs through `MagnetaProxyV2`, which takes 30 bps
  protocol fee on every routed swap before delegating to the underlying
  V2 router. Bypassing this fee while completing a swap is in-scope.
- **The launchpad** (`MagnetaCurvePool`) graduates to the chain's
  native V2 DEX via `router.addLiquidityETH`, with LP burned to
  `0xDEAD`. Anti-frontrun: pair must be empty or non-existent at
  graduation time. Bypassing this guard is in-scope.
- **Cross-chain** is LayerZero V2 OApp (`MagnetaBridgeOApp`,
  `CreateTokenDispatcher`). Peer wiring is complete on 19/19 chains
  (see git history). Forcing message replay or peer impersonation is
  in-scope.
- **Known divergences** we have already documented but not yet
  audited:
  - `MagnetaSwap` uses a custom `bool paused` instead of OpenZeppelin
    Pausable. Logic looks equivalent, but it's not the canonical
    pattern.
  - `MagnetaBundler` does not expose `paused()` as a getter — we can
    only observe events. If you can derive the pause state from
    storage layout, please mention it.
- **No upgradability** on the core contracts as of 2026-05. Fixes
  require redeployment + migration. Reports of upgrade-key abuse are
  therefore out of scope (no upgrade keys exist).

For a deeper read, the operational runbook is in
[`INCIDENT_RUNBOOK.md`](INCIDENT_RUNBOOK.md).

## Security Hall of Fame

We credit every researcher whose report led to a code change, regardless
of severity.

| Date | Researcher | Severity | Brief |
|------|-----------|----------|-------|
| _(empty — be the first)_ | | | |

## Contact

- **Security disclosures**: [security@magneta.finance](mailto:security@magneta.finance)
- **General support**: [support@magneta.finance](mailto:support@magneta.finance)
- **GitHub Security Advisory** (recommended for sensitive reports):
  https://github.com/Bosacks/magneta-finance-contracts/security/advisories/new

Thank you for helping keep Magneta and its users safe.
