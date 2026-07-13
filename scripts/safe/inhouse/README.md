# Safe in-house — déploiement et exécution sans Safe Wallet UI

Pour les chaînes où **app.safe.global** ne supporte pas l'UI (Cronos, Dexalot, Abstract, Rootstock, Flare, Sei, etc.), ces scripts permettent de :

1. Déployer un Safe Magneta avec nos params (2 owners, threshold 2, SafeL2 v1.4.1)
2. Exécuter des batches Safe Tx Builder JSON directement on-chain via `execTransaction`

Les contrats Safe canoniques (`SafeProxyFactory`, `SafeL2`, `MultiSendCallOnly`, `SafeSingletonFactory`) sont déjà déployés par Safe team sur la plupart des chaînes EVM, même celles non supportées par leur UI. Pour `Dexalot` (et toute autre chaîne sans cette infra), utiliser `deploySafeInfra.ts` (à venir).

## Address Magneta Safe in-house

```
0x40ea2908Ea490d58E62D1Fd3364464D8A857b297
```

Cette adresse est **CREATE2-déterministe** : même adresse sur **toute chaîne** ayant le canonical SafeProxyFactory + SafeL2 + nos params (saltNonce=0).

⚠️ **Note importante** : différente de l'adresse `0xC4c96aF54cdE078dc993d6948199b0AF8cD6717a` que Safe Wallet UI a déployée sur les 14 chaînes supportées. C'est normal — Safe Wallet UI utilise un saltNonce timestamp-based qu'on ne peut pas reproduire sans leur backend. Sécurité identique (mêmes owners + threshold), juste une adresse différente.

## Workflow standard

### Étape 1 — Vérifier l'address prédite

```bash
pnpm ts-node scripts/safe/inhouse/predictAddress.ts
```

Affiche l'adresse qui sera déployée.

### Étape 2 — Déployer le Safe sur une chaîne

```bash
pnpm hardhat run scripts/safe/inhouse/createMagnetaSafe.ts --network cronos
```

Le script :
- Vérifie que les contrats Safe canoniques existent sur la chaîne
- Calcule l'adresse prédite
- Si déjà déployé → vérifie owners + threshold + skip
- Sinon → appelle `SafeProxyFactory.createProxyWithNonce(...)`
- Met à jour `deployments/<network>.json` avec `gnosisSafe`

### Étape 3 — Exécuter un batch Safe via script

```bash
PAUSE_GUARDIAN_PRIVATE_KEY=0x... \
  BATCH=scripts/safe/cronos-acceptOwnership-batch.json \
  pnpm hardhat run scripts/safe/inhouse/execBatch.ts --network cronos
```

Le script :
- Charge le batch JSON (format Safe Tx Builder)
- Lit le Safe address depuis `deployments/<network>.json`
- Encode en MultiSend si plusieurs tx
- Calcule `safeTxHash` (EIP-712)
- Signe avec les 2 owners (Deployer via Hardhat config + PauseGuardian via env)
- Submit `execTransaction(...)`

## Sécurité et secrets

- `DEPLOYER_PRIVATE_KEY` ou `PRIVATE_KEY` : déjà dans la config Hardhat (deployer EOA)
- `PAUSE_GUARDIAN_PRIVATE_KEY` : **fournir uniquement quand on exécute `execBatch.ts`**, jamais en config persistante
  - Recommandation : utiliser `direnv` ou un manager de secrets, ne pas le mettre dans `.env`
- Les 2 clés EOA pour notre Safe 2/2 sont détenues par Dominique (même opérateur)
- En cas de besoin de gouvernance étendue (3e signataire externe), augmenter threshold du Safe via `swapOwner` + `changeThreshold`

## Cas particuliers par chaîne

| Chaîne | Safe canonical infra | Action |
|--------|---------------------|--------|
| Cronos | ✅ déployé | `createMagnetaSafe.ts` direct |
| Abstract | ✅ déployé | `createMagnetaSafe.ts` direct |
| Rootstock | ✅ déployé | `createMagnetaSafe.ts` direct |
| Flare | ✅ déployé | `createMagnetaSafe.ts` direct (rétroactif post-deploy contrats) |
| Sei | ✅ déployé | `createMagnetaSafe.ts` direct (rétroactif post-deploy contrats) |
| Dexalot | ❌ rien déployé | `deploySafeInfra.ts` d'abord, puis `createMagnetaSafe.ts` |

## Coûts estimés (déploiement Safe)

`createProxyWithNonce` consomme ~250-400k gas. Coût selon la chaîne :

- Chaînes EVM cheap (Linea, Base, Optimism, Sonic) : ~$0.50-1.00
- Chaînes EVM moyennes (Polygon, Avalanche, Arbitrum) : ~$0.50-2.00
- Chaînes EVM chères (Ethereum) : $20-100 (à éviter sauf besoin)
- Cronos (gas haute mais CRO cheap) : ~$0.30
- Berachain, Mantle, etc. : ~$0.50

## Files

| Fichier | Rôle |
|---------|------|
| `lib/safe.ts` | Helpers : address calc, EIP-712 sign, MultiSend encoding, constants Safe v1.4.1 |
| `predictAddress.ts` | Affiche l'address prédite — sanity check sans réseau |
| `createMagnetaSafe.ts` | Deploy le Safe Magneta sur la chaîne courante |
| `execBatch.ts` | Execute un batch Safe Tx Builder JSON via `execTransaction` |
| `deploySafeInfra.ts` | (TODO) Deploy SafeProxyFactory + SafeL2 sur chaîne sans canonical infra (Dexalot) |

## Migration depuis Safe Wallet UI vers Safe in-house

Pour les chaînes où on a déjà un Safe via UI (`0xC4c9...717a`), **rien à changer** : ce Safe reste fonctionnel via app.safe.global. Les scripts in-house sont uniquement pour les chaînes non supportées.

Si on veut tout consolider sous un seul système (in-house partout) :
1. Sur chaque chaîne déjà déployée, soit on ajoute le Safe in-house en parallèle, soit on transfert l'ownership des contrats vers le Safe in-house via une tx du Safe UI actuel
2. Mais c'est un gros chantier et ça complique sans valeur claire — déconseillé sauf besoin spécifique
