# Magneta — Incident Response Runbook

> **À 3h du matin, sous adrénaline, tu auras 3 minutes pour décider.**
> Ce document est ton check-list. Il est conçu pour être lu rapidement
> et exécuté ligne par ligne.

**Dernière révision** : à dater à la première vraie utilisation
**Status** : 🟡 SQUELETTE — à compléter au fur et à mesure (sections marquées `TODO`)

---

## 0. Boîte à outils permanente

À garder accessible **hors-ligne** (printout dans un classeur, fichier sur clé USB, page Notion offline-cached) :

- Cette page (INCIDENT_RUNBOOK.md)
- Liste des contrats déployés (`deployments/*.json`)
- Clés d'urgence (encrypted, password manager backup) : deployer, relayer, pause guardian
- Numéros de téléphone des signers du multisig + auditeurs + contacts CEX
- Accès SSH au VPS (clé sur clé USB chiffrée)

---

## 1. Sévérité — décide en 30 secondes

| Niveau | Signes | Action immédiate |
|--------|--------|------------------|
| 🔴 **P0 — Drain en cours** | Transferts sortants anormaux du feeVault / MagnetaPool / Bridge ; LP en baisse rapide non liée au marché | Section 4.1 — Pause tout, alerter, war room |
| 🟠 **P1 — Exploit détecté, pas encore drain** | Transaction match un pattern d'attaque (flash loan, oracle manipulation), bug bounty whitehat report critique | Section 4.2 — Pause contrats concernés, investigation 60 min |
| 🟡 **P2 — Anomalie suspecte** | Volume × 100 inattendu, ownership transfer non-planifié, alert Forta non-critique | Section 4.3 — Investigation 4h, pas de pause sauf si confirmation |
| 🟢 **P3 — Bug fonctionnel** | Frontend cassé, listing erroné, transaction stuck, etc. | Section 4.4 — Communication, fix dans la journée |

**Règle d'or** : en cas de doute entre 2 niveaux, **prends le pire**. Pauser pour rien coûte 30 min ; ne pas pauser à temps coûte des millions.

---

## 2. Contacts d'urgence

> 🚧 **À remplir au fur et à mesure**

| Rôle | Nom | Téléphone | Email | Signal/Telegram |
|------|-----|-----------|-------|-----------------|
| Owner / Deployer | Dominique | TODO | bosacks@mail.com | TODO |
| Co-signer multisig | TODO | TODO | TODO | TODO |
| Auditeur référent | (à recruter) | — | — | — |
| Contact LayerZero (Bridge incident) | TODO | — | TODO | TODO |
| Contact Binance compliance (freeze stolen funds) | TODO | TODO | TODO | — |
| Contact Coinbase compliance | TODO | TODO | TODO | — |
| Contact OKX compliance | TODO | TODO | TODO | — |
| Avocat crypto (Canada) | TODO | TODO | TODO | — |

**Comment contacter un CEX en incident** : passer par le formulaire compliance + tweet public taggant `@cz_binance`, `@brian_armstrong`, etc. Les exchanges réagissent en 30-60min pour freeze sur tweet public d'un incident sérieux.

---

## 3. Adresses critiques par chaîne

Source : `deployments/<chain>.json`

### Mainnets

| Chain | MagnetaProxyV2 | MagnetaPool | MagnetaGateway | feeVault | pauseGuardian (on-chain) | Safe owner |
|-------|---------------|-------------|----------------|----------|---------------|------------|
| Polygon | TODO | TODO | TODO | `0x68109132...d9d68b` | `0x92F440Bc...4260` ✓ rotated 2026-05-09 | `0x4AeA3A3...EC2F` |
| Arbitrum | TODO | TODO | TODO | TODO | `0x92F440Bc...4260` (présumé après rotation 05-09) | TODO |
| Base | TODO | TODO | TODO | TODO | `0x92F440Bc...4260` (idem) | TODO |
| BSC | TODO | TODO | TODO | TODO | `0x92F440Bc...4260` (idem) | TODO |
| (autres 16 chaînes…) | … | … | … | … | … | … |

> ⚠️ **Divergence connue** : `scripts/deploy/chainConfig.ts:17` contient encore l'ancien guardian `0x479ED5228DCcef6CD05C98A5fe81aCF08F2f5998`. Toute redéploiement depuis ce script initialisera le contrat avec l'ancien guardian → régression silencieuse jusqu'à un batch Safe `rotateGuardian` qui suit. **À fixer avant tout nouveau déploiement** (ligne 17 = `0x92F440Bc1f1FaBD6D3e6256491631E07857F4260`).

> 💡 **Tip** : `jq -r '.contracts.MagnetaProxyV2' deployments/<chain>.json` te donne l'adresse rapidement.

### Testnet (drill / training)

| Chain | MagnetaSwap | MagnetaPool | MagnetaGateway | MagnetaFactory | MagnetaLending | MagnetaBridgeOApp |
|-------|-------------|-------------|----------------|----------------|----------------|-------------------|
| Base Sepolia | `0x4A5737...c4b8E` | `0x37A5D5...0e5Ab` | `0x14fe8c...3DceF` | `0xf5baA0...aF2Dc` | `0x8cb71B...46102` | `0x0a78D6...e79E5` |

