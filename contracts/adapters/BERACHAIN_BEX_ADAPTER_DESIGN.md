# Berachain BEX adapter — design notes for the V1.1 LP-unlock session

Berachain LP is currently disabled in `CHAIN_CONFIG[80094]` because no
mainstream UniV2 fork has shipped on its mainnet. The dominant DEXes are:

| DEX | Shape | Why unsuitable as drop-in |
|-----|-------|---------------------------|
| BEX (BeraSwap) | Balancer V2 fork | Vault-based architecture, weighted pools, `IVault.swap` instead of `swapExactTokensForTokens`, `joinPool`/`exitPool` instead of `addLiquidity`/`removeLiquidity` |
| Kodiak | Uniswap V3 fork | Concentrated liquidity, NFT positions, tick-based pricing |
| Honeypot Finance / Wasabee | Algebra V3 fork | Same V3 NFT shape as Kodiak |

The `LPModule` calls a `IUniswapV2Router02`-shaped interface at 4 sites:
- `addLiquidityETH` (CREATE_LP path)
- `addLiquidityETH` again inside CREATE_LP_AND_BUY (after the buy swap)
- `swapExactTokensForTokens` (the buy leg of CREATE_LP_AND_BUY, twice)
- (`removeLiquidityETH` etc. via the standard router for REMOVE_LP / BURN_LP)

To unlock LP on Berachain we ship a `BexBerachainAdapter` contract that
exposes the four V2 router functions Magneta uses and forwards them to
BEX's Vault + weighted pool registry.

## Scope (estimated 8-12h with tests)

### Contract surface (≈ 250-350 LOC)

```solidity
contract BexBerachainAdapter {
    // V2 router facade — required by LPModule + SwapModule
    function factory() external view returns (address);   // returns this contract (we are our own "pair registry")
    function WETH() external view returns (address);      // returns WBERA

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint amountToken, uint amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    // V2 factory facade — required by LPModule's pair-existence lookup
    function getPair(address tokenA, address tokenB) external view returns (address);
}
```

### Internal mapping to BEX (Balancer V2 fork)

| V2 call | BEX equivalent | Notes |
|---------|----------------|-------|
| `addLiquidityETH(token, ...)` | `IVault.joinPool(poolId, sender, recipient, joinReq)` with `JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT` on a 50/50 weighted pool of `[WBERA, token]` | Pool must exist; if it doesn't, we need a separate "create-pool" path through `IBexPoolFactory.createPool` first |
| `removeLiquidityETH(token, lp, ...)` | `IVault.exitPool(poolId, sender, recipient, exitReq)` with `ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT` | BPT = pool's LP token |
| `swapExactTokensForTokens(in, out, path[in,out], ...)` | `IVault.swap(SingleSwap{poolId, kind: GIVEN_IN, assetIn, assetOut, amount}, ...)` | For multi-hop path of length > 2, use `IVault.batchSwap` |
| `getPair(tokenA, tokenB)` | `bexPoolRegistry.getPool(tokenA, tokenB)` | We maintain a chain-local mapping `(tokenA, tokenB) → poolId` populated lazily on first `joinPool` |

### Storage

```solidity
IVault public immutable vault;          // BEX Vault (0xBA12222222228d8Ba445958a75a0704d566BF2C8 on Berachain mainnet — verify before deploy)
IBexPoolFactory public immutable factory_;  // BEX WeightedPoolFactory (find on-chain)
address public immutable WETH;          // WBERA
address public constant WEIGHT_50_50 = ...;  // helper constant

mapping(bytes32 => mapping(address => mapping(address => bytes32))) public poolIdByPair;
```

### Non-trivial implementation concerns

1. **Native BERA wrapping.** BEX swaps/joins use ERC20 token addresses
   only; `addLiquidityETH` receives raw `msg.value`. The adapter must
   wrap to WBERA (`IWETH(WBERA).deposit{value: msg.value}()`), forward
   the WBERA into the Vault, and unwrap any returned excess back to
   native before refunding the caller. Same pattern as
   `UbeswapCeloAdapter.sol` but with explicit wrap/unwrap.

