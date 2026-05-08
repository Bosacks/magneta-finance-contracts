#!/usr/bin/env bash
# Wire LZ peers between every (chain × chain) pair for MAG OFT — direct EOA
# calls. Runs wireMAGPeersDirect.ts on each chain that has MAG deployed.
#
# Each chain ends up with `peers[eid_M] = bytes32(MAG[M])` for every other M,
# enabling bidirectional bridging via OFT.send.
#
# Idempotent — the script skips peers already set.
#
#   bash scripts/util/batchWireMAGPeers.sh
set -u

cd "$(dirname "$0")/../.."

# Order doesn't matter — each chain's peers are independent.
CHAINS=(
  polygon gnosis celo flare sei plasma sonic mantle
  bsc berachain avalanche
  optimism base arbitrum linea unichain katana monad abstract
)

declare -A RPC_OVERRIDE=(
  [polygon]="https://polygon-bor-rpc.publicnode.com"
  [arbitrum]="https://arbitrum-one-rpc.publicnode.com"
  [bsc]="https://bsc-rpc.publicnode.com"
  [avalanche]="https://avalanche-c-chain-rpc.publicnode.com"
  [sei]="https://sei-evm-rpc.publicnode.com"
  [flare]="https://flare.public-rpc.com"
  [monad]="https://rpc.monad.xyz"
)

OK=()
FAIL=()

for chain in "${CHAINS[@]}"; do
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo " $chain"
  echo "═══════════════════════════════════════════════════"

  env_var=""
  if [ -n "${RPC_OVERRIDE[$chain]:-}" ]; then
    case "$chain" in
      polygon)    env_var="POLYGON_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      arbitrum)   env_var="ARBITRUM_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      bsc)        env_var="BSC_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      avalanche)  env_var="AVALANCHE_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      sei)        env_var="SEI_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      flare)      env_var="FLARE_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
      monad)      env_var="MONAD_MAINNET_RPC_URL=${RPC_OVERRIDE[$chain]}";;
    esac
  fi

  if [ -n "$env_var" ]; then
    eval "$env_var pnpm hardhat run scripts/deploy/wireMAGPeersDirect.ts --network $chain"
  else
    pnpm hardhat run scripts/deploy/wireMAGPeersDirect.ts --network "$chain"
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
echo " Wired   : ${#OK[@]}   ${OK[*]}"
echo " Failed  : ${#FAIL[@]}  ${FAIL[*]}"
