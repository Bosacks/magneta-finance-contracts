# Manual audit — MagnetaFactory.sol

**Auditor**: Claude Opus 4.7 (manual review, not commissioned audit)
**Date**: 2026-05-21
**Target**: [`contracts/core/MagnetaFactory.sol`](../contracts/core/MagnetaFactory.sol) (109 lines, commit `e4a6648` baseline)
**Context**: complement to a Sentinelleai Multi-AI Audit scan that ran with the
LLM panel offline (OpenRouter 402 — insufficient credits). This document
captures findings a human reviewer can identify in ~30 minutes so they can
later be compared with a re-run of Sentinelle once the LLM panel is funded.

**Outcome of Sentinelle scan that prompted this review**:
- 1 LOW (SC01 / ZAD-1) — zero-address in `setPauseGuardian` line 97
- All 6 adversarial agents (Developer, Attacker, Economist, Historian,
  Formalist, Judge) **did not run** due to OpenRouter credits exhaustion.

**Outcome of this manual audit**: 1 LOW (same as Sentinelle, now fixed in
the patch series of 2026-05-21) + 9 additional findings across MEDIUM, LOW,
and INFO severities listed below.

---

## Severity classification

Aligned with Immunefi's standard. Reproduced from `SECURITY.md`:

| Severity | Definition |
|----------|-----------|
| Critical | Direct theft of user funds, permanent freeze, full protocol drain |
| High     | Conditional theft / loss; long-term DoS of a core function |
| Medium   | Theft of unclaimed yield/fees; short-term DoS; griefing > 1× attacker cost |
| Low      | Information disclosure; minor inconsistencies; griefing ≈ attacker cost |
| Info     | Code quality, conventions, hardening — not exploitable |

---

## Summary

| # | ID | Severity | Title | Status |
|---|----|----------|-------|--------|
| 1 | MF-1 | LOW    | `setPauseGuardian` accepts zero address (was Sentinelle SC01) | ✅ Fixed 2026-05-21 |
| 2 | MF-2 | MEDIUM | `createMultiPool` swapFee unbounded (token/weight invariants live in MagnetaMultiPool constructor) | ✅ Fixed 2026-05-22 (4ef3940) |
| 3 | MF-3 | MEDIUM | `createDLMMPool` input validation | ✅ Already enforced at MagnetaDLMM constructor (DLMM:101-106) |
| 4 | MF-4 | LOW    | `createStandardPool` zero-address token0/token1 | ✅ Fixed 2026-05-22 (4ef3940) |
| 5 | MF-5 | LOW    | All `create*` functions are permissionless without rate limit or per-creator quota | 🟡 Open (design choice) |
| 6 | MF-6 | LOW    | `pauseGuardian` not initialised in constructor | 🟡 Open |
| 7 | MF-7 | INFO   | `multiPools` / `dlmmPools` arrays grow unbounded | 🟢 Acceptable |
| 8 | MF-8 | INFO   | Constructor uses `_transferOwnership` (single-step) on `Ownable2Step` parent | 🟢 Acceptable |
| 9 | MF-9 | INFO   | No `tokens.length` lower bound on multi-pool creation | 🟡 Open |
| 10 | MF-10 | INFO  | `setPauseGuardian` does not enforce "no-op" detection (emits event on identical guardian) | 🟢 Acceptable |

---

## Findings — detailed

### MF-1 · LOW · `setPauseGuardian` accepts zero address ✅ Fixed

**Location**: `MagnetaFactory.sol:97-101`

**Description**: The pause guardian setter wrote `_guardian` to state without
checking for `address(0)`. An operator slip on the Safe multisig
(autocomplete error, bad transaction-builder UI) could brick the secondary
pause path by setting the guardian to the zero address.

**Impact**: The Safe owner can no longer rely on the guardian to react fast
to an exploit; reaction time degrades from "seconds" (hot EOA) to "minutes"
(multisig coordination). Indirect: increases the window in which a drain
can complete.

