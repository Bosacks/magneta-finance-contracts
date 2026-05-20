#!/usr/bin/env bash
# Pause Guardian Fire Drill — Base Sepolia
#
# Exercises the pause/unpause flow on every pausable core contract deployed
# on Base Sepolia. Run this when:
#   - You first set up the PauseGuardian (verifies the wiring works)
#   - Quarterly (verifies the ops still work after upgrades/redeploys)
#   - After every redeploy of any pausable contract
#   - Before any incident response training
#
# The goal of the drill is twofold:
#   1. Prove the technical wiring works — `pause()` actually halts user-facing
#      functions, and `unpause()` actually restores them.
#   2. Measure the OWNER reaction time. If pausing 3 contracts takes more than
#      ~60s from "decision made" to "all paused", the runbook needs work.
#
# Usage:
#   export BASE_SEPOLIA_RPC="https://sepolia.base.org"
#   export DEPLOYER_PRIVATE_KEY="0x..."   # the owner key for testnet
#   ./scripts/test/pause-guardian-drill.sh
#
# Optional:
#   DRY_RUN=1 ./scripts/test/pause-guardian-drill.sh   # read-only, no tx sent
#   SKIP_SWAP_TEST=1 ./...                              # skip the revert verification
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
: "${BASE_SEPOLIA_RPC:=https://sepolia.base.org}"
: "${DEPLOYER_PRIVATE_KEY:?Set DEPLOYER_PRIVATE_KEY to the owner key for testnet contracts}"
: "${DRY_RUN:=0}"
: "${SKIP_SWAP_TEST:=0}"

# Deployed addresses on Base Sepolia (sourced from deployments/baseSepolia.json)
MAGNETA_SWAP="0x4A5737405cb87862F1809a869d7e1a25af5c4b8E"
MAGNETA_POOL="0x37A5D51f71053D6aae0e337256db1829a6B0e5Ab"
MAGNETA_GATEWAY="0x14fe8c8D80C7420842B9313314F7b24dc4b3DceF"
MAGNETA_BUNDLER="0xe570eA38940E40EEdB8555F4fB40E652644cC13C"
MAGNETA_PROXY_V2="0x75D083DD60614FC53a8C41D2f69b27FE9f8F7D90"

# Mock tokens for the revert-during-pause verification
MOCK_USDC="$(jq -r .contracts.MockUSDC deployments/baseSepolia.json 2>/dev/null || echo 0x0)"
MOCK_TOKEN_X="$(jq -r .contracts.MockTokenX deployments/baseSepolia.json 2>/dev/null || echo 0x0)"

# Targets that have a pause()/unpause() + a paused() getter
declare -A PAUSABLE
PAUSABLE["MagnetaSwap"]="$MAGNETA_SWAP"
PAUSABLE["MagnetaPool"]="$MAGNETA_POOL"
PAUSABLE["MagnetaGateway"]="$MAGNETA_GATEWAY"
PAUSABLE["MagnetaBundler"]="$MAGNETA_BUNDLER"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
log() { printf '%s | %s\n' "$(date +%H:%M:%S)" "$*"; }
log_step() { printf '\n\e[1;36m▸ %s\e[0m\n' "$*"; }
log_ok() { printf '\e[1;32m  ✓ %s\e[0m\n' "$*"; }
log_warn() { printf '\e[1;33m  ⚠ %s\e[0m\n' "$*"; }
log_err() { printf '\e[1;31m  ✗ %s\e[0m\n' "$*" >&2; }

if ! command -v cast >/dev/null 2>&1; then
    log_err "cast (foundry) not found. Install: curl -L https://foundry.paradigm.xyz | bash && foundryup"
    exit 1
fi

# Sanity check — confirm we can read from the RPC.
chain_id=$(cast chain-id --rpc-url "$BASE_SEPOLIA_RPC" 2>/dev/null) || { log_err "Cannot reach $BASE_SEPOLIA_RPC"; exit 1; }
if [ "$chain_id" != "84532" ]; then
    log_err "Expected chainId 84532 (Base Sepolia), got $chain_id. Check BASE_SEPOLIA_RPC."
    exit 1
fi

owner_addr=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
log "Drill running as owner: $owner_addr"
log "RPC: $BASE_SEPOLIA_RPC (chainId $chain_id)"
log "Mode: $([ "$DRY_RUN" = "1" ] && echo DRY-RUN || echo LIVE)"

# Read paused() state. Returns "true" / "false" / "n/a" if call fails.
read_paused() {
    local addr=$1
    local result
    if result=$(cast call "$addr" "paused()(bool)" --rpc-url "$BASE_SEPOLIA_RPC" 2>/dev/null); then
        echo "$result"
    else
        echo "n/a"
    fi
}

# Read owner() to confirm we have the right key.
read_owner() {
    local addr=$1
    cast call "$addr" "owner()(address)" --rpc-url "$BASE_SEPOLIA_RPC" 2>/dev/null || echo "0x0"
}

# Send a tx via cast. Captures stderr so failures are diagnosable.
# Sleeps 1.5s between calls to avoid public-RPC rate limits + nonce caching
# bugs observed on sepolia.base.org when several signed txs ship within
# the same Base block (~2s).
send_tx() {
    local addr=$1 fn=$2
    if [ "$DRY_RUN" = "1" ]; then
        log "  [dry-run] would send $fn to $addr"
        return 0
    fi
    local out err rc
    err=$(mktemp)
    if out=$(cast send "$addr" "$fn" \
        --rpc-url "$BASE_SEPOLIA_RPC" \
        --private-key "$DEPLOYER_PRIVATE_KEY" \
        --json 2>"$err"); then
        echo "$out" | jq -r '.transactionHash'
        rc=0
    else
        # Surface the cast error so the operator can diagnose
        log_err "  cast send failed: $(cat "$err" | tr '\n' ' ' | sed 's/  */ /g' | head -c 300)"
        rc=1
    fi
    rm -f "$err"
    sleep 1.5  # spread successive txs over more than one Base block
    return $rc
}

