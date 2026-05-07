#!/usr/bin/env bash
# Deploy MAG OFT (0 supply) on the 17 secondary chains.
# Skips chains where deployments/<chain>.json already has contracts.MAG set.
#
#   bash scripts/util/batchDeployMAG.sh
set -u

cd "$(dirname "$0")/../.."

# Order = gas-cheapest first to minimise upfront cost on tight wallets.
CHAINS=(
  gnosis cronos celo flare sei plasma sonic mantle
  bsc berachain avalanche
  optimism base arbitrum linea unichain katana monad abstract
)

declare -A RPC_OVERRIDE=(
  [arbitrum]="https://arbitrum-one-rpc.publicnode.com"
  [bsc]="https://bsc-rpc.publicnode.com"
  [avalanche]="https://avalanche-c-chain-rpc.publicnode.com"
  [sei]="https://sei-evm-rpc.publicnode.com"
  [flare]="https://flare.public-rpc.com"
)

OK=()
SKIP=()
FAIL=()

for chain in "${CHAINS[@]}"; do
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " $chain"
  echo "═══════════════════════════════════════════════════"

  dep="deployments/${chain}.json"
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
    esac
  fi

  if [ -n "$env_var" ]; then
    eval "$env_var pnpm hardhat run scripts/deploy/deployMAGOnSecondaryChain.ts --network $chain"
  else
    pnpm hardhat run scripts/deploy/deployMAGOnSecondaryChain.ts --network "$chain"
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
echo "Next: pnpm tsx scripts/deploy/generateMAGPeerWiringBatches.ts"
echo "      Then execute each safe batch in scripts/safe/<chain>-MAG-peerWiring-batch.json"
