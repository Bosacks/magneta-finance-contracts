# Pre-launch wiring audit — 2026-05-20

Two consecutive runs of `scripts/verify-production-wiring.sh` against all
20 EVM mainnet deployments.

## Round 2 (final, after script hardening) — 20 / 20 PASS

Every probed contract on every chain passes every check:

- Bytecode exists at the declared address
- `owner()` resolves to the expected Safe multisig (from `gnosisSafe` in JSON)
- `pauseGuardian()` is the rotated value `0x92F440Bc1f1FaBD6D3e6256491631E07857F4260`
  (post-2026-05-09 rotation propagated cleanly to all 20 chains)
- `paused()` reads false on every contract (not stuck-paused)
- `feeRecipient()` / `feeVault()` matches the declared FeeVault when the
  contract exposes such a getter

Chains tested (in run order):
polygon, arbitrum, base, optimism, bsc, avalanche, linea, mantle,
unichain, sonic, sei, gnosis, celo, flare, monad, berachain, katana,
plasma, abstract, cronos.

Conclusion: **the production wiring of the 20 EVM mainnets is consistent
and ready** from the perspective of owner / guardian / pause / fee-vault
configuration. No JSON corruption, no missed guardian rotation, no
stuck-paused contract.

## Round 1 (initial, with bug) — false positives on 7 chains

The first run reported **7 chains with all addresses returning zero
bytecode**: bsc, avalanche, unichain, sonic, gnosis, celo, berachain.

Diagnosis after investigation: this was a **script bug, not a real
issue**. The script was hitting the Alchemy RPCs declared in `.env`
(via `<CHAIN>_MAINNET_RPC_URL` env vars). For these 7 chains, the env
RPC apparently returns `0x` from `eth_getCode` instead of an HTTP
error — likely because the Alchemy key/app is not configured for those
specific networks (Alchemy supports some chains under particular
plans only). The fallback to public RPC was never triggered because
the env var was set, not empty.

Fix committed in the same run as this doc update:

```bash
# Before (false positives on misconfigured Alchemy chains):
code=$(cast code "$addr" --rpc-url "$rpc")
if [ "$code" = "0x" ]; then fail; fi

# After (defensive double-check):
code=$(cast code "$addr" --rpc-url "$rpc")
if [ "$code" = "0x" ]; then
    code2=$(cast code "$addr" --rpc-url "$fallback_public_rpc")
    if [ "$code2" != "0x" ]; then
        warn "env-var RPC misconfigured for this chain"
        rpc="$fallback_public_rpc"   # use fallback for the rest of checks
    else
        fail  # both agree → real issue
    fi
fi
```

Output during the run now flags the misconfigured chains with a yellow
warning (`env var X_MAINNET_RPC_URL is misconfigured for this chain`)
instead of a red fail. The operator can then check their `.env` against
Alchemy's actual supported chain list.

## Action items still open

1. **Check which chains have misconfigured Alchemy entries** in `.env`.
   Most likely candidates given Alchemy's network catalog as of 2026:
   - Sonic, Berachain, Plasma, Abstract, Cronos, Katana — these are
     newer/less common chains and may not be supported by Alchemy.
   - For unsupported chains, leave the env var unset so the public RPC
     fallback is used. Public Cronos/Sonic/etc. endpoints are reliable
     enough for periodic verification + occasional pause ops.

2. **Document in `.env.example`** which Alchemy chains are
   supported vs which should remain on the public fallback. Avoids
   re-discovery in future audits.

3. **Restart magneta-listener** after fixing `.env` so it stops using
   broken Alchemy endpoints on those 7 chains (impacts watch reliability
   even though the addresses themselves are correct).

## Status of the verification script

The script worked exactly as designed once hardened — caught the false
positive, surfaced the env-var misconfiguration, then passed all 20
chains. Intended runtime use:

- Before any public announcement
- After every contract redeploy
- Quarterly maintenance drill (alongside `pause-guardian-drill.sh`)
- Optionally in CI to gate releases (exit code 1 on any fail)
