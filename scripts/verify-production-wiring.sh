#!/usr/bin/env bash
# Verify Magneta production wiring on every mainnet chain.
#
# Reads `deployments/*.json` to discover the chains and contracts, then
# probes each chain's RPC (from .env via <CHAIN>_MAINNET_RPC_URL with public
# RPC fallback) to confirm:
#
#   1. Contract bytecode exists (no zero-code address).
#   2. `owner()` resolves to the expected Safe multisig (per deployment file).
#   3. `pauseGuardian()` is the EXPECTED rotated value (not the old
#      0x479ED522… nor a zero address).
#   4. `paused()` reads false (so we're not in a stuck-paused state).
#   5. `feeRecipient()` / `feeVault()` matches the expected FeeVault when
#      the contract exposes the getter.
#
# Output is a per-chain summary + a final pass/fail table.  Designed to be
# run before any public announcement, after every contract redeploy, and
# from the runbook as part of pre-launch checklist.
#
# Usage:
#   ./scripts/verify-production-wiring.sh                # all mainnets
#   ./scripts/verify-production-wiring.sh polygon base   # selected chains
#
# Exit code:
#   0 — every probed contract passed every check
#   1 — at least one finding (printed in red); review before launch
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
EXPECTED_GUARDIAN="0x92F440Bc1f1FaBD6D3e6256491631E07857F4260"
OLD_GUARDIAN="0x479ED5228DCcef6CD05C98A5fe81aCF08F2f5998"

# Load .env if present so MAINNET RPCs override the public fallbacks.
[ -f "$(dirname "$0")/../.env" ] && set -a && . "$(dirname "$0")/../.env" && set +a

DEPLOYMENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/deployments"

# Mainnet chains and the env var name that hosts their RPC URL. Order
# matters only for printout. Comment-out a row to skip a chain.
declare -A CHAIN_RPC_ENV=(
    [polygon]="POLYGON_MAINNET_RPC_URL"
    [arbitrum]="ARBITRUM_MAINNET_RPC_URL"
    [base]="BASE_MAINNET_RPC_URL"
    [optimism]="OPTIMISM_MAINNET_RPC_URL"
    [bsc]="BSC_MAINNET_RPC_URL"
    [avalanche]="AVALANCHE_MAINNET_RPC_URL"
    [linea]="LINEA_MAINNET_RPC_URL"
    [mantle]="MANTLE_MAINNET_RPC_URL"
    [unichain]="UNICHAIN_MAINNET_RPC_URL"
    [sonic]="SONIC_MAINNET_RPC_URL"
    [sei]="SEI_MAINNET_RPC_URL"
    [gnosis]="GNOSIS_MAINNET_RPC_URL"
    [celo]="CELO_MAINNET_RPC_URL"
    [flare]="FLARE_MAINNET_RPC_URL"
    [monad]="MONAD_MAINNET_RPC_URL"
    [berachain]="BERACHAIN_MAINNET_RPC_URL"
    [katana]="KATANA_MAINNET_RPC_URL"
    [plasma]="PLASMA_MAINNET_RPC_URL"
    [abstract]="ABSTRACT_MAINNET_RPC_URL"
    [cronos]="CRONOS_MAINNET_RPC_URL"
)

# Public RPC fallback per chain — used when the env var isn't set.
declare -A CHAIN_PUBLIC_RPC=(
    [polygon]="https://polygon-rpc.com"
    [arbitrum]="https://arb1.arbitrum.io/rpc"
    [base]="https://mainnet.base.org"
    [optimism]="https://mainnet.optimism.io"
    [bsc]="https://bsc-dataseed.binance.org"
    [avalanche]="https://api.avax.network/ext/bc/C/rpc"
    [linea]="https://rpc.linea.build"
    [mantle]="https://rpc.mantle.xyz"
    [unichain]="https://mainnet.unichain.org"
    [sonic]="https://rpc.soniclabs.com"
    [sei]="https://evm-rpc.sei-apis.com"
    [gnosis]="https://rpc.gnosischain.com"
    [celo]="https://forno.celo.org"
    [flare]="https://flare-api.flare.network/ext/C/rpc"
    [monad]="https://rpc.monad.xyz"
    [berachain]="https://rpc.berachain.com"
    [katana]="https://rpc.katana.network"
    [plasma]="https://rpc.plasma.to"
    [abstract]="https://api.mainnet.abs.xyz"
    [cronos]="https://evm.cronos.org"
)

