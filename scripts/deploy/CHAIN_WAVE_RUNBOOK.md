# Per-chain wave — the sequence, in order

Written 2026-08-03 after Base, the first chain to leave the pre-remediation
code. Every step here exists because skipping it cost something real.

## Before touching anything

1. **Capture the live fee schedule.** Read `opServiceFeeNative(op)` for ops 0-16
   off the CURRENT Gateway and store it. Fees are re-applied by hand after the
   wave; without this snapshot you are guessing. Read each value through TWO
   RPCs — Base's public endpoint returned unreadable values twice mid-operation,
   and a single read would have recorded a fee of zero as fact.
2. **Check the deployer can pay.** ~5.5M gas for the Gateway plus four modules.
   Arbitrum, Cronos and Linea were short on 2026-08-03.
3. **Back up `deployments-b/<net>.json`.** The wave rewrites it.

## The wave

4. **Clear only the five redeployable entries** from the manifest: Gateway,
   LPModule, SwapModule, TaxClaimModule, TokenOpsModule. The script skips
   anything already present, so leaving them in means it does nothing.
   ⚠️ **Leave `MagnetaFactory` in place.** It is above EIP-170 and the wave
   reverts on it. It stays paused, which keeps DLMM creation shut.
5. `pnpm hardhat run scripts/deploy/redeployGatewayWave.ts --network <net>`
   — writes to `deployments-b/`, which is the set the frontend reads.
6. **Verify by selector, not by a successful transaction.** The new stack must
   answer `adminRefundPendingValueOp`, `MAX_OP_SERVICE_FEE_NATIVE_CAP`,
   `withdrawPendingRefund`, `maxSlippageBps`, `repairMarketingWallet`, and the
   guid-carrying `execute` — while the old `execute` selector is GONE.

## Restoring what the wave does not carry over

7. **Re-apply the fee schedule** while the deployer still owns the stack.
   Send them ONE AT A TIME: firing them in a loop produced nonce collisions and
   half of them silently failed. Re-read every op afterwards and compare against
   the snapshot; only a 17/17 match is done.
8. **Initiate ownership transfer** to the Safe on all five (Ownable2Step).

## Two steps the redeploy silently removes — do not skip

9. **Re-grant the breaker's pauser** on the NEW Gateway. The key is registered
   on the retired one, so between the wave and this batch the chain has no
   circuit breaker. Model: `scripts/safe/base-newGateway-addPauser-batch.json`.
10. **Regenerate the breaker baseline** and diff it before shipping: only the
    chain you just did may change `gateway`, `watched` or `modules`. Changes to
    `sources` or `gaps` on other chains are RPC noise and expected.

## Then, and only then

11. Update `lib/constants/gatewayChains.ts` in the tokens repo, deploy the site,
    and confirm the served bundle carries the new address and no longer the old.
12. Safe batch: `setFeeExempt(newLPModule, true)` on the kept MagnetaSwap, plus
    `acceptOwnership()` on all five.
