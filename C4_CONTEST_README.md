# Magneta Finance — Code4rena Audit Contest

## Contest Details

| Field | Details |
|-------|---------|
| **Sponsor** | Magneta Finance |
| **Total Prize Pool** | $15,000 USDC |
| **High/Medium split** | 70% High / 30% Medium |
| **nSLOC in scope** | 1,676 |
| **Audit type** | DeFi — DEX / AMM / Lending |
| **Chain** | EVM (Base / Ethereum) |
| **Compiler** | Solidity 0.8.20 |

---

## Protocol Overview

Magneta Finance is a multi-chain DeFi protocol providing:

- **DLMM** (Dynamic Liquidity Market Maker) — bin-based concentrated liquidity inspired by Meteora.ag
- **AMM pools** — standard constant-product liquidity pools with NFT-based positions
- **Lending** — overcollateralized lending with Chainlink price feeds and flash loans
- **Yield farming** — token reward distribution for liquidity providers
- **Multi-token pools** — weighted Balancer-style pools
- **Cross-chain swap aggregation** — swap routing across integrated DEXs

Live at: https://app.magneta.finance

---

## Scope

### In-Scope Contracts

| Contract | nSLOC | Description |
|----------|-------|-------------|
| `contracts/core/MagnetaPool.sol` | 368 | AMM pool — constant product, NFT positions, fee tiers |
| `contracts/core/MagnetaDLMM.sol` | 270 | DLMM — bin-based concentrated liquidity, protocol fees |
| `contracts/core/MagnetaFactory.sol` | 67 | Factory — deploys Pool, DLMM, MultiPool instances |
| `contracts/core/MagnetaFarm.sol` | 318 | Yield farm — reward distribution, NFT staking, emergency withdraw |
| `contracts/core/MagnetaLending.sol` | 325 | Lending — borrow/repay/liquidate, flash loans, Chainlink oracles |
| `contracts/core/MagnetaSwap.sol` | 155 | Swap aggregator — routes swaps through MagnetaPool |
| `contracts/core/MagnetaMultiPool.sol` | 128 | Multi-token weighted pool (Balancer-style) |
| `contracts/libraries/BinHelper.sol` | 45 | DLMM price math — geometric bin pricing |
| **Total** | **1,676** | |

### Out of Scope

| Contract | Reason |
|----------|--------|
| `contracts/core/MagnetaBridge.sol` | LayerZero bridge — separate audit scope |
| `contracts/core/MagnetaBridgeOApp.sol` | LayerZero OApp — separate audit scope |
| `contracts/core/MagnetaBundler.sol` | Uniswap V2 bundler — uses external trusted router |
| `contracts/core/MagnetaProxy.sol` | 0x/DEX aggregator proxy — external integrations |
| `contracts/tokens/MockERC20.sol` | Test only |

---

## Architecture

```
MagnetaFactory
├── creates → MagnetaPool      (standard AMM pools)
├── creates → MagnetaDLMM      (bin-based DLMM pools)
└── creates → MagnetaMultiPool (weighted multi-token pools)

MagnetaSwap ──routes swaps──→ MagnetaPool

MagnetaFarm
└── stakes LP positions (NFTs from MagnetaPool)
    └── distributes reward tokens

MagnetaLending
├── accepts ERC20 collateral
├── uses Chainlink price feeds
└── supports flash loans
```

---

## Key Design Decisions

### MagnetaPool
- Liquidity positions represented as **ERC721 NFTs** (Uniswap V3-style)
- Simplified constant product formula (AMM V2-style reserves)
- **Feature flags**: `poolCreationEnabled`, `liquidityAdditionEnabled` — owner can gate access
- Fees stay in pool reserves (Uniswap V2 style), distributed proportionally on withdrawal
- Emergency `pause()` / `unpause()` blocks: `addLiquidity`, `removeLiquidity`, `swap`

### MagnetaDLMM
- Bin-based price model: `price(id) = (1 + binStep/10000)^(id - BASE_ID)` via `BinHelper`
- LP shares tracked per `(user, binId)` — no ERC20/NFT token for positions
- Two-tier fee: LP fee stays in bin reserves, protocol fee accumulated separately
- Emergency `pause()` / `unpause()` blocks: `addLiquidity`, `removeLiquidity`, `swap`

