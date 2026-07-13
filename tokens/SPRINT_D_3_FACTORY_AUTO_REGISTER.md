# Sprint D #3 — Factory auto-register patch + size limit

Handoff notes for the redeploy session.

## What this patch does

Closes the audit finding "Token registration gap" (`infra` memory
`project_token_registration_gap.md`):

- `MagnetaOFTStandardFactory.createOFTStandardToken` and `createForCreator`
  now call `TokenOpsModule.registerByTokenOwner(tokenAddress)` immediately
  after creating the token, wrapped in a low-level `call` (NOT try/catch —
  see size note below) so a misconfigured / not-yet-deployed module never
  bricks paid token creation.
- `MagnetaOFTAutoLiquidityFactory` intentionally left unpatched: AL tokens
  don't route Mint/Update/Freeze through TokenOpsModule (logic baked into
  the token itself), so the gap doesn't apply.

After this lands on mainnet, users no longer hit
`TokenNotRegistered() 0x259ba1ad` reverts when calling Mint / Update /
Freeze via the Magneta-managed UI on a freshly-created token.

## Why low-level call instead of try/catch

The factory is at the Spurious Dragon 24576-byte deployable limit (see
below). `try/catch` pulls in Solidity's error-decoder bytecode (~150
bytes); a `bool ok; address.call(abi.encodeWithSelector(...))` pattern
avoids it. Same defensive intent (failure does not brick token creation),
~150 bytes lighter.

The function selector for `registerByTokenOwner(address)` is hardcoded
to `0x4a4f0aac` — verified by `cast sig "registerByTokenOwner(address)"`.
If the TokenOpsModule signature ever changes, regenerate.

## ✅ Contract-size constraint — RESOLVED (2026-06-03)

Factory compiles to **24572 / 24576 bytes** runtime — **under the
Spurious Dragon limit by 4 bytes**. Redeploy is unblocked.

Total reduction: **1623 bytes saved** from the 26195-byte starting
point (Sprint D #3 patch baseline). Cuts applied in order:

| Cut | Savings | Notes |
|-----|--------:|-------|
| Custom errors (8 require strings → 6 errors) | ~235 | `ZeroAddress`, `InsufficientFee`, `RefundFailed`, `WithdrawFailed`, `NoFees` |
| Factor common deploy → `_deployAndRegister` helper | ~282 | shared by both public + cross-chain entries |
| `evmVersion: "shanghai"` (PUSH0 opcode) | ~239 | safe on all 20 Magneta EVMs (post-Apr 2023) |
| `Ownable2Step` → `Ownable` | ~183 | acceptable — owner is always a Safe multisig in prod |
| Remove `getUserTokens` + `getTokenCount` getters | ~237 | UIs index TokenCreated events instead |
| `userTokens`/`allTokens` → `internal` (drop auto-getters) | ~263 | same — events are the canonical reader |
| `treasury` + `tokenOpsModule` → `internal` | ~180 | admin-only state, not UI-read |
| `createFee` → `constant` (drop `setCreateFee` + `FeeUpdated`) | ~25  | fee never changed in 6 months; redeploy if needed |

`accumulatedFees` + `crossChainCreator` kept as `public` because the
deploy scripts (`deploy-create-token-dispatcher.ts`) and tests
(`test/MagnetaERC20OFT.test.ts`) actively read them.

### Tests — verified passing (2026-06-05)

All 60 tests in `test/MagnetaERC20OFT.test.ts` pass. Two tests needed
`revertedWith` → `revertedWithCustomError` updates to match the new
custom errors (`ZeroAddress` instead of "LZ endpoint cannot be zero
address"; `NoFees` instead of "No fees to withdraw"). The
`getUserTokens` / `getUserTokensPaginated` test is for the LEGACY
`MagnetaTokenFactory` which still retains those getters — no change
needed there. The earlier handoff note suggesting otherwise was wrong.

### Build verification

```bash
cd contracts/solidity
# Temporarily disable LZ DevTools import (dep conflict):
#   line ~6 in hardhat.config.ts → comment `import "@layerzerolabs/toolbox-hardhat";`
npx hardhat compile --force 2>&1 | grep -E "size is|Compiled"
# Expect:
#   Compiled 59 Solidity files successfully (evm targets: paris, shanghai).
# NO "size is X bytes and exceeds" warning.
```

## Rollout (after size is fixed)

20 chains, sequential:

```bash
# For each chain (Polygon, Base, Arbitrum, Optimism, Avalanche, BSC,
# Mantle, Celo, Linea, Gnosis, Sei, Monad, Unichain, Sonic, Berachain,
# Plasma, Katana, Flare, Abstract — Cronos has no OFT factory so skip):
pnpm hardhat run scripts/deploy/deployOFTStandardFactory.ts --network <chain>
```

The deploy script (existing) updates `deployments-oft/<chain>.json` with
the new factory address. Then in the Tokens app repo:

1. Update `lib/constants/gatewayChains.ts` `oftStandardFactory` field for
   each of the 19 chains.
2. Generate 19 Safe batches that:
   - Call `MagnetaOFTStandardFactory.setTokenOpsModule(localTokenOps)` to
     wire the new factory to its local TokenOps module.
   - Call `MagnetaOFTStandardFactory.setCrossChainCreator(localDispatcher)`
     to wire the cross-chain CREATE_TOKEN path.
   - Call `CreateTokenDispatcher.setStdFactory(newFactory)` so cross-chain
     fan-out lands on the new factory.
3. User signs each batch via Safe UI / in-house Safe.
4. Sanity-test a paid Standard token creation on one chain — the new token
   should immediately be Mint/Update/Freeze-capable without an extra
   `registerByTokenOwner` call.

Estimated total: **10-12h** focused (most of it the per-chain deploy +
Safe ceremony, not the contract change which is already done).

## Why ship this patch now (uncompiled-on-mainnet)

The contract change is the correct shape, and the codebase comment now
documents the registration flow correctly. When the size fix lands, the
patch is already in place — no need to re-do the work in a future
session. Committing now also keeps the audit punch-list checked off,
with the size constraint surfaced clearly for the V1.2 redeploy session.

The size warning is **non-blocking for the existing live factories**:
they're already deployed at a smaller bytecode size from an older
codebase state. Today's mainnet users keep using them unchanged.
