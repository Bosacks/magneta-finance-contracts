# Sprint B — 2-DVN Required on CreateTokenDispatcher

Planning + handoff notes for the next dedicated session.

## Goal

Set `requiredDVNCount >= 2` on every CreateTokenDispatcher OApp pathway
(19 source chains × 18 remote peers = 342 paths). Closes the audit
finding "2-DVN PENDING — LayerZero V2 defaults = 0 DVN (permissionless),
pas de guard contre les relayers malveillants".

## Why we are not doing it ad-hoc

LayerZero V2 requires that the **SendUlnConfig** on chain A match the
**ReceiveUlnConfig** on chain B for each (A, B) pathway. A mismatch
blocks messages and, in some configurations, can lose funds. Doing this
by hand across 342 paths is unsafe.

The standard tooling is `@layerzerolabs/toolbox-hardhat`, which
generates a single `lz:oapp:wire` Hardhat task that orchestrates the
matched Send/Receive setConfig calls per peer.

## Install state (this session)

Added to `devDependencies` in `package.json`:

- `@layerzerolabs/toolbox-hardhat@^0.6.13`
- `@layerzerolabs/devtools-evm-hardhat@^4.0.4`
- `@layerzerolabs/lz-definitions@^3.1.2`
- `@layerzerolabs/io-devtools@^0.3.2`
- `@safe-global/safe-core-sdk-types@2.3.0` (peer dep workaround)

The `import "@layerzerolabs/toolbox-hardhat"` line is wired into
`hardhat.config.ts`.

## Blocker hit

`@layerzerolabs/devtools-evm-hardhat@4.0.4` transitively requires
`@nomiclabs/hardhat-ethers@2.2.3`, which is **ethers v5 only**. This
repo already runs `ethers@6.x` via the existing scripts. Result:

```
TypeError: Cannot read properties of undefined (reading 'JsonRpcProvider')
  at @nomiclabs/hardhat-ethers/src/internal/ethers-provider-wrapper.ts:4:61
```

`hardhat-toolbox` (already installed) is incompatible with the LZ
DevTools pin on `@nomiclabs/hardhat-ethers` v5.

## Resolution options for next session

Pick one before starting the wire work.

### Option 1 — pnpm override to ethers v5 alias

Add to `pnpm.overrides` in `package.json`:

```json
{
  "pnpm": {
    "overrides": {
      "@nomiclabs/hardhat-ethers>ethers": "5.7.2"
    }
  }
}
```

Lets the LZ chain keep ethers v5 internally while our scripts use
ethers v6. ~30 min to validate + re-run.

### Option 2 — Foundry-based LZ DevTools

LayerZero ships `@layerzerolabs/toolbox-foundry` for projects on
Foundry. Could install it standalone and run the wire commands via
`forge script` without touching Hardhat's ethers. Requires installing
Foundry on the dev machine (already done) + adapting our chain RPC
config from `hardhat.config.ts` to `foundry.toml`. ~2h.

### Option 3 — Roll our own using `@layerzerolabs/lz-definitions`

Use only the data packages (`lz-definitions` for EID + DVN registry)
and write a Hardhat script that:

1. Reads each dispatcher address from `deployments-dispatcher/*.json`
2. Pulls DVN addresses from
   https://metadata.layerzero-api.com/v1/metadata/dvns per chain
3. For each (source, dest) pair, picks LayerZero Labs DVN + one
   alternative present on both chains (Chainlink / Google /
   Polyhedra / Horizen depending on availability)
4. Encodes UlnConfig + SetConfigParam via viem
5. Writes one Safe batch JSON per chain (38 transactions each:
   18 SendConfig + 18 ReceiveConfig + 2 setSendLibrary calls)

~5–7h focused work, but no dependency conflicts. **Recommended if
Option 1 also breaks** — gives full control over the DVN selection
matrix and stays in our existing toolchain.

## Inputs the next session needs

- `deployments-dispatcher/*.json` — already on disk (19 chains)
- `lib/constants/gatewayChains.ts` (tokens app) — same dispatcher
  addresses, redundant source of truth
- LZ endpoint address `0x1a44076050125825900e736c501f859c50fE728c`
  (same on all 19 EVMs)
- Send/Receive library addresses per chain — fetch from
  https://metadata.layerzero-api.com/v1/metadata/contracts
- DVN addresses per chain — fetch from
  https://metadata.layerzero-api.com/v1/metadata/dvns
- Safe addresses per chain — already in dispatcher JSON `safe` field

## Execution path

Whichever option, the final flow is:

1. Generate 19 Safe batch JSON files in `scripts/safe/2dvn-*.json`
2. For each chain, upload its batch to Safe UI (or for in-house Safe
   chains — Cronos/Sei/Flare/Abstract — run via the existing
   `scripts/safe/execBatch.ts` script)
3. Sign + execute (2/2 multi-sig)
4. Verify with `lz:oapp:config:get` or LayerZero Scan

## Sanity check first

Before writing anything, query the current DVN config on at least
one chain to confirm the audit (zero required DVN) is still accurate:

```bash
cast call 0x1a44076050125825900e736c501f859c50fE728c \
  "getConfig(address,address,uint32,uint32)" \
  <DISPATCHER> <SEND_LIB> <DEST_EID> 2 \
  --rpc-url $POLYGON_RPC | xxd
```

Decode as `UlnConfig` — if `requiredDVNCount == 0` we confirm the gap.
