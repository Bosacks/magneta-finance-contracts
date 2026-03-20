# Magneta Finance — Core Contracts (magneta-finance-contracts)

Contrats Solidity du protocole DeFi Magneta : pool de liquidité, swap, lending, farm, bundler.

## Stack
- **Solidity** : 0.8.20, OpenZeppelin
- **Tests** : Foundry (forge) + Hardhat
- **Réseau déployé** : Base Sepolia (testnet), Base Mainnet (cible)
- **Déploiements** : `deployments/baseSepolia.json`

## Contrats principaux
| Contrat | Rôle |
|---------|------|
| `MagnetaPool` | Pool de liquidité |
| `MagnetaSwap` | AMM swap |
| `MagnetaFactory` | Création de pools |
| `MagnetaLending` | Prêts/emprunts |
| `MagnetaFarm` | Yield farming |
| `MagnetaDLMM` | DLMM (concentrated liquidity) |
| `MagnetaBundler` | Bundle buy/sell, volume brush |
| `RewardToken` | Token de récompenses |

## Skills à activer

| Situation | Skill |
|-----------|-------|
| Développement ou modification de contrats | `/web3` |
| Audit de sécurité, analyse de vulnérabilités | `/cybersecurite` |
| Développement d'une fonctionnalité complexe | `/codage-antigravity` |
| Review de contrats avant déploiement | `/code-review` |

## Sécurité — Checklist avant déploiement
- [ ] Slither sans warnings critiques
- [ ] Forge tests coverage > 95%
- [ ] Slippage protection sur tous les swaps
- [ ] ReentrancyGuard sur toutes les fonctions ETH/token
- [ ] Testé sur Base Sepolia 48h minimum
- [ ] Audit externe si TVL > 50k$

## Conventions
- Commits en anglais, format `type: description`
- Toujours vérifier les patterns CEI (Checks-Effects-Interactions)
- Adresses de contrats déployés dans `deployments/` uniquement (pas dans le code)
