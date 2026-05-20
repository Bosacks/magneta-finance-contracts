# Pause Guardian Fire Drill — Mode d'emploi

## Pré-requis

- **Foundry** installé (`cast` doit être dans le PATH)
  ```bash
  curl -L https://foundry.paradigm.xyz | bash && foundryup
  ```
- **jq** installé (la plupart des distros l'ont déjà)
- **Une clé privée** qui correspond au `owner` des contrats sur Base Sepolia
  - Sur testnet, c'est le deployer EOA `0x7900F22d8d6b234E87499F1d5b59e868963387EB`
  - Tu retrouves cette clé dans ton password manager (probablement labellée `magneta-testnet-deployer` ou similaire)

## Run en dry-run (read-only, recommandé en premier)

```bash
cd ~/Projets/magneta-finance-contracts

export DEPLOYER_PRIVATE_KEY=0x0000000000000000000000000000000000000000000000000000000000000001
DRY_RUN=1 ./scripts/test/pause-guardian-drill.sh
```

→ Lit l'état actuel des 4 contrats pausables, simule les calls, n'envoie aucune transaction. Sert à valider :
- Que ton RPC fonctionne (chainId 84532 attendu)
- Que les contrats répondent à `paused()` et `owner()`
- Que ton script lit bien les addresses depuis `deployments/baseSepolia.json`

## Run en mode live (vraies transactions sur Base Sepolia)

```bash
cd ~/Projets/magneta-finance-contracts

# Mets la VRAIE clé du deployer testnet (pas 0x000...001)
export DEPLOYER_PRIVATE_KEY=0x<ta_vraie_cle_testnet>

# Optionnel — RPC alternatif si sepolia.base.org est down
# export BASE_SEPOLIA_RPC=https://base-sepolia.g.alchemy.com/v2/<api_key>

./scripts/test/pause-guardian-drill.sh
```

## Ce que le script fait, dans l'ordre

1. **Phase 1 — Pre-flight** : lit l'état actuel (`paused()`) et le owner de chaque contrat pausable. Te dit si quelque chose va casser avant de toucher quoi que ce soit.
2. **Phase 2 — Pause** : envoie `pause()` sur les 3-4 contrats. Mesure le temps écoulé entre le premier et le dernier tx confirmé. **C'est cette latence qu'il faut connaître par cœur pour ton runbook.**
3. **Phase 2b — Verify** : 3s d'attente puis re-lit `paused()` sur chacun pour confirmer le state changé.
4. **Phase 3 — Revert verification** (optionnelle) : appelle `swap()` sur MagnetaSwap pausé en s'attendant à ce que ça revert avec une erreur "Pausable: paused" ou "EnforcedPause". Skippée si `SKIP_SWAP_TEST=1`.
5. **Phase 4 — Unpause** : restaure l'état normal. Mesure aussi la latence.
6. **Phase 4b — Verify** : confirme `paused() == false` partout.

## Coût en gas

Sur Base Sepolia (gratuit, faucet) :
- 4 × `pause()` + 4 × `unpause()` = ~8 transactions
- Total ~200k gas combiné ; à 0.05 gwei sur Base Sepolia = négligeable
- Si tu n'as pas de testnet ETH : https://www.alchemy.com/faucets/base-sepolia (0.1 ETH gratis)

## Ce que tu dois noter après ton premier run

Dans `INCIDENT_RUNBOOK.md` section 8, mets à jour avec :

- **Date du dernier drill** : YYYY-MM-DD
- **Latence Phase 2 (pause)** : Xs total ; pire cas si Phase 4 prend < ce nombre = anomalie
- **Anomalies détectées** : ex: "MagnetaBundler n'a pas de getter paused()" (déjà connu, le contrat utilise un pattern différent)
- **Action de remédiation** : si > 60s pour pause complète, voir comment paralléliser ou pré-loader les commandes

## Variantes

| Variable | Effet |
|----------|-------|
| `DRY_RUN=1` | Aucune tx envoyée, juste les reads + logs |
| `SKIP_SWAP_TEST=1` | Skip la phase 3 (pratique si tu n'as pas de mock tokens) |
| `BASE_SEPOLIA_RPC=<url>` | RPC alternatif (Alchemy, Infura, QuickNode) |

## Prochaines évolutions du drill

À ajouter quand pertinent :

- [ ] Drill sur Polygon mainnet (avec une vraie clé `pauseGuardian`, pas owner) — quand le pauseGuardian sera wired
- [ ] Drill cross-chain (pause sur 3 chaînes en parallèle, mesure latence agrégée)
- [ ] Variante "war room simulation" qui télécharge les addresses depuis Etherscan plutôt que `deployments/*.json` (pour répliquer le cas où tu n'as pas accès au repo)
