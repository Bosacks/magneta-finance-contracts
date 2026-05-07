#!/usr/bin/env bash
# Batch deploy MagnetaStakingFactory sur les 20 chaînes EVM Magneta.
# Skip les chaînes où le factory est déjà dans deployments/{net}.json.
# Usage: bash scripts/util/batchDeployStakingFactory.sh
set -u

cd "$(dirname "$0")/../.."

# 20 chaînes EVM Magneta — ordre = gas le moins cher d'abord
CHAINS=(
  gnosis cronos polygon celo flare sei plasma sonic mantle
  bsc berachain avalanche
  optimism base arbitrum linea unichain katana monad abstract
)

# RPC overrides pour les chaînes flaky
declare -A RPC_OVERRIDE=(
  [polygon]="https://polygon-bor-rpc.publicnode.com"
  [arbitrum]="https://arbitrum-one-rpc.publicnode.com"
  [bsc]="https://bsc-rpc.publicnode.com"
  [avalanche]="https://avalanche-c-chain-rpc.publicnode.com"
  [sei]="https://sei-evm-rpc.publicnode.com"
  [flare]="https://flare.public-rpc.com"
)

OK=()
FAIL=()
SKIP=()

for chain in "${CHAINS[@]}"; do
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " $chain"
  echo "═══════════════════════════════════════════════════"

  # Skip si déjà déployé
  dep="deployments/${chain}.json"
  if [ -f "$dep" ] && grep -q '"MagnetaStakingFactory"' "$dep"; then
    echo "  ⏭  Already deployed — skipping"
    SKIP+=("$chain")
    continue
  fi

  # Build env override
  env_var=""
  if [ -n "${RPC_OVERRIDE[$chain]:-}" ]; then
    case "$chain" in
      polygon)    env_var="POLYGON_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      arbitrum)   env_var="ARBITRUM_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      bsc)        env_var="BSC_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      avalanche)  env_var="AVALANCHE_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      sei)        env_var="SEI_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      flare)      env_var="FLARE_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
    esac
  fi

  # Run deploy
  if [ -n "$env_var" ]; then
    eval "$env_var pnpm hardhat run scripts/deploy/deployStakingFactory.ts --network $chain"
  else
    pnpm hardhat run scripts/deploy/deployStakingFactory.ts --network "$chain"
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