2. **Pool creation on first LP.** Unlike a UniV2 factory, BEX doesn't
   auto-create pools on first join. The adapter must:
   - On `addLiquidityETH` with no existing pool: call
     `factory_.create(weightedPoolParams)` to deploy a new 50/50 weighted
     pool, register its `poolId` in `poolIdByPair`, then `joinPool`.
   - On subsequent joins: re-use the stored poolId.
   - Reentrancy concern: ensure `poolIdByPair` is set BEFORE calling
     `joinPool`, in case the pool's `onJoinPool` callback re-enters.

3. **LP token identity.** Balancer V2 weighted pools mint a BPT (pool
   token) directly to the recipient. From the caller's perspective the
   BPT IS the "liquidity" — so `addLiquidityETH` returns
   `(amountToken, amountETH, liquidity = BPT minted)` which is what
   `LPModule` expects.

4. **Slippage semantics.** `JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT` takes
   a `minBPTAmountOut` — we map `amountTokenMin + amountETHMin` into a
   single minBPT computed from the join's expected BPT (use the pool's
   `onJoinPool` simulation via the Vault's `queryJoin`).

5. **Pool fee.** Magneta's V2 router pattern is 0.30%. BEX weighted
   pools support 0.01%-10% fees; pick 0.30% on pool creation so the
   on-chain swap pricing matches what the UI shows for other V2 chains.

### Tests (≈ 8-12 tests)

Mocking strategy: write `MockBexVault.sol` and `MockBexPoolFactory.sol`
that capture the key call params. Then test:

1. First addLiquidityETH creates pool then joins; subsequent reuses
2. removeLiquidityETH burns BPT for proportional withdrawal
3. swapExactTokensForTokens uses single-pool path
4. swapExactTokensForTokens uses batchSwap on multi-hop path
5. Native wrap/unwrap accounting (msg.value in, ETH refund out)
6. Slippage: minBPTAmountOut respected
7. Zero-amount / zero-address rejects
8. Pool already exists short-circuits creation
9. getPair returns 0 for unknown pair (LPModule "doesn't exist" branch)

### Deploy + wire (mirrors Abstract LP flow)

```
pnpm hardhat run scripts/deploy/deployBexAdapter.ts --network berachain
pnpm hardhat run scripts/deploy/deployLPModuleSafe.ts --network berachain
BATCH=scripts/safe/berachain-lp-wire-batch.json \
  pnpm hardhat run scripts/safe/inhouse/execBatch.ts --network berachain
# Then update CHAIN_CONFIG[80094] + GATEWAY_CHAINS[80094].lpModule
```

### On-chain addresses to verify before coding

Run `cast code` on each before relying on them:

- BEX Vault (likely `0xBA12222222228d8Ba445958a75a0704d566BF2C8` if BEX preserved
  Balancer's canonical address; **verify**)
- BEX WeightedPoolFactory (varies — check Berachain docs)
- WBERA wrapped native (likely `0x6969696969696969696969696969696969696969`
  per Berachain convention; **verify**)
- USDC.e Stargate-bridged (already in `CHAIN_CONFIG[80094]` —
  `0x549943e04f40284185054145c6E4e9568C1D3241`)

### What this DOESN'T solve

- **Kodiak V3 swap path.** Some Berachain users will want the
  concentrated-liquidity efficiency of Kodiak for swap routing. That's
  a separate `KodiakV3SwapAdapter` (V2 facade over V3 swap router), out
  of scope for the LP unlock.
- **BEX stable pools / weighted pools with non-50/50 weights.** The
  adapter is opinionated to 50/50 weights because that's what Magneta's
  UI assumes. Pools with different weights would require frontend
  changes to display correct prices.

## Estimated wall-clock for V1.1 dedicated session

| Phase | Hours |
|------:|-------|
| On-chain address discovery + spec validation | 1 |
| Adapter contract | 3 |
| Mocks + tests | 3 |
| Deploy + Safe wire scripts | 1 |
| End-to-end smoke test (testnet Bepolia first) | 2 |
| Mainnet deploy + frontend update | 1 |
| **Total** | **~10-11h** |

That's why this work is deferred outside the 4-6h budget that
unlocked Abstract LP cleanly.