**Owner sur Base Sepolia** (testnet) : `0x7900F22d8d6b234E87499F1d5b59e868963387EB` — c'est le deployer EOA, clé privée dans `~/Projets/DevWallet/.env` sous `FAUCET_PRIVATE_KEY`.

**Pause Guardian sur Base Sepolia** : `0x0000...0000` (UNSET, vérifié on-chain 2026-05-20). Le mécanisme `setPauseGuardian` existe en code mais n'a jamais été initialisé sur testnet → modifier `onlyOwnerOrGuardian` retombe sur owner-only. Pour drill la voie guardian distincte, il faut `setPauseGuardian()` avec une EOA de test séparée.

---

## 4. Procédures par type d'incident

### 4.1 — 🔴 P0 : Drain en cours

**SLA** : pause tous les contrats critiques dans **les 60 secondes** après détection.

1. **NE PAS ouvrir Twitter, NE PAS lire les DM** — focus.
2. **Ouvre l'onglet `cast` déjà loggé** (ou ssh `vps-magneta`). Si tu dois te logger, tu perds 30 secondes critiques.
3. **Exécute les pauses dans l'ordre :**
   ```bash
   # Variables d'env (export-les au boot de ta shell, jamais à taper sous stress)
   export RPC_POLYGON="https://polygon-rpc.com"
   export OWNER_KEY="..."   # depuis password manager pré-chargé
   export PROXY_POLYGON="$(jq -r .contracts.MagnetaProxyV2 deployments/polygon.json)"
   export POOL_POLYGON="$(jq -r .contracts.MagnetaPool deployments/polygon.json)"
   export GATEWAY_POLYGON="$(jq -r .contracts.MagnetaGateway deployments/polygon.json)"

   # Pause les 3 surfaces user-facing en parallèle (3 terminaux ou & en bash)
   cast send "$PROXY_POLYGON"   "pause()" --rpc-url "$RPC_POLYGON" --private-key "$OWNER_KEY" &
   cast send "$POOL_POLYGON"    "pause()" --rpc-url "$RPC_POLYGON" --private-key "$OWNER_KEY" &
   cast send "$GATEWAY_POLYGON" "pause()" --rpc-url "$RPC_POLYGON" --private-key "$OWNER_KEY" &
   wait
   ```
4. **Réplique sur les chaînes affectées.** Si l'exploit cible Polygon, vérifie d'abord si Base/Arbitrum/etc. sont touchées (même pattern de transactions). Sinon, on garde l'écosystème vivant pendant l'incident.
5. **Annonce 1-liner sur Twitter** (template) :
   > *"Incident detected on Magneta. Contracts paused on [chain]. Investigation in progress. No funds movement possible while paused. Updates here within 30 min."*
6. **War room Discord** : ouvre `#🚨-incident-active`, ping `@security-council`.
7. **Capture la tx attaquante** : `cast tx <hash> --rpc-url $RPC` + screenshot Etherscan + sauvegarde dans `/incidents/YYYY-MM-DD/`.
8. **Contact CEX** où les fonds volés vont probablement passer (cf section 2). Tweet public `@cz_binance @brian_armstrong "Magneta exploit, stolen funds bridged to [exchange]: [tx hash]"` accélère la réponse.
9. **NE PAS unpauser** avant que les questions suivantes aient une réponse claire :
   - Quelle est la vulnérabilité exacte ?
   - Est-ce qu'un fix on-chain est nécessaire avant unpause ?
   - Combien a été drainé ? Sur quel pool ?
   - Y a-t-il une LP / treasury à compenser ?

### 4.2 — 🟠 P1 : Exploit détecté, pas encore drainé

**SLA** : pause contrats concernés en **5 minutes**.

> 🚧 **À détailler** — pour l'instant : même flow que P0 mais avec 5 min de fenêtre pour vérifier que c'est bien un vrai exploit avant de pauser. Cas typique : un whitehat te DM avec un PoC, ou Forta agent flag un pattern.

### 4.3 — 🟡 P2 : Anomalie suspecte

> 🚧 **À détailler** — investigation, pas de pause sauf escalation à P1.

### 4.4 — 🟢 P3 : Bug fonctionnel

> 🚧 **À détailler** — communication user + fix dans la journée.

---

## 5. Patterns d'incidents documentés

> 🚧 **À remplir après chaque incident réel** (postmortem). Format suggéré :

### Template — postmortem

