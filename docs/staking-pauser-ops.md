# Staking — pause & pauser operations

_Last updated: 2026-07-05 (branch `security/pause-hardening`)._

## Pause model

`MagnetaMasterChef`, `MagnetaStakingRewards` and `MagnetaStakingFactory` use the
repo-standard multi-pauser pattern (same as `MagnetaFactory` / `MagnetaGateway`):

- `pause()` — callable by the **owner or any registered pauser** (`isPauser`).
- `unpause()` — **owner only** (Safe).
- `addPauser(addr)` / `removePauser(addr)` — owner only.

`whenNotPaused` gates **fund-entry only**: `deposit` (MasterChef), `stake`
(StakingRewards), `createStakingPool` (Factory). Exits are **never** blocked:
`withdraw`, `emergencyWithdraw`, `getReward` and `exit` stay callable while
paused, including the `withdraw(pid, 0)` harvest idiom on MasterChef.

## Operational gap to remember: factory-created pools

`MagnetaStakingFactory.createStakingPool` deploys a new `MagnetaStakingRewards`
**owned by its creator**, with **no pauser registered**:

- The protocol pauser (guardian EOA / Defender relayer) has **no pause rights**
  on user-created pools unless the pool owner opts in via `addPauser`.
- Pausing the Factory only stops **new pool creation**; it does not affect
  already-deployed pools.

For protocol-operated pools (deployed by us, e.g. via
`deployMasterChefAndSetup.ts`), the deploy/wiring checklist must include:

1. `addPauser(<guardian>)` (and Defender relayer once provisioned) on each pool.
2. `transferOwnership(<chain Safe>)` + Safe-side `acceptOwnership()`
   (contracts are `Ownable2Step`).

Add these two calls to the per-chain Safe batches the same way the core
contracts' `addPauser` batches were generated (`scripts/safe/populate-pauser-table.js`).
