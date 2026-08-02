#!/usr/bin/env bash
# Pause MagnetaFactory on every chain, closing createDLMMPool.
#
#   read -rs -p "Clé PauseGuardian : " PG && echo && PAUSE_GUARDIAN_PRIVATE_KEY="$PG" ./scripts/safe/pauseCurveAndDlmmFactories.sh
#   # dry run (default): prints what it would do, sends nothing
#   # to actually send:  EXECUTE=1 ... ./scripts/safe/pauseCurveAndDlmmFactories.sh
#
# WHY. MagnetaFactory.createDLMMPool is permissionless and open on all 20
# chains, and the MagnetaDLMM it would deploy still carries the two report-18
# design defects (partial fill strands liquidity while advancing activeId; a
# one-sided deposit followed by a proportional withdrawal is a fee-free swap).
# Pool count is 0 everywhere — pausing now costs nothing and closes the door
# before the first pool exists.
#
# WHAT IT COSTS. pause() also gates createMultiPool and createStandardPool.
# Verified 2026-08-02: the site calls neither — its pool creation goes to
# MagnetaPool.createPool directly and its LP path to the external DEX router.
# So the only thing this closes is the DLMM path plus two unused entry points.
#
# WHO CAN. pause() is onlyOwnerOrPauser and the PauseGuardian
# (0x92F440Bc1f1FaBD6D3e6256491631E07857F4260) is a registered pauser on all
# 20 factories — no Safe batch needed. Reversal is unpause(), which is
# onlyOwner: the Safe.
set -uo pipefail

: "${PAUSE_GUARDIAN_PRIVATE_KEY:?set PAUSE_GUARDIAN_PRIVATE_KEY}"
EXECUTE="${EXECUTE:-0}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# chain:rpc — the RPCs the circuit breaker uses, which are known to answer.
CHAINS=(
  "base|https://mainnet.base.org"
  "arbitrum|https://arb1.arbitrum.io/rpc"
  "polygon|https://polygon.drpc.org"
  "optimism|https://mainnet.optimism.io"
  "bsc|https://bsc-dataseed.binance.org"
  "avalanche|https://api.avax.network/ext/bc/C/rpc"
  "gnosis|https://rpc.gnosischain.com"
  "celo|https://forno.celo.org"
  "linea|https://rpc.linea.build"
  "mantle|https://rpc.mantle.xyz"
  "sonic|https://rpc.soniclabs.com"
  "unichain|https://mainnet.unichain.org"
  "katana|https://rpc.katana.network"
  "berachain|https://rpc.berachain.com"
  "sei|https://evm-rpc.sei-apis.com"
  "cronos|https://evm.cronos.org"
  "flare|https://rpc.ankr.com/flare"
  "abstract|https://api.mainnet.abs.xyz"
  "monad|https://rpc.monad.xyz"
  "plasma|https://rpc.plasma.to"
)

for entry in "${CHAINS[@]}"; do
  net="${entry%%|*}"; rpc="${entry##*|}"
  manifest="$REPO/deployments-b/$net.json"
  [[ -f "$manifest" ]] || { printf '%-11s SKIP  no manifest\n' "$net"; continue; }

  addr=$(python3 -c "
import json,sys
d=json.load(open('$manifest'))
def g(o,t):
    if isinstance(o,dict):
        for k,v in o.items():
            if k.lower()==t: return v
            r=g(v,t)
            if r: return r
print(g(d,'magnetafactory') or '')")
  [[ -n "$addr" ]] || { printf '%-11s SKIP  no MagnetaFactory\n' "$net"; continue; }

  paused=$(cast call "$addr" "paused()(bool)" --rpc-url "$rpc" 2>/dev/null | tail -1)
  if [[ "$paused" == "true" ]]; then
    printf '%-11s SKIP  already paused\n' "$net"; continue
  fi
  if [[ -z "$paused" ]]; then
    printf '%-11s SKIP  unreadable — not touching a chain we cannot read\n' "$net"; continue
  fi

  # A pool that already exists would keep trading; pausing only blocks creation.
  counts=$(cast call "$addr" "getPoolCounts()(uint256,uint256)" --rpc-url "$rpc" 2>/dev/null | tr '\n' ' ')

  if [[ "$EXECUTE" != "1" ]]; then
    printf '%-11s WOULD PAUSE  %s  (pools multi/dlmm: %s)\n' "$net" "$addr" "${counts:-?}"
    continue
  fi

  out=$(cast send "$addr" "pause()" --rpc-url "$rpc" \
        --private-key "$PAUSE_GUARDIAN_PRIVATE_KEY" --json 2>&1)
  if grep -q '"status": *"0x1"' <<<"$out"; then
    printf '%-11s PAUSED  %s\n' "$net" "$(grep -o '"transactionHash": *"[^"]*"' <<<"$out" | cut -d'"' -f4)"
  else
    printf '%-11s FAILED  %s\n' "$net" "$(head -c 140 <<<"$out")"
  fi
done