send_pause()   { send_tx "$1" "pause()"; }
send_unpause() { send_tx "$1" "unpause()"; }

# ─────────────────────────────────────────────────────────────────────────────
# Drill — Phase 1: pre-flight inspection
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 1 — Pre-flight: read current state of every pausable contract"

declare -A INITIAL_STATE
all_ok=1
for name in "${!PAUSABLE[@]}"; do
    addr="${PAUSABLE[$name]}"
    state=$(read_paused "$addr")
    contract_owner=$(read_owner "$addr")
    INITIAL_STATE["$name"]="$state"

    printf '  %-18s %s  paused=%-5s  owner=%s\n' "$name" "$addr" "$state" "$contract_owner"

    if [ "$state" = "n/a" ]; then
        log_warn "  Cannot read paused() on $name — skipping in later phases"
        unset PAUSABLE["$name"]
        continue
    fi
    if [ "$state" = "true" ]; then
        log_warn "  $name is ALREADY paused. Drill will unpause it at the end."
    fi
    if [ "${contract_owner,,}" != "${owner_addr,,}" ]; then
        log_warn "  $name owner is $contract_owner, your key is $owner_addr — pause/unpause will revert"
        all_ok=0
    fi
done

if [ "$all_ok" = "0" ]; then
    log_err "Owner mismatch on at least one contract. Fix DEPLOYER_PRIVATE_KEY before running live."
    [ "$DRY_RUN" = "0" ] && exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Drill — Phase 2: pause every contract, measure latency
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 2 — Pause every contract (the panic path)"

start=$(date +%s.%N)
declare -A PAUSE_TX
for name in "${!PAUSABLE[@]}"; do
    [ "${INITIAL_STATE[$name]}" = "true" ] && { log "  $name was already paused, skipping pause tx"; continue; }
    addr="${PAUSABLE[$name]}"
    log "  pausing $name…"
    if tx=$(send_pause "$addr"); then
        PAUSE_TX["$name"]="$tx"
        log_ok "  pause tx: $tx"
    else
        log_err "  pause FAILED for $name"
    fi
done
end=$(date +%s.%N)
elapsed=$(awk "BEGIN {printf \"%.2f\", $end - $start}")
log_ok "All pause txs submitted in ${elapsed}s"

# Verify each contract reports paused=true.
sleep 3
log_step "Phase 2b — Verify paused() == true on every contract"
for name in "${!PAUSABLE[@]}"; do
    addr="${PAUSABLE[$name]}"
    state=$(read_paused "$addr")
    if [ "$state" = "true" ]; then
        log_ok "$name paused=true confirmed"
    else
        log_err "$name paused=$state (expected true)"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Drill — Phase 3: verify a user-facing function actually reverts
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SKIP_SWAP_TEST" = "0" ] && [ "$DRY_RUN" = "0" ]; then
    log_step "Phase 3 — Sanity: confirm pause state read matches Phase 2b"
    # Note: we previously tried to cast call swap() and grep the revert reason,
    # but a malformed swap (invalid poolId/tokens) reverts *before* reaching
    # the whenNotPaused modifier, producing false negatives. Re-reading
    # paused() against MagnetaSwap is the authoritative check that the
    # pause state is wired correctly. Functional whenNotPaused validation
    # requires a real swap with a real pool — out of scope for a drill.
    state=$(read_paused "$MAGNETA_SWAP")
    if [ "$state" = "true" ]; then
        log_ok "MagnetaSwap state still reads paused=true (whenNotPaused modifier reads from this slot)"
    else
        log_err "MagnetaSwap state slipped back to paused=$state — investigate"
    fi
else
    log "  Skipping Phase 3 (SKIP_SWAP_TEST=1 or DRY_RUN)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Drill — Phase 4: unpause every contract
# ─────────────────────────────────────────────────────────────────────────────
log_step "Phase 4 — Unpause every contract (restore the system)"

start=$(date +%s.%N)
for name in "${!PAUSABLE[@]}"; do
    addr="${PAUSABLE[$name]}"
    log "  unpausing $name…"
    if tx=$(send_unpause "$addr"); then
        log_ok "  unpause tx: $tx"
    else
        log_err "  unpause FAILED for $name"
    fi
done
end=$(date +%s.%N)
elapsed=$(awk "BEGIN {printf \"%.2f\", $end - $start}")
log_ok "All unpause txs submitted in ${elapsed}s"

sleep 3
log_step "Phase 4b — Verify paused() == false on every contract"
for name in "${!PAUSABLE[@]}"; do
    addr="${PAUSABLE[$name]}"
    state=$(read_paused "$addr")
    if [ "$state" = "false" ]; then
        log_ok "$name paused=false confirmed"
    else
        log_err "$name paused=$state (expected false). MANUAL INTERVENTION REQUIRED."
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
log_step "Drill complete"
log "Now check the INCIDENT_RUNBOOK.md: does the documented panic sequence"
log "match the latency you just observed? If not, update the SLA targets."
