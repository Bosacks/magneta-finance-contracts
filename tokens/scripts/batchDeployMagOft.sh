#!/usr/bin/env bash
# Deploy MAG OFT (0 supply) on the 18 secondary chains where LZ V2 is supported.
# Skips Cronos (no LZ V2) and Polygon (canonical). Idempotent — re-run safe.
#
#   bash scripts/batchDeployMagOft.sh
set -u

cd "$(dirname "$0")/.."

# Order = gas-cheapest first to minimise upfront cost on tight wallets.
CHAINS=(
  gnosis celo flare sei plasma sonic mantle
  bsc berachain avalanche
  optimism base arbitrum linea unichain katana monad abstract
)

declare -A RPC_OVERRIDE=(
  [arbitrum]="https://arbitrum-one-rpc.publicnode.com"
  [bsc]="https://bsc-rpc.publicnode.com"
  [avalanche]="https://avalanche-c-chain-rpc.publicnode.com"
  [sei]="https://sei-evm-rpc.publicnode.com"
  [flare]="https://flare.public-rpc.com"
  [monad]="https://rpc.monad.xyz"
  [polygon]="https://polygon-bor-rpc.publicnode.com"
)

OK=()
SKIP=()
FAIL=()

CONTRACTS_REPO=$(realpath ../../../magneta-finance-contracts)

for chain in "${CHAINS[@]}"; do
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " $chain"
  echo "═══════════════════════════════════════════════════"

  dep="$CONTRACTS_REPO/deployments/${chain}.json"
  if [ -f "$dep" ] && grep -q '"MAG"' "$dep"; then
    echo "  ⏭  Already deployed — skipping"
    SKIP+=("$chain")
    continue
  fi

  env_var=""
  if [ -n "${RPC_OVERRIDE[$chain]:-}" ]; then
    case "$chain" in
      arbitrum)   env_var="ARBITRUM_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      bsc)        env_var="BSC_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      avalanche)  env_var="AVALANCHE_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      sei)        env_var="SEI_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      flare)      env_var="FLARE_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      monad)      env_var="MONAD_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      polygon)    env_var="POLYGON_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
    esac
  fi

  if [ -n "$env_var" ]; then
    eval "$env_var pnpm hardhat run scripts/deploy-mag-oft-secondary.ts --network $chain"
  else
    pnpm hardhat run scripts/deploy-mag-oft-secondary.ts --network "$chain"
  fi

  if [ $? -eq 0 ]; then
    OK+=("$chain")
  else
    FAIL+=("$chain")
  fi
done

echo ""
echo "═══════════════════════════════════════════════════"
echo " RECAP"
echo "═══════════════════════════════════════════════════"
echo " Deployed : ${#OK[@]}   ${OK[*]}"
echo " Skipped  : ${#SKIP[@]}  ${SKIP[*]}"
echo " Failed   : ${#FAIL[@]}  ${FAIL[*]}"
echo ""
echo "Next:"
echo "  cd ../../../magneta-finance-contracts"
echo "  pnpm tsx scripts/deploy/generateMAGPeerWiringBatches.ts"
echo "  Then setPeer on each chain (direct EOA call or Safe batch)"
