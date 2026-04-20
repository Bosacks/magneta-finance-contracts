#!/usr/bin/env bash
# Verify every contract in deployments/<network>.json on the chain's block explorer.
#
# Usage:   ./scripts/verify-all.sh <network>
# Example: ./scripts/verify-all.sh base
#
# Requires: ETHERSCAN_API_KEY (or chain-specific equivalent) set in .env
#           Hardhat's @nomicfoundation/hardhat-verify plugin configured.
set -euo pipefail

NET="${1:-}"
if [[ -z "$NET" ]]; then
  echo "usage: $0 <network>" >&2
  exit 1
fi

DEP="deployments/${NET}.json"
if [[ ! -f "$DEP" ]]; then
  echo "no deployment file: $DEP" >&2
  exit 1
fi

# Pull contract name -> address pairs (requires jq)
mapfile -t PAIRS < <(jq -r '.contracts | to_entries[] | "\(.key) \(.value)"' "$DEP")

FAILED=()
OK=()

for pair in "${PAIRS[@]}"; do
  NAME="${pair%% *}"
  ADDR="${pair##* }"
  echo
  echo "=== ${NAME} @ ${ADDR} (${NET}) ==="

  # Skip mocks on mainnets — they shouldn't be there but belt and suspenders.
  if [[ "$NET" != *Sepolia && "$NET" != *Amoy && "$NET" != "hardhat" && "$NAME" == Mock* ]]; then
    echo "  skipped (mock on mainnet)"
    continue
  fi

  if npx hardhat verify --network "$NET" "$ADDR" 2>&1 | tee /tmp/verify-$$.log; then
    if grep -q "Already Verified\|Successfully verified\|successfully verified" /tmp/verify-$$.log; then
      OK+=("$NAME")
    else
      FAILED+=("$NAME")
    fi
  else
    FAILED+=("$NAME")
  fi
done

rm -f /tmp/verify-$$.log

echo
echo "==============================================================="
echo "Verified : ${#OK[@]}"
printf '  %s\n' "${OK[@]:-(none)}"
echo
echo "Failed   : ${#FAILED[@]}"
printf '  %s\n' "${FAILED[@]:-(none)}"
echo "==============================================================="

[[ ${#FAILED[@]} -eq 0 ]] || exit 1