- **Date** : YYYY-MM-DD
- **Sévérité** : P0/P1/P2/P3
- **Durée détection → pause** : Xs
- **Durée pause → fix** : Xh
- **Tx attaquante** : `0x...`
- **Pertes** : $X (USDC equivalent)
- **Cause technique** : (vulnérabilité exacte, ex: "MagnetaSwap.swap() missed reentrancy guard on token0 callback")
- **Cause organisationnelle** : (process qui aurait permis de l'éviter)
- **Mesures prises** : (fix code, ajustement runbook, etc.)

---

## 6. Communications publiques

### Templates Twitter

**T+0 — Détection** :
```
We've detected unusual activity on Magneta. Contracts paused on [chain]. 
Investigation ongoing. No new transactions possible during pause. 
Updates within 30 min.
```

**T+30 — Premier update** :
```
Update on the incident: 
- [What we know about the cause]
- [Funds affected: yes/no, scope]
- [Next steps]
We'll post the full postmortem within 24h.
```

**T+24h — Postmortem** : lien vers article Mirror.xyz détaillant
- Root cause
- Pertes (s'il y en a)
- Plan de compensation (s'il y a lieu)
- Mesures pour que ça ne se reproduise pas

### Discord war room — opening message

```
🚨 INCIDENT ACTIVE - Severity: [P0/P1/P2/P3]
Chain(s) affected: [chain list]
Status: Investigating / Paused / Fixing / Resolved
Lead: @Dominique
Updates every 15 min in this thread.
```

---

## 7. Checklists de prévention (avant chaque release)

> 🚧 **À étoffer**

- [ ] Code review interne
- [ ] Tests Foundry > 90% coverage sur fonctions critiques
- [ ] Pas d'admin keys EOA en production
- [ ] Pause guardian configuré et testé (cf `scripts/test/pause-guardian-drill.sh`)
- [ ] Timelock activé sur les changements de paramètres
- [ ] Bug bounty visible Immunefi
- [ ] Monitoring on-chain configuré (magneta-listener + Forta agents)
- [ ] Alerting multi-canal (Discord + Telegram CRITICAL)

---

## 8. Drills à faire régulièrement

| Fréquence | Drill | Script |
|-----------|-------|--------|
| Trimestriel | Pause guardian end-to-end | `scripts/test/pause-guardian-drill.sh` |
| Trimestriel | Restauration backup base de données (Scope subgraph) | TODO |
| Annuel | Tabletop incident response (sans pause réelle, mais lecture du runbook chronométré) | TODO |
| Annuel | Recover from compromised deployer key | TODO |

### Historique des drills

| Date | Chain | Latence pause | Latence unpause | Anomalies / leçons |
|------|-------|---------------|-----------------|--------------------|
| 2026-05-20 | Base Sepolia | 9.51s (3 contrats, avec sleep 1.5s entre tx) | 9.45s | Round 1 v1 du script avait nonce collision sur public RPC `sepolia.base.org` → unpause Swap+Pool ont fail silencieusement. Fix v2 = capture stderr + sleep 1.5s entre cast send. `MagnetaBundler` n'expose pas `paused()` getter — non-observable on-chain. `MagnetaSwap` utilise pattern custom `bool paused` au lieu d'OpenZeppelin Pausable (à flagger en audit). |

### SLA cibles dérivées du baseline 2026-05-20

| Scénario | Latence cible | Latence observée |
|----------|---------------|------------------|
| Pause 3 contrats sur 1 chaîne, public RPC + sleep | < 15s | 9.51s ✓ |
| Pause 3 contrats sur 1 chaîne, private RPC sans sleep (mainnet panic) | < 8s | À mesurer en condition réelle (drill mainnet à programmer) |
| Pause 19 chaînes en parallèle (1 worker/chain) | < 30s | Non testé — implique de scripter le parallélisme et avoir un RPC privé sur chaque chaîne |
| Pause 19 chaînes en série | < 5 min | Non testé — à éviter en panic, parallélisation obligatoire |

### Note opérationnelle pour mainnet panic

- **Toujours utiliser un RPC privé** (Alchemy/QuickNode/Infura) pour les pauses d'urgence — le public peut rate-limit ou cache le nonce au pire moment.
- **Avoir l'env var `OWNER_KEY` déjà exportée** dans la shell que tu garderas ouverte 24/7 (ou rechargeable en une commande depuis password manager) — éviter d'avoir à `cat .env` sous adrénaline.
- **Paralléliser les chaînes** : `for chain in polygon arbitrum base ...; do pause_chain $chain & done; wait`. Pas en série.

---

## 9. Ressources externes

- **Immunefi bug bounty** : https://immunefi.com/bug-bounty/[magneta] *(à configurer)*
- **Forta agents** : https://app.forta.network/ (search Magneta contracts)
- **OpenZeppelin Defender** : https://defender.openzeppelin.com/ (autotask + monitoring)
- **Tenderly** : https://tenderly.co/ (transaction simulation + alerts)
- **REKT news archive** : https://rekt.news/ (apprendre des autres exploits)

---

## 10. Historique des révisions

| Date | Auteur | Changement |
|------|--------|------------|
| 2026-05-20 | Dominique + Claude | Création du squelette initial. Premier drill Base Sepolia exécuté : latence baseline 9.51s pause / 9.45s unpause sur 3 contrats. Bug nonce/rate-limit identifié sur public RPC + fixé dans script v2. Divergence chainConfig.ts vs guardian on-chain mainnet identifiée à corriger avant tout redéploiement. |

---

*Si tu lis ce document parce qu'un incident est en cours, va directement à la section 4.x correspondant à ta sévérité. Le reste peut attendre.*
