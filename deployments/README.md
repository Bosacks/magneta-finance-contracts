# Deployments registry

Source of truth for every Magneta contract address on every network.

## Layout

```
deployments/
  <network>.json       one per network (hardhat network name)
  index.ts             typed loader — imported by SDKs / apps
  README.md            this file
```

Each JSON file follows [`Deployment`](./index.ts):

```json
{
  "network": "baseSepolia",
  "chainId": "84532",
  "deployer": "0x...",
  "admin": "0x...",
  "timestamp": "2026-03-07T17:41:44.424Z",
  "contracts": {
    "MagnetaPool": "0x...",
    "MagnetaSwap": "0x..."
  }
}
```

## After a new deploy

1. Commit the updated `<network>.json` — no other manual step.
2. Consuming repos should pin to this commit (via the SDK package or a
   git submodule) and re-release.
3. Run `pnpm ts-node scripts/verify-deployed.ts <network>` to confirm
   every address has code and the admin matches.

## Consuming from another repo

```ts
import { address } from "@magneta/contracts/deployments";

const pool = address("base", "MagnetaPool");
```

## Explorer verification

After a deploy, verify the source on the explorer so users can read
the code. Example for Base:

```bash
pnpm hardhat verify --network base <ADDRESS> <CONSTRUCTOR_ARG_1> <CONSTRUCTOR_ARG_2>
```

Requires `ETHERSCAN_API_KEY` (works on Basescan / Arbiscan / etc.) in
the hardhat config — see `hardhat.config.ts`.