**Fix applied (2026-05-21)**: added `require(_guardian != address(0),
"MagnetaFactory: zero guardian");`

**References**:
- Code4rena "nested" 2021-11 (#83): missing zero-address check in setters
- Code4rena "curves" 2024-01 (#1438): no access-control in critical setter

---

### MF-2 · MEDIUM · `createMultiPool` has no input validation

**Location**: `MagnetaFactory.sol:47-57`

**Description**: The factory passes the user-supplied `tokens`, `weights`,
`name`, `symbol`, and `swapFee` straight to the `MagnetaMultiPool`
constructor without any local validation. Missing checks include:

1. **`tokens.length == weights.length`** — mismatched arrays will either
   revert in the constructor (best case) or silently use bogus data
   depending on `MagnetaMultiPool`'s constructor behaviour.
2. **`tokens` contains no `address(0)` and no duplicates** — both produce
   non-functional or trivially-drainable pools.
3. **`weights` sum to a meaningful invariant** (typically `1e18` for
   Balancer-style value-function AMMs) — incorrect sum breaks pricing math.
4. **`swapFee` within sane bounds** (e.g. `<= 1000` bps = 10 %) — an
   unbounded fee can be set to 100 % or more, locking users in.
5. **`tokens.length >= 2`** — at least 2 tokens are required for any AMM
   to make sense (covered separately as MF-9).
6. **`name` / `symbol` reasonable lengths** — gas-griefing via 64 kB string.

**Impact**: deploys non-functional or maliciously-configured pools that may
trap funds when users try to LP into them, or drain via miscalibrated math.
Severity is bumped to MEDIUM (vs LOW) because pool deployments are
permissionless and the bad pool then appears in the on-chain `multiPools`
registry, lending it false legitimacy.

**Recommendation**:

```solidity
function createMultiPool(
    string memory name,
    string memory symbol,
    address[] memory tokens,
    uint256[] memory weights,
    uint256 swapFee
) external whenNotPaused returns (address pool) {
    require(tokens.length >= 2,                 "MagnetaFactory: need 2+ tokens");
    require(tokens.length == weights.length,    "MagnetaFactory: length mismatch");
    require(swapFee <= MAX_SWAP_FEE_BPS,        "MagnetaFactory: fee too high");
    require(bytes(name).length   <= 64,         "MagnetaFactory: name too long");
    require(bytes(symbol).length <= 16,         "MagnetaFactory: symbol too long");

    uint256 weightSum;
    for (uint256 i = 0; i < tokens.length; ++i) {
        require(tokens[i] != address(0), "MagnetaFactory: zero token");
        for (uint256 j = i + 1; j < tokens.length; ++j) {
            require(tokens[i] != tokens[j], "MagnetaFactory: duplicate token");
        }
        weightSum += weights[i];
    }
    require(weightSum == 1e18, "MagnetaFactory: weights must sum to 1e18");
    // ... existing creation logic
}
```

Where `MAX_SWAP_FEE_BPS` is a constant (e.g. `1000` for 10 %).

**References**: same Balancer-style attack patterns documented in Code4rena
across multiple AMM projects (Sushi, Trader Joe, etc.).

---

### MF-3 · MEDIUM · `createDLMMPool` has no input validation

**Location**: `MagnetaFactory.sol:62-74`

**Description**: Same pattern as MF-2. The factory accepts:

- `tokenX`, `tokenY` — no zero check, no `tokenX != tokenY` check
- `binStep` — no range check (extreme values break the DLMM bin math)
- `lpFeeBps` + `protocolFeeBps` — neither individually bounded nor checked
  for `total <= 10000` (100 %)
- `initialActiveId` — no sanity check (DLMM math may overflow at extreme IDs)
- `feeRecipient` — no zero check (fees collected and burned)

**Impact**: same as MF-2 — non-functional or maliciously-configured pools
that appear in the on-chain registry and may attract LPs.

**Recommendation**:

```solidity
function createDLMMPool(
    address tokenX,
    address tokenY,
    uint16 binStep,
    uint16 lpFeeBps,
    uint16 protocolFeeBps,
    uint24 initialActiveId,
    address feeRecipient
) external whenNotPaused returns (address pool) {
    require(tokenX != address(0) && tokenY != address(0), "MagnetaFactory: zero token");
    require(tokenX != tokenY,                              "MagnetaFactory: identical tokens");
    require(feeRecipient != address(0),                    "MagnetaFactory: zero feeRecipient");
    require(binStep >= MIN_BIN_STEP && binStep <= MAX_BIN_STEP, "MagnetaFactory: bin step OOB");
    require(uint256(lpFeeBps) + uint256(protocolFeeBps) <= MAX_TOTAL_FEE_BPS,
            "MagnetaFactory: fees too high");
    // ... existing creation logic
}
```

---

### MF-4 · LOW · `createStandardPool` passes through without local sanity

**Location**: `MagnetaFactory.sol:79-86`

**Description**: This function is a thin wrapper around
`standardPoolManager.createPool(...)`. It performs no local validation
itself, trusting the manager to validate. Defensive programming would add
basic checks here so a buggy or malicious manager-version can't propagate
trash pools through the factory.

**Impact**: low — depends entirely on `MagnetaPool.createPool` validation
(out of scope for this audit). Listing as LOW so it's tracked.

**Recommendation**: at minimum,
`require(token0 != address(0) && token1 != address(0))` and `require(token0
!= token1)` locally.

---

### MF-5 · LOW · Permissionless `create*` without rate limit or per-creator quota

**Location**: `MagnetaFactory.sol:47, 62, 79`

**Description**: The three creation functions are `external` (no
`onlyOwner`). Any address can deploy unlimited pools. The factory pushes
each new pool address into the on-chain `multiPools` / `dlmmPools` arrays
which grow unbounded (see MF-7).

**Impact**: griefing via spam deployment — an attacker can spend a few
hundred dollars in gas to deploy thousands of empty pools, polluting the
on-chain registry. Front-ends that list "all pools" become slow and
expensive to render. Storage costs grow on every chain.

This appears to be a **design choice** consistent with Magneta's
permissionless-pool-factory model (similar to Uniswap V2 factory). If kept,
front-ends should filter pools client-side (e.g. by TVL threshold) rather
than rely on the on-chain registry being curated.

**Recommendation**: either
- accept the design and document it in a header comment, or
- add a minimum-stake requirement (small fee that goes to FeeVault), or
- add a per-`msg.sender` cooldown to discourage scripting.

The minimum-stake variant doubles as monetisation.

---

### MF-6 · LOW · `pauseGuardian` not initialised in constructor

**Location**: `MagnetaFactory.sol:37-42`

**Description**: The constructor sets `standardPoolManager` and the owner
but leaves `pauseGuardian` at its default `address(0)`. Until
`setPauseGuardian` is explicitly called post-deployment, the `pause()`
function falls back to owner-only (the `onlyOwnerOrGuardian` modifier
short-circuits when the second OR is `address(0)`).

**Impact**: a Magneta operator might deploy the factory and forget to
configure the guardian, leaving an unpatched-by-default emergency response
gap. The drill script (`scripts/test/pause-guardian-drill.sh`) and the
production-wiring verifier (`scripts/verify-production-wiring.sh`) catch
this post-hoc, but it would be cheaper to enforce at construction time.

**Recommendation**: add a `_pauseGuardian` parameter to the constructor:

```solidity
constructor(address _standardPoolManager, address _owner, address _pauseGuardian) {
    require(_standardPoolManager != address(0), "Invalid pool manager");
    require(_owner != address(0),               "Invalid owner");
    require(_pauseGuardian != address(0),       "Invalid guardian");
    standardPoolManager = MagnetaPool(_standardPoolManager);
    pauseGuardian       = _pauseGuardian;
    _transferOwnership(_owner);
}
```

If existing deployments need to keep the post-deploy configuration model,
this can be a v2-factory change rather than a hot-patch.

---

### MF-7 · INFO · Unbounded array growth in `multiPools` / `dlmmPools`

**Location**: `MagnetaFactory.sol:16-17, 55, 72`

**Description**: `multiPools.push(pool)` and `dlmmPools.push(pool)` append
without removal. Combined with MF-5 (permissionless creation), the arrays
can grow indefinitely.

**Impact**: pure storage / readability concern. `getPoolCounts()` is O(1)
so the contract itself stays cheap, but any external indexer that
enumerates the arrays via `multiPools(i)` paginates at the front-end's
expense. The Magneta subgraph already indexes pools via events, so this is
unlikely to bite in practice.

**Acceptable as-is** — flag for future review if the registry pattern
changes.

---

### MF-8 · INFO · Constructor uses single-step `_transferOwnership` on `Ownable2Step`

**Location**: `MagnetaFactory.sol:41`

**Description**: `Ownable2Step` introduces a `transferOwnership` /
`acceptOwnership` flow that requires the new owner to actively accept the
transfer. In the constructor, calling `_transferOwnership(_owner)` (the
internal one-step) bypasses the acceptance step.

This is **the canonical pattern** for `Ownable2Step` initialisation —
you can't have a pending acceptance during construction (the contract
doesn't exist yet) — and OpenZeppelin uses it themselves. Listing here
because a junior auditor might flag it as a false positive.

**Acceptable as-is.**

---

### MF-9 · INFO · No `tokens.length` lower bound on `createMultiPool`

**Location**: `MagnetaFactory.sol:50, 54`

**Description**: A user could call `createMultiPool` with `tokens.length ==
0` or `tokens.length == 1`. The `MagnetaMultiPool` constructor likely
reverts in these cases but the factory itself doesn't enforce it. Covered
also by MF-2.

---

### MF-10 · INFO · `setPauseGuardian` always emits, no no-op detection

**Location**: `MagnetaFactory.sol:97-101` (post-fix)

**Description**: Calling `setPauseGuardian(currentGuardian)` (i.e., setting
the guardian to the same address it already is) still emits a
`PauseGuardianUpdated(old, _guardian)` event. Off-chain indexers (the
Magneta listener, etc.) treat this as a "guardian change" which it isn't.

**Impact**: trivial — false-positive in alerting, no on-chain effect.

**Recommendation**: optional. Add
```solidity
require(_guardian != pauseGuardian, "MagnetaFactory: no change");
```
or just accept the noise — the listener can dedupe on the address.

---

## Cross-cutting notes

- **No reentrancy concern** in the create functions: the deployed pools'
  constructors don't call back into the factory (verified by reading
  `MagnetaMultiPool` / `MagnetaDLMM` constructors).
- **Pausable inheritance** is correctly wired (factory pauses → all `create*`
  revert via `whenNotPaused`). The pause-drill confirmed this round-trip
  works in production.
- **No upgradability** — fixes require redeployment + migration of the
  registry. Mitigation: validation can be done off-chain in the front-end
  before any pool creation transaction is submitted (good UX, no
  recompile).

---

## Conclusion

The contract is small (109 lines) and the access-control surface is clean.
The single Sentinelle finding (MF-1) was real and is now fixed. The
remaining 9 findings cluster around the same theme: **`create*` functions
trust their arguments without local validation**. None of them is
exploitable in a "drain user funds" sense — they're brick-the-pool /
griefing-class — but together they justify a defensive-programming pass
before public launch.

**Comparison plane for future Sentinelle re-runs**: once the LLM panel is
funded, re-scan this contract and check whether the 6 adversarial agents
+ Judge converge on the same MF-2/MF-3 cluster of input-validation
findings. If they do, the multi-AI architecture is validated. If they
miss MF-2/MF-3, the prompt design needs to bias more strongly toward
"trust no input" auditing patterns.

---

*Generated 2026-05-21 by manual review. Reproduce: read the contract,
match against the OWASP Smart Contract Top 10 + Code4rena common findings
corpus, write down anything the contract relies on without enforcing.*