# Contracts to probe on each chain. Only ones with the OZ-style getters we
# rely on (`owner`, `pauseGuardian`, `paused`). MagnetaBundler skipped
# because it doesn't expose a public paused() reader (known limitation —
# see INCIDENT_RUNBOOK.md drill history).
PAUSABLE_CONTRACTS=(MagnetaSwap MagnetaPool MagnetaGateway MagnetaFactory MagnetaLending MagnetaBridgeOApp)

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────────────
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
ok()   { printf "      %s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
fail() { printf "      %s✗%s %s\n" "$RED"   "$RESET" "$*"; ANY_FAIL=1; CHAIN_FAIL=1; }
warn() { printf "      %s!%s %s\n" "$YELLOW" "$RESET" "$*"; ANY_WARN=1; }
step() { printf "%s▸ %s%s\n" "$BOLD" "$*" "$RESET"; }

if ! command -v cast >/dev/null 2>&1; then
    echo "cast (foundry) not found. Install: curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found. Install: sudo apt install jq" >&2
    exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Probes
# ─────────────────────────────────────────────────────────────────────────────
ANY_FAIL=0
ANY_WARN=0

# Lower-case helper for address comparison
lc() { echo "${1,,}"; }

# Read a view function on a contract. Returns the value or "ERROR".
cast_call() {
    local addr=$1 sig=$2 rpc=$3
    cast call "$addr" "$sig" --rpc-url "$rpc" 2>/dev/null || echo "ERROR"
}

probe_chain() {
    local chain=$1
    local file="$DEPLOYMENTS_DIR/$chain.json"
    if [ ! -f "$file" ]; then
        printf "%s%s%s — no deployments/%s.json, skipping\n" "$YELLOW" "$chain" "$RESET" "$chain"
        return
    fi

    local env_var="${CHAIN_RPC_ENV[$chain]:-}"
    local rpc="${!env_var:-}"
    [ -z "$rpc" ] && rpc="${CHAIN_PUBLIC_RPC[$chain]:-}"
    if [ -z "$rpc" ]; then
        printf "%s%s%s — no RPC configured (env %s nor public default)\n" "$YELLOW" "$chain" "$RESET" "$env_var"
        return
    fi

    step "$chain  ($([ -n "${!env_var:-}" ] && echo "via env" || echo "public RPC"))"

    local expected_safe expected_fee_vault
    expected_safe=$(jq -r '.gnosisSafe // .safe // .deployer // empty' "$file")
    expected_fee_vault=$(jq -r '.feeVault // empty' "$file")

    if [ -z "$expected_safe" ]; then
        warn "no expected Safe / owner declared in $chain.json — skipping owner check"
    fi

    local CHAIN_FAIL=0
    for cname in "${PAUSABLE_CONTRACTS[@]}"; do
        local addr
        addr=$(jq -r ".contracts.$cname // empty" "$file")
        if [ -z "$addr" ] || [ "$addr" = "null" ]; then
            warn "$cname — not deployed on $chain (skipping)"
            continue
        fi

        # 1. Bytecode exists
        # Defensive double-check: some Alchemy multi-chain keys return `0x`
        # for unsupported chains instead of an HTTP error, producing
        # false-positive "no bytecode" findings. If the primary RPC says
        # empty, retry with the public fallback and only fail if both
        # agree the address has no code.
        local code
        code=$(cast code "$addr" --rpc-url "$rpc" 2>/dev/null || echo "0x")
        if [ "$code" = "0x" ] || [ -z "$code" ]; then
            local fallback_rpc="${CHAIN_PUBLIC_RPC[$chain]:-}"
            if [ -n "$fallback_rpc" ] && [ "$fallback_rpc" != "$rpc" ]; then
                local code2
                code2=$(cast code "$addr" --rpc-url "$fallback_rpc" 2>/dev/null || echo "0x")
                if [ "$code2" != "0x" ] && [ -n "$code2" ]; then
                    # Primary RPC lied; the contract exists. Warn loudly so
                    # the operator fixes the env-var RPC and continue with
                    # the fallback for the rest of this contract's checks.
                    warn "$cname — primary RPC returned 0x but public RPC sees bytecode (env var $env_var is misconfigured for this chain)"
                    rpc="$fallback_rpc"
                    code="$code2"
                fi
            fi
            if [ "$code" = "0x" ] || [ -z "$code" ]; then
                fail "$cname @ $addr — NO BYTECODE on both env and public RPC (address is empty / wrong)"
                continue
            fi
        fi

        # 2. owner()
        if [ -n "$expected_safe" ]; then
            local owner
            owner=$(cast_call "$addr" "owner()(address)" "$rpc")
            if [ "$owner" = "ERROR" ]; then
                warn "$cname — owner() reverted (contract may lack OZ Ownable)"
            elif [ "$(lc "$owner")" = "$(lc "$expected_safe")" ]; then
                ok "$cname owner = expected Safe"
            else
                fail "$cname owner = $owner (expected $expected_safe)"
            fi
        fi

        # 3. pauseGuardian()
        local guardian
        guardian=$(cast_call "$addr" "pauseGuardian()(address)" "$rpc")
        if [ "$guardian" = "ERROR" ]; then
            warn "$cname — pauseGuardian() reverted (no setter on this contract)"
        elif [ "$(lc "$guardian")" = "$(lc "$EXPECTED_GUARDIAN")" ]; then
            ok "$cname pauseGuardian = rotated (✓ post-2026-05-09)"
        elif [ "$(lc "$guardian")" = "$(lc "$OLD_GUARDIAN")" ]; then
            fail "$cname pauseGuardian = OLD ($guardian) — must rotate to $EXPECTED_GUARDIAN"
        elif [ "$(lc "$guardian")" = "0x0000000000000000000000000000000000000000" ]; then
            fail "$cname pauseGuardian = 0x0 (UNSET) — owner-only pause path, slower reaction"
        else
            fail "$cname pauseGuardian = $guardian (unknown — expected $EXPECTED_GUARDIAN)"
        fi

        # 4. paused()
        local paused
        paused=$(cast_call "$addr" "paused()(bool)" "$rpc")
        if [ "$paused" = "ERROR" ]; then
            warn "$cname — paused() reverted (no public getter — verify via events)"
        elif [ "$paused" = "false" ]; then
            ok "$cname paused = false"
        else
            fail "$cname paused = $paused (CONTRACT IS LIVE-PAUSED ON MAINNET)"
        fi

        # 5. feeRecipient / feeVault (best-effort — different contracts use
        # different getter names; we try the common ones and don't fail if
        # none match)
        if [ -n "$expected_fee_vault" ]; then
            local fee
            for sig in "feeRecipient()(address)" "feeVault()(address)" "vault()(address)"; do
                fee=$(cast_call "$addr" "$sig" "$rpc")
                [ "$fee" != "ERROR" ] && [ "$fee" != "0x0000000000000000000000000000000000000000" ] && break
            done
            if [ "$fee" != "ERROR" ] && [ -n "$fee" ] && [ "$fee" != "0x0000000000000000000000000000000000000000" ]; then
                if [ "$(lc "$fee")" = "$(lc "$expected_fee_vault")" ]; then
                    ok "$cname feeRecipient = expected vault"
                else
                    fail "$cname feeRecipient = $fee (expected $expected_fee_vault)"
                fi
            fi
        fi
    done

    if [ "$CHAIN_FAIL" = "0" ]; then
        printf "    %s%s passed all checks%s\n\n" "$GREEN" "$chain" "$RESET"
    else
        printf "    %s%s has FINDINGS — review above%s\n\n" "$RED" "$chain" "$RESET"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
if [ $# -gt 0 ]; then
    SELECTED=("$@")
else
    # All declared chains, in a stable order
    SELECTED=(polygon arbitrum base optimism bsc avalanche linea mantle \
              unichain sonic sei gnosis celo flare monad berachain katana \
              plasma abstract cronos)
fi

printf "%sMagneta production-wiring verification%s — %d chains to probe\n\n" "$BOLD" "$RESET" "${#SELECTED[@]}"
printf "Expected guardian: %s\n" "$EXPECTED_GUARDIAN"
printf "Old (rotated)    : %s\n\n" "$OLD_GUARDIAN"

for c in "${SELECTED[@]}"; do
    probe_chain "$c"
done

# ─────────────────────────────────────────────────────────────────────────────
# Final verdict
# ─────────────────────────────────────────────────────────────────────────────
if [ "$ANY_FAIL" = "1" ]; then
    printf "%s%s✗ At least one finding above. Review before public launch.%s\n" "$BOLD" "$RED" "$RESET"
    exit 1
elif [ "$ANY_WARN" = "1" ]; then
    printf "%s%s⚠ Completed with warnings only — no blocker.%s\n" "$BOLD" "$YELLOW" "$RESET"
    exit 0
else
    printf "%s%s✓ All probed contracts on all selected chains pass every check.%s\n" "$BOLD" "$GREEN" "$RESET"
    exit 0
fi