### MagnetaLending
- Overcollateralized only (no undercollateralized loans except flash loans)
- Chainlink oracle with staleness check: `block.timestamp - updatedAt <= 3600`
- Flash loan fee: configurable, collected in `flashLoanFeePool`
- Liquidation bonus paid from collateral to liquidator

### MagnetaFarm
- MasterChef-style: `rewardPerBlock` distributed across pools weighted by `allocPoint`
- Supports both ERC20 LP tokens and NFT positions (from MagnetaPool)
- `emergencyWithdraw()` — bypasses reward calculation, returns principal only

---

## Known Issues (Acknowledged, Not in Scope)

These findings from our internal Slither analysis are **known and accepted**:

| Severity | Issue | Contract | Status |
|----------|-------|----------|--------|
| Medium | `divide-before-multiply` in DLMM price loop | `BinHelper.getPriceFromId` | Accepted — iterative price is intentional for prototype; production will use binary exponentiation |
| Medium | `divide-before-multiply` in reward calculation | `MagnetaFarm.updatePool` | Accepted — bounded precision loss |
| Medium | `divide-before-multiply` in swap math | `MagnetaPool`, `MagnetaDLMM`, `MagnetaMultiPool` | Accepted — MVP precision trade-off |
| Low | `incorrect-equality` for zero-check | `MagnetaFarm`, `MagnetaMultiPool` | Accepted — initial state only |
| Low | Unused return values from Uniswap router | `MagnetaBundler` | Out of scope |
| Info | Missing `indexed` on some events | Various | Gas optimization, not security |
| Info | State variables could be `immutable` | Various | Gas optimization, not security |

---

## Setup & Testing

### Prerequisites
```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install Node dependencies
pnpm install
```

### Build
```bash
cd packages/contracts
forge build
```

### Run Tests
```bash
# Foundry tests
forge test -vvv

# Fuzz tests
forge test --match-contract FarmFuzz -vvv
forge test --match-contract MagnetaProxy -vvv

# Hardhat tests
npx hardhat test
```

### Coverage
```bash
forge coverage
```

### Static Analysis
```bash
slither contracts/core/ --filter-paths "node_modules|test|mocks"
```

---

## Areas of Concern for Auditors

We are particularly interested in findings related to:

1. **Price manipulation** in `MagnetaDLMM` — can `activeId` be manipulated to drain reserves?
2. **Liquidity accounting** in `MagnetaPool` — is the simplified constant product formula exploitable at edge cases?
3. **Oracle manipulation** in `MagnetaLending` — Chainlink staleness window of 3600s, is this sufficient?
4. **Flash loan interactions** in `MagnetaLending` — can flash loans interact with borrow/liquidate in the same block?
5. **Reentrancy** in `MagnetaFarm.emergencyWithdraw` — nonReentrant present but NFT callbacks (`onERC721Received`) present
6. **Reserve rounding errors** in `MagnetaPool` — can repeated add/remove cycles drain reserves via rounding?

---

## Deployment

Contracts are deployed on **Base Sepolia** (testnet):

| Contract | Address |
|----------|---------|
| MagnetaFactory | `0xFef295610Be34e097Bf6Ebd0295f7f02D0b8DE5a` |
| MagnetaPool | `0x819E809D55B3101E3adc3B701c704412E005Af5a` |
| MagnetaSwap | `0xc987c18869151A8Fa6aAB02a182427740d2Ca08D` |
| MagnetaDLMM | `0xF569769ef755484310b9Ca6d83f8a9190461D28B` |
| MagnetaLending | `0x2AdB28534959292933619F42fE259d954263d25c` |
| MagnetaFarm | `0x11CF3a229fD7a339bC83518884bc43Cd26045c55` |
| MockTokenX (DLMM pair) | `0xAF21a21E43d572Db09c5F6A72853224CFA1Bd085` |
| MockTokenY (DLMM pair) | `0x716B8a28DBaa2b621db69d47e029437b36437d22` |

---

## Contact

- **Website**: https://magneta.finance
- **App**: https://app.magneta.finance
- **GitHub**: https://github.com/Bosacks/magneta-finance-dex
- **Twitter/X**: @MagnetaFinance

For contest setup questions, contact the sponsor through the Code4rena Discord.
