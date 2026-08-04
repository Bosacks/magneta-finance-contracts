## 2026-08-03 — Modèle pump.fun : part créateur, AMM de graduation maison, chemin prouvé on-chain

- **Le launchpad n'était PAS dans le périmètre de la vague** : `redeployGatewayWave.ts` liste `MagnetaCurveFactory` comme SEPARATE — Base était « finie » et tournait encore une factory sans le correctif CRITICAL du rapport 21
- Modèle pump.fun adopté (leur grille du 20/05/2026) : commission **1,25 % = 0,95 protocole + 0,30 créateur**, création gratuite hors gaz. Frais créateur **accumulés et réclamés**, jamais poussés — un créateur-contrat refusant le natif bloquerait sinon tous les échanges de sa propre courbe
- **AMM de graduation déployé** sur Base Sepolia (factory `0xFfce1501…`, routeur `0x9cb70bd7…`, `setFeeTo(FeeVault)` appliqué) : les graduations cessent de céder 100 % du volume secondaire à BaseSwap/QuickSwap ; 0,05 % de chaque swap revient désormais au FeeVault à perpétuité
- `INIT_CODE_PAIR_HASH` vérifié **empiriquement** contre la factory déployée (créer une paire, comparer au CREATE2) : sans ça, `pairFor` viserait des adresses vides et **toutes les graduations reverteraient** sans message
- Déploiement du core V2 obligatoirement via **Hardhat** : l'artefact Foundry du même source aux mêmes réglages hashe différemment (métadonnées)
- Chemin de l'argent **prouvé on-chain** : courbe → répartition 3e11/9,5e11 wei exacte → graduation → paire sur l'AMM Magneta → 140,53 LP au DEAD → pool vidé → frais créateur réclamés
- **Staking : 2 défauts réels corrigés** — `stake()` créditait le demandé et non le reçu ; `notifyRewardAmount` ne tirait pas les fonds (motif Venus, qu'une donation d'un tiers permettait d'exploiter). Le menu « Stake to Earn » du DEX est ACTIF et les 20 factories déployées portent encore l'ancien code
- Suite Testsites **débloquée** : elle ne compilait pas du tout (3 tests morts) ; 208/210 après resynchronisation de 11 contrats et 19 tests en retard sur main
- `maxPriceImpactBps` absent des contrats des **deux** dépôts — sa seule spécification survivante préservée en `test/attic` avec un README qui interdit de la jeter
- Financement rechiffré sur des tailles mesurées : **26,3M gas/chaîne**, ~108 $ au total. Linea en représente la moitié (plancher de 1 gwei, confirmé sur 2 RPC)
- XCommentExporter terminé (backend `/api/x-comments`, format effectif, vrai téléchargement) ; surveillance VPS réparée : discord-bot mort depuis le 29/07 (93 618 redémarrages), 0 unité en échec

## 2026-08-02 — Audit économique des 4 moteurs de liquidité + DLMM fermée sur 20 chaînes

- Audit économique (3 agents, périmètres disjoints, chaque finding porteur revérifié par moi dans le code et on-chain) : courbe, MagnetaPool/Swap, MultiPool, adaptateurs
- **CRITICAL courbe** : `finalizeGraduation` passé 7 jours met `amountTokenMin` ET `amountETHMin` à **0** (l.423-425) → dépôt V2 au ratio d'une paire amorçable à la poussière. Reproduit : +148,5 ETH pour 1 ETH engagé, ou 149,5 ETH balayés vers le feeVault (l.452)
- Aggravant STRUCTUREL : la bande compare au prix terminal `nativeRaised/tokensSold` alors que les mins dérivent de `nativeRaised` sur `totalSupply−curveAllocation` → **deux ratios incompatibles, le chemin honnête est inatteignable** ; le délai de 7 j n'est pas un filet, c'est la porte
- Le test `H-1` du dépôt EXÉCUTE cette attaque et la déclare réussie (n'assère qu'un événement, jamais un solde)
- **Correctif adaptateurs jamais déployé** : `pullMeasured` (f401f9a, 27/07) fait 2 `balanceOf` — absents du bytecode vivant sur sei/avalanche, manifestes du 21/07. 3e occurrence du jour d'un correctif mergé qui n'atteint pas la chaîne
- MagnetaPool : frais 0,3 % contournables (`swap` sans restriction d'appelant), pas de plafond d'impact. **Sa math est saine** — le défaut est l'emplacement des frais, pas le modèle. MultiPool non déployé
- **Tout est latent** : 0 pool AMM sur 5 chaînes, 0 courbe, 0 pool DLMM
- ⛔ **20/20 MagnetaFactory PAUSÉES** (vérifié on-chain) — `createDLMMPool` était ouverte sur 20 chaînes, pas 3. Aucun lot Safe requis (guardian déjà pauser), coût produit nul (le site n'appelle pas la factory)
- Marge EIP-170 mesurée AVANT d'écrire le correctif : CurveFactory 19 274 o, marge 5 302 — la refonte a la place

# Journal — magneta-finance-contracts

> Fil chronologique des sessions. Anti-chronologique (plus récent en haut).
> Voir `~/CLAUDE.md` pour la règle d'édition.

## 2026-08-01 — 19:59 — Rapport 19 remédié + vague Base Sepolia (a5db67e)

- 16 findings corrigés en 4 périmètres disjoints : TaxClaim (plancher de slippage réel + delta de solde au lieu du retour routeur + reset d'allowance + revert au lieu du paiement local + `registerToken` vérifié avec chemin de réparation), Gateway (earmarks préservés + `adminRefundPendingValueOp` + montant nul rejeté + version inconnue rejetée + plancher DVN + plafond de frais), TokenCreation (nonce local), LPModule (code mort + tokenSource)
- Arbitrage F-3 : **sûreté > vivacité** — une op n'est servie que si le solde restant couvre tous les autres engagements ; la vivacité revient par le remboursement admin, qui fait porter la perte du bridge à l'opérateur et non à un tiers
- Suites : forge **367/367**, hardhat racine **513/513**, tokens **189/189**
- 2 tests épinglaient le bug F-12 (« le second appel local reverte toujours ») → récrits après avoir vérifié que le rejeu sur GUID reste couvert ailleurs
- 8 échecs hardhat étaient **pré-existants et invisibles** : le commit permit du 31/07 a ajouté un champ à `CreateLPParams`, et `MockV2Router` n'implémentait pas `getAmountsOut` que le durcissement TaxClaim appelle — la remédiation 15-18 a été mergée avec une suite rouge
- **DÉCOUVERTE : `MagnetaFactory` = 27 132 o > EIP-170.** Elle embarque `new MagnetaDLMM(...)` : mon correctif CRITICAL DLMM du 31/07 l'a fait dépasser → **le fix DLMM est INDÉPLOYABLE**. Base Sepolia sert encore 20 518 o (version d'avant). Remède = déployeur séparé, comme la factory de tokens
- Base Sepolia redéployé en bloc : Gateway `0xec7beC25`, LPModule `0x87B6c972`, SwapModule `0x016f4409`, TokenOpsModule `0x402f6a8D`, TaxClaim `0x2e7732Bd` ; sélecteurs neufs vérifiés on-chain, `setRequiredDVNCount(1)` rejeté par ma garde (0x4345069c), smoke **ALL GREEN**
- 2 défauts de scripts corrigés, vus seulement en réel : `redeployGatewayStack.ts` ne réglait jamais le quorum DVN (tout module revertait) ; le smoke lisait des blocs rassis et n'était jouable qu'une fois (assertions passées en deltas)

## 2026-08-01 — 18:05 — Rapport 19 dépouillé : 16 findings réels sur 22, mainnet tourne du pré-audit

- Rapport 19 (panel, groupe 06) : 22 findings, 1 CRITICAL + 7 HIGH. Triage : **16 RÉELS, 4 faux positifs, 2 atténués** — chacun revérifié à la main ou on-chain, jamais sur la foi du rapport
- **F-1 CRITICAL confirmé on-chain** : 6 chaînes sondées (base, arbitrum, optimism, bsc, avalanche, gnosis) → TOUS les modules couche B exposent l'ANCIEN sélecteur `execute` (sans guid), sans `withdrawPendingRefund` ; le mainnet tourne du code **pré-remédiation 13-18**. Bruit à écarter : le scanner mesure aussi `deployments/` (couche A héritée) et `arbitrumSepolia.json` que j'avais marqué DEPRECATED
- **F-6 est PIRE que le rapport** : le TaxClaimModule déployé n'a même pas `maxSlippageBps` (revert on-chain) et l'UI passe `amountOutMin: 0n` en dur sur ses 3 chemins → plancher de slippage NUL en prod, sandwich exploitable dès $20 (`minUsdc`)
- **F-10 actif en prod** : `cctpMessenger()` = 0 sur Base alors que l'UI propose la case « Bridge to treasury » → paiement local silencieux, aucun revert
- Hors rapport (le panel ne voyait pas le site) : le SDK encode `ClaimParams` à **4 champs** contre **5** sur main → déployer TaxClaim durci CASSE le claim frontend ; et `test_SandwichedClaimRevertsOnTheProportionalFloor` teste un routeur malhonnête, pas un sandwich (fausse assurance)
- Faux positifs écartés : F-5 (frais 0,15 % — la Gateway prélève en natif AVANT le module, vérifié l. 208-229 + on-chain 5e14), F-21, F-19, F-14 (collision de sémantique)
- Aucun correctif appliqué : arbitrage produit requis (cf. rapport à Dominique)

## 2026-08-01 — Re-scan gratuit des contrats « fonds » à scan > 3 jours

- Re-scan couche gratuite Sentinelleai (economic+aderyn, EVM only) : launcher+adapters (panel ≤ 28/07) + code modifié après son dernier scan (LPModule permit, TaxClaim porté, Gateway GUID, Bex)
- Résultat : **0 finding nouveau** — 11 ECON + 94 aderyn, tous FP ou déjà arbitrés (fee-on-transfer non supporté, SC02/SC04 en place)
- Vérifié à la main : mins re-add LpAtomicHelper, floor TaxClaim jamais plus lax qu'`amountOutMin`, `_payNative` overridé (Gateway + DispatcherV3), `EthNotAccepted` TokenCreationModule
- Découverte : PromotionPayment fantôme sur Optimism (`0x414dC3f0…a504`, hors manifestes post-redeploy) — VIDE (0 ETH) mais codes 1-6 ENCORE PAYANTS (0,01-0,06 ETH) pour une feature que l'indexeur n'honore plus ; bytecode = version pré-pull-payment (sélecteurs vérifiés on-chain)
- Lot Safe de décommission écrit : `scripts/safe/optimism-promotionPayment-DECOMMISSION-batch.json` (1 tx `setPricesBatch([1..6],[0×6])`, réversible) — à signer avec le lot Gnosis
- Groupe `06-post-remediation-diff` ajouté à scope.json (rapport 19 recommandé AVANT la vague mainnet : Gateway+LPModule+TaxClaim+TokenCreation, modifiés après les rescans 15/16)
- Repo GitHub `Bosacks/Testsites` : existait mais VIDE — Dominique a poussé le dépôt maison (77 commits, tip 8fc67e63 vérifié) ; risque sauvegarde CLOS
- Décommissions GNOSIS **et** OPTIMISM exécutées par Dominique, toutes deux **vérifiées on-chain** : keeper XChainLpReceiver = 0xdEaD ; PromotionPayment codes 1-6 = 0 (2 RPC)
- Testsites : défaut GitHub rebasculé sur security/curve-graduation-keeper, branche ex-master (renommée par GitHub, contenu de juin) supprimée après vérif d'ancestralité — une seule branche restante

## 2026-07-31 — Rapport 18, durcissement Bex, décommissionnement Gnosis

- Balayage outils GRATUITS des contrats jamais passés au panel (slither/semgrep/mythril + couche gratuite Sentinelleai via nouveau lanceur headless) → CRITICAL DLMM : `BinHelper` tombait à prix=0, le swap avalait la mise entière en passant sa propre garde de slippage (42759b0, vérifié par simulation entière)
- 1-clic création de pool : LPModule consomme une signature EIP-2612 (cad897b) + SDK/UI côté site — repli 2-tx intact pour les jetons sans permit
- Portage Testsites→main (0db79b7) : TaxClaim durci, garde domaine CCTP (domaine 0 = Ethereum, une entrée non configurée le signifiait en silence), verrou rotation USDC ; puis resynchro inverse (a8ba8809)
- Rapport 18 (panel, 12 findings) : DLMM F-1 remplissage partiel + F-2 échange déguisé sans frais — VÉRIFIÉS à la main, défauts de modèle → refonte, différée avec le plan produit
- Bex durci (b529f44) : réentrance en lecture seule Balancer (le panel l'avait MANQUÉE, le gratuit l'avait trouvée), validation setPair contre le Vault, minLiquidity sur les joins (signature 6→7 args), fee-on-transfer mesuré
- DÉCOUVERTE : `MagnetaXChainLpReceiver` VIVANT sur Gnosis (`0xeca6092e…`) absent de TOUS les manifestes — lot Safe de décommissionnement prêt (7cb7639), à signer ; `setKeeper(0)` est rejeté par le contrat, d'où l'adresse de burn
- Suites : forge 274 → 314, hardhat racine 511, tokens 189

## 2026-07-30 — 19:55 — Vague testnet Base Sepolia : dérive close, money paths validés (715a05b)

- Merge security/audit-13-remediation → main (c769d5f) puis redeploy atomique complet sur Base Sepolia (Gateway + TOUS les modules en bloc — imposé par le changement de Context)
- 12 contrats + LPAtomic stack (helper/registry/module, jamais présent sur ce testnet) + ServiceFee + CurveFactory ; ~0,0004 ETH de gas total
- Contrôle de dérive : 12/12 longueurs bytecode on-chain == artefacts ; tous les sélecteurs que l'audit signalait absents répondent ; multiPool gate fermé, DVN=2, MAX_BATCH=50
- Smoke on-chain : payFee → FeeVault +montant exact ; Lending deposit 100 USDC → withdraw complet (scénario F-2), état final 0/0/0
- arbitrumSepolia.json marqué DEPRECATED (aucune chainConfig 421614, adresses pré-audit)
- Scripts : deployLpAtomicStack.ts + smokeTestnetStack.ts nouveaux ; fallback testnet sans Safe dans deployTokenCreation/deployServiceFee ; chemin OFT post-centralisation corrigé
- ⚠ BLOQUÉ op 13 (CREATE_TOKEN) : factories OFT testnet orphelines (owner = clé 0x7900 rotationnée/disparue) ET la factory actuelle fait 24 615 o > limite EIP-170 (déjà runs:1+viaIR) → toute future factory passe par le split factory/deployeur de la branche feat/erc20-permit-onesig (non auditée) — décision à prendre
- Pièges vécus : RPC public Base Sepolia sert des blocs rassis juste après une tx (retry obligatoire dans les scripts de vérification)

## 2026-07-30 — 3e passe — Arbitrages design + GUID + harnais hardhat (02d7257, 750a73f)

- Arbitrages Dominique appliqués : BURN_LP officiellement gratuit (doc alignée sur le site), fee-on-transfer non supporté Bundler/LPModule (doc), bridge officiel (DVN + caps entrants) différé à son activation — CCTP+LI.FI en attendant
- Oracle F-9 : `refreshPrice` = ré-ancrage progressif permissionless (1 pas de maxDeviation par bloc) — un -30 % légitime déverrouille en ~7 appels keeper ; `getAssetPrice` reste strict
- GUID F-22/31 : `bytes32 guid` dans IModule.Context (LZ guid sur _lzReceive + fulfillValueOp, 0 en local) ; clés de replay LPAtomic/TokenCreation sur le guid — ⚠ **Gateway + TOUS les modules à redéployer EN BLOC** (sélecteur d'execute changé)
- Harnais hardhat RACINE réparé : cause = chai 5 (ESM) résolu par pnpm pour la racine vs matchers chai ^4 — peer set du toolbox épinglé en dur (chai 4.5.0) ; **511 passing / 0 failing** (chaque fichier échouait avant)
- Emprunt à exactement LTV : plus atteignable d'un wei d'arrondi (voulu, protocole-favorable, documenté)
- Suites : forge 268/268, hardhat racine 511/511, tokens/ 189/189

## 2026-07-30 — 2e passe — Re-scans 15+16 traités (125d794)

- Re-scans Dominique post-remédiation : les 27 fixes tiennent, aucun ne réapparaît
- Corrigé la RÉGRESSION CRITICAL de ma réécriture lending : initReserve ré-initialisable après setReserveActive(false) → garde sur supplyIndex==0
- Lending aussi : arrondi liquidation (saisie sans burn de dette), whenNotPaused sur liquidate, modes flash-loan rejetés
- Bridge : bridgeLiquidity créditée à l'envoi (divergence compteur/balance), delta mesuré addBridgeLiquidity, endpointId==localEid, reset fenêtre au ré-armement
- Modules : validation de paire anti-spoof (getPair canonique), prédicats routage CREATE_LP unifiés, MAX_BATCH=50, sync pauseGuardian ×3, feeVault contrat
- Cronos : MAX_INTENT_TTL 30j + cancelIntent creator, typehash compile-time (valeur inchangée)
- 3 findings RÉFUTÉS avec preuve : F-5 (registerByTokenOwner est permissionless), F-10 (borrowIndex≥1e18 rend la troncature inatteignable), F-13 (EndpointV2 rembourse déjà le surplus — vérifié dans les sources LZ)
- Suites : forge 262/262, tokens/ hardhat 189/189
- Décisions design en attente : frais BURN_LP (F-7), ré-ancrage oracle après grand mouvement (F-9), plancher DVN du bridge OApp (F-14), politique fee-on-transfer Bundler/LP (F-18), GUID dans IModule.Context (F-22/31), caps entrants bridge (F-20), bornage allReserves (F-27)

## 2026-07-30 — Remédiation audit 13+14 : 27 findings de code corrigés, branche security/audit-13-remediation

- Phase 1 (04e586a) : 15 findings rapport 13 hors lending (DVN re-check à chaque execute, payInLzToken rejeté, validation createDLMMPool, allowances Bundler, nonReentrant rescueETH, pull-payment dust LPModule, clés de replay + msg.value modules, CEI ServiceFee, bounds+pagination CurveFactory, event registration) + 3 findings rapport 14 Cronos
- BREAKING Cronos : `CREATE_INTENT_TYPEHASH` changé (binding receiver/factory) → `lib/relayer/cronosRelayer.ts` à mettre à jour AVANT redéploiement
- Phase 2 (b357de1) : réécriture comptabilité MagnetaLending — parts canoniques (F-2), ltv≠threshold (F-3), availableCash interne (F-7), fee-on-transfer mesuré (F-8), skip oracle réserves vides (F-9), primes flash-loan comptabilisées (F-11), + F-18/19/22
- Bug attrapé en review du travail d'agent : flashLoan re-créditait la prime seule, pas le principal → fuite `amount-premium` du ledger à chaque flash-loan ; corrigé + test de conservation mutation-checké
- Suite complète : 170 (baseline) → 228 tests, 0 échec ; tokens/ hardhat 183/183
- Restent OUVERTS : F-1/F-5/F-6/F-12 (dérive de déploiement — seul un redeploy testnet depuis build épinglé les clôt) ; re-scan Sentinelleai à relancer (vérifier crédits OpenRouter d'abord)
- Harnais hardhat racine cassé (`Invalid Chai property`, pré-existant, tous fichiers) — hors périmètre, à réparer

## 2026-07-29 — 16:54 — Suite verte à nouveau, routeur Flare mort, garde pré-déploiement

- **`forge` ne construisait plus le repo** : Foundry résout un seul solc et les sources Uniswap vendorisées imposent 0.5.16/0.6.6. Remède : `--skip "contracts/imports/*" --skip "contracts/uniswap/*"`. PIÈGE : `/usr/bin/forge` est un binaire « ZOE » sans rapport qui sort avec le code 0 — utiliser `~/.foundry/bin/forge`
- **151→152 tests, 0 échec** (10 étaient rouges). `MagnetaProxy.t.sol` : le durcissement `ce701c6` avait ajouté les allowlists spender/target sans mettre à jour la fixture ; +3 tests couvrant la propriété réelle (spender quelconque non inscrit, pas seulement l'adresse zéro)
- `MagnetaPool.t.sol` : l'invariant n'avait **aucune cible déclarée**, le fuzzer usurpait l'adresse du pool pour appeler `TokenB.transfer` et sortir 2077 wei sans toucher aux réserves. `targetContract` + `targetSender` (sinon campagne verte sans rien exercer)
- **DÉFAUT PRODUCTION : `defaultRouter` de Flare n'a aucun code** (`0x0ECAA009…23e8`, vérifié on-chain avec USDC.e en contrôle positif). Les `LPModule` et `SwapModule` déployés le retournent tous deux depuis `router()`, qui est `immutable` → **LP et swap sur Flare échouent aujourd'hui**, seul un redéploiement corrige
- `deployAll` refuse désormais de déployer si une adresse de la config n'a pas de bytecode sur la chaîne cible (vérifié : Flare bloqué, Base passe) — la valeur devient un argument de constructeur permanent, pas un réglage corrigeable
- Bonne adresse Flare écrite : `UniswapV2Router02` `0x4a1E5A90…72a1e` (doc SparkDEX fournie par Dominique), vérifiée on-chain — code présent, `factory()` = le V2Factory de la doc, `WETH()` de symbole WFLR. **Ne corrige que les déploiements futurs**
- `_refundDust` : le volet token de REMOVE_LP remboursait le **solde entier** là où le volet natif est borné par `nativeBefore` ; borné par instantané, test validé en replantant l'ancienne ligne (échec `0 != 7e17`)
- Actions GitHub pinnées par SHA (4 repos)

## 2026-07-27 — 17:02 — Rescan Sentinelleai : F-1 (ma remédiation incomplète) + 20→0 Dependabot
- Rescan des 4 adaptateurs UniV2 (audit `2693bb55`) : le panel a trouvé que le correctif fee-on-transfer du matin n'avait été posé que sur les chemins liquidité, **pas sur les swaps** — `swapExactTokensForTokens`/`ForETH` pullaient encore `amountIn` brut (F-1 HIGH)
- `pullMeasured` étendu aux 5 points d'entrée des 4 adaptateurs ; plafonné à `amount` (F-4) contre les tokens réflexifs qui créditent en cours d'appel
- 2 tests ajoutés, chacun **vérifié en échec correctif retiré** (100e18≠95e18 ; 1100e18>1000e18) ; 49/49 invariants + 8 durcissement verts (`f401f9a`)
- Dependabot 20→0 en deux passes (`9e69a78`, `f1a93ef`) : tar 7.5.22 (critique patchée seulement en .19), axios, adm-zip, fast-uri, immutable, puis brace-expansion 1.x/2.x — nouveaux avis publiés **pendant** la session, contre les copies que le premier override laissait volontairement de côté
- adm-zip est sur le chemin de téléchargement de solc → vérifié en compile cache vidé, pas incrémental (124 fichiers, 511+171 tests)
- Constat : le rescan servait à valider le pipeline ; il a surtout relu du code neuf jamais relu — et y a trouvé un vrai trou

## 2026-07-22 — 14:16 — Chantier B TERMINÉ : cutover frontends + frais on-chain actifs 20/20
- Cutover Tokens (`765a9557`) + DEX (`4aa9365`) déployés prod → couche B (Gateway skim durci), smoke tests verts (bundles + on-chain owner=Safe + HTTP 200)
- Batches `scripts/safe/b-setopfeenative/` (20 chaînes) : setMax=50×U + 11 frais d'op (poids : LP create 2.5U, remove/burn/mint/claim 1U, admin 0.5U) — unités U identiques au chantier A
- Batches exécutés (16 Safe UI + 4 in-house execBatch) ; frais vérifiés on-chain 20/20 conformes
- Ops sans headroom frontend laissées à 0 (SWAP_*, CREATE_TOKEN, atomiques) — sinon revert
- Fix .env : SEI_MAINNET_RPC_URL dédupliqué → publicnode (drpc 500)
- Reste (indépendant) : CSP enforce, Dependabot (Tokens 9, DEX 15), gate /lending DEX, révocation secrets
- Suite même jour : CSP collector `/api/csp-report` + report-uri déployé (enforce après collecte) ; Dependabot Tokens 9/9 + DEX 15/15 corrigés (pins) ; /lending gaté Coming Soon ; purge clés bash_history local+VPS
- Vérif source explorers B : `scripts/deploy/verifyB.ts`, **19/20 chaînes / 152 contrats vérifiés** (Etherscan V2 + Blockscout flare ; katana/plasma/abstract basculés V2 dans hardhat.config) ; cronos = Cloudflare bloque l'API → vérif via UI si voulu

## 2026-07-23 — Cronos : vérif source complète → 20/20 chaînes
- API keyed Cronos Explorer (clé CRONOSCAN_API_KEY .env) : route réelle `/mainnet/api/v1/contract/verifySourceCode` **multipart** (contractAddress/name/compilerVersion/constructorArguments/compilerType/contract[]=@build-info-input)
- PIÈGE : leur backend échoue sur l'input standard-json complet (110 sources) → **élaguer au graphe d'imports** ; 7/8 Pass-Verified
- MagnetaFactory : build à part (runs=1 + revertStrings=strip, squeeze 24KB) que leur pipeline ne reproduit pas → vérifié via **Sourcify exact_match** (creation+runtime, chain 25)
- Bilan : source des contrats B publiquement vérifiée sur les 20 chaînes (155/155)
- **Listener VPS re-pointé sur la couche B** (155 champs deployments/ VPS ← deployments-b) — le monitoring/indexation frais suivait encore l'ancien set
- Remise en état listener (dégradé depuis des mois, préexistant) : RPC directs par chaîne (base=mainnet.base.org, polygon=quiknode, avax=officiel, bsc=rpc-bsc.48.club, sei=sei-apis, katana/cronos=officiels, plasma=plasma.drpc.org) — publicnode bloque les getLogs multi-adresses, drpc free les timeout, le proxy 4003 rejette les batches ethers (bug à fixer) ; checkpoints figés depuis mai avancés au tip (ère pré-B sans valeur) → 20/20 chaînes vertes, reste tip-race sei intermittente
- Recommandation : clé dRPC payante = fix durable sei + robustesse globale ; fix batch-400 du rpc-proxy à faire

## 2026-07-20 — Chantier A : MagnetaServiceFee déployé (20 chaînes)
- Runbook du redeploy native-fee : `docs/native-fee-redeploy-runbook-2026-07-20.md` (scope A léger vs B lourd Gateway-cascade)
- Découverte : le skim on-chain est DANS le Gateway (immuable, pas proxy) → chantier B = redeploy Gateway + cascade modules + pauser→Safe→cutover (différé, attend frontend Ch3 + rotation guardian)
- **Chantier A EXÉCUTÉ** : nouveau `scripts/deploy/deployServiceFee.ts`, MagnetaServiceFee déployé sur les **20 chaînes** (deployer 0x6206…7e25E financé par owner), vérifié on-chain 20/20 (code+feeVault+pendingOwner=Safe), frais OFF (opFee=0)
- 5 échecs RPC transitoires (drpc rate-limit) retentés avec RPC publics → 20/20 ; fix script : retry read-back pendingOwner (latence séquenceur Base)
- Batches accept Ownable2Step générés : `scripts/safe/servicefee-accept/` (14 sous 0xC4c9, 2 sous 0x4AeA, 4 sous 0x40ea) — RESTE : owner accepte via Safe, puis setOpFee par op + réconciliation Terminal/listener

## 2026-07-13 — Centralisation des contrats
- Mergé `feat/native-service-fee` + `fix/cronos-verify-config` → main, pushé
- Committé le backlog : sources AMM V2 (`uniswap/`, `imports/` — déployées mainnet, jamais versionnées), chain-service (CREATE_TOKEN, LP atomique, createLpFromUsdc, messaging tracker), archives vague Safe (batches → `Fait/`, gnosisSafe dans les 20 deployments)
- **Migration : `tokens/` = contrats du launcher** (depuis magneta-finance-tokens/contracts/solidity, avec les 7 dossiers deployments-*) ; package workspace pnpm ; 511 + 171 tests verts
- Nouveau `scripts/export-abis.mjs` (`pnpm export:abis`) : check de dérive ABI par défaut, 3/3 DRIFT attendu (sources durcies ≠ contrats déployés) ; `--write` réservé au cutover/redeploy
- Dependabot 141→0 : locks morts `tokens/` supprimés (2 critical), overrides tar/tough-cookie + OZ≥4.9.6 via alias LZ V1 ; 511+171 tests verts post-overrides ; request/web3-core-subscriptions (sans fix, chemins morts protocol-kit) dismiss motivés

## 2026-07-09 (transfert Safe de la vague TERMINÉ)
- **20/20 chaînes = 231 contrats de la vague sous multisig 2/2** ✅ (vérifié on-chain owner==Safe, tous)
- Accepts (step-2) : UI Safe pour ~10 chaînes ; **execBatch.ts** pour berachain/unichain + les 4 INH (flare/sei/abstract/cronos) car UI plante (Safe SDK/Tenderly/Safe Shield mal supportés sur chaînes récentes)
- Faux positifs UI rencontrés + tranchés on-chain : Tenderly "will fail" (berachain), GS013 = déjà accepté (bsc), Safe Shield "malicious address" = nos propres contrats non-vérifiés (unichain Pool/Swap/Lending)
- ⚠️ Clé guardian a transité sur la machine (execBatch sur 6 chaînes) → **rotation guardian + nettoyage bash_history recommandés** (les 2 signers du 2/2 étaient temporairement sur la même machine)
- Reste : (1) rotation clé guardian, (2) vérif source des contrats sur explorers (réduit faux positifs Safe Shield), (3) **cutover frontends** vers la vague durcie (le but de la décision A)

## 2026-07-08 (exécution transfert Safe de la vague)
- **Step-1 (transferOwnership EOA) exécuté sur les 20 chaînes** — pending=Safe sur les 2-step, BridgeOApp (1-step) transféré direct ; vérifié on-chain
- Accepts (step-2) faits par user : polygon, arbitrum, optimism = ✅ 12/12 owner=Safe ; 17 chaînes restent en attente d'accept (UI MAIN/LEGACY + execBatch INH)
- RPC galère : base (in-flight limit/521/timeout sur proxy/llama/publicnode/drpc → **1rpc.io** a fini), gnosis (lent, 3 runs publicnode+gnosischain), monad/cronos direct
- **⚠️ PIÈGE évité** : `0x4AeA` sur base = Safe DIFFÉRENT (deployer+Relayer, **1/2**), pas ton 2/2 ; base reste sous `0xC4c9` (vrai {deployer+guardian} 2/2). Cf mémoire infra_safe_multisig. Toujours getOwners/getThreshold avant transfert
- Reste : user finit les 17 accepts, puis vérif finale owner==Safe, puis cutover frontends

## 2026-07-07 — bis (prépa transfert Safe de la vague)
- Découverte : DEUX écosystèmes distincts — set LIVE (gatewayChains.ts, Tokens+DEX) **déjà Safe-owned** (LEGACY/MAIN/INH), et la vague `deployments/*.json` (EOA, issue de la couche audit-grade Sentinelleai) **non-cutover**. Décision user = **A** (basculer les frontends sur la vague durcie). Cf mémoire project_two_contract_ecosystems
- Correction : mon 1er audit "0/20 transféré" ne concernait QUE la vague ; le live EST sécurisé Safe
- Carte Safe dérivée de la vérité terrain (owner des contrats live) + vérifiée : LEGACY/MAIN/INH tous 2/2 avec code ; monad MAIN OK (proxy gas-quirk, lu via rpc.monad.xyz)
- Prépa (rien d'irréversible exécuté) : `gnosisSafe` peuplé dans les 20 deployments/*.json ; `transferOwnership.ts` corrigé (+MagnetaCurveFactory, manquait) ; DRY_RUN OK 3 groupes (BridgeOApp=Ownable 1-step, reste 2-step) ; 20 batches `scripts/safe/wave-accept/<chain>-accept-batch.json` (211 acceptOwnership, cronos re-généré via proxy car direct RPC choke)
- Reste : exécution transferOwnership (EOA) + accept batches (Safe) par chaîne, un par un + vérif — en attente go user

## 2026-07-07
- Audit on-chain pré-Safe (20 chaînes × 12 contrats, lu 3×: moi + 4 agents Sonnet + RPC public tiers) : **ownership 100% deployer EOA, 0 transféré au Safe, aucun pendingOwner** — le vrai transfert Safe reste entièrement à faire (les "Safe" passés = batches addPauser Gateway/Swap)
- Constat : guardian pauser câblé seulement sur Gateway+Swap (deployAll/configureOnly n'ajoutaient que ces 2) → trou sur Pool/Lending/Factory/Bundler/BridgeOApp sur les 20 chaînes
- Nouveau `scripts/deploy/wirePauserGap.ts` (idempotent, préflight owner==signer, DRY_RUN, retry nonce) : addPauser(guardian) sur les 5 contrats manquants, via deployer EOA AVANT transfert Safe (sinon = batch multisig)
- Exécuté : **20/20 chaînes complètes** (guardian pauser sur tous les pausables présents : Pool/Lending/Factory/Bundler/BridgeOApp + Gateway/Swap préexistants), vérifié on-chain indépendamment ; berachain = 4 cibles (pas de Bundler)
- cronos manquait de gas → `scripts/deploy/topUpCronosViaLifi.ts` : bridge 5 POL→6,35 CRO via LI.FI (Relay, ~6s), puis re-run idempotent = 5/5 ✓
- Notes RPC : monad/cronos via RPC direct (proxy = gas-limit quirk) ; base throttle "in-flight delegated" → proxy ; bsc/ava/gnosis/celo default RPC échouait getSigners → proxy
- Prochaine étape : scripts/batches transfert ownership deployer→Safe (transferOwnership.ts existe) — le vrai transfert Safe reste 0/20 à faire

## 2026-07-05
- Durcissement staking/ (MasterChef, StakingRewards, StakingFactory) : Ownable→Ownable2Step + Pausable multi-pauser (pattern MagnetaFactory), whenNotPaused sur entrées seulement (deposit/stake/createStakingPool), sorties jamais bloquées
- 45 tests staking créés (0 avant) : 42+3 fichiers, pause/rôles/2-step ; suite complète 410 verts, zéro régression
- Re-scan custody repo entier : aucun autre trou pause/custody ; reste = 4 adapters sans tests (smoke), MagnetaProxy sans kill-switch (defense-in-depth), vérifier décommission XChainLpReceiver gnosis
- Note ops : pools créés par StakingFactory naissent sans pauser protocole (owner=créateur, addPauser opt-in)
- Non committé (branche security/pause-hardening, working tree) → committé/poussé en fin de session (`2aeb16c`)
- 4 points résiduels traités : smoke tests 4 adapters (80 tests + 2 mocks, zéro bug trouvé), pause defense-in-depth MagnetaProxy (executeSwap*, rescue non gaté, 8 tests), doc ops `docs/staking-pauser-ops.md`, deps Dependabot (11 overrides pnpm =X.Y.Z, vitest 1→3 chain-service) ; suite 498 verts
- ⚠️ Gnosis XChainLpReceiver PAS décommissionné : 0.218 xDAI toujours dedans, batch rescueNative à exécuter côté Safe

## 2026-06-30 — F112 MagnetaSwap fee-on-transfer fix

- `MagnetaSwap.swap()` mesure désormais `received = balanceAfter - balanceBefore` autour du `safeTransferFrom` ; fee + `amountToSwap` calculés sur `received` (plus sur `amountIn` nominal) → un tokenIn fee-on-transfer ne fait plus approve/forward plus que le router ne détient. Guard `received > 0`. Non-FOT path inchangé (`received == amountIn`)
- Vérifié via solc 0.8.20 isolé (flatten + native compiler) : OK. Suite Hardhat globale non lançable (erreurs préexistantes MagnetaCurvePool.sol / LPModule.sol sur cette branche multi-session)

## 2026-05-30 — V1.1 LPModule V2-direct + LPSourceWrapper + keeper bot opérationnel

- **LPModule V1.1** patché : `_createLPFromBridgedUsdc` route dest swap via V2 router direct (USDC→WNATIVE 1-hop puis USDC→WNATIVE→token 2-hop), bypass MagnetaSwap pour cross-chain. Magneta-first reste valide pour Token Manage swaps locaux (commit `a75fe17`)
- LPModule redéployé Polygon `0x42233fDC…189b` + Base `0x43FDA452…96f6` ; `setModule(0..3)` × 2 chains via `redeployLPModule.ts` (commit `a56dbd0`)
- **LPSourceWrapper** : nouveau contrat 200 lignes pour cross-chain LP en 1 tx native-only — swap native→USDC via V2, patch `usdcTotal` in-place, forward à Gateway.sendFanOutValueOp, refund l'excédent. Bug critique trouvé/fixé : offset assembly à 1+32 au lieu de 32 (le SDK prepend un opByte). 2/2 tests. Déployé Polygon `0x0A0D2fBe…e745` + Base `0xFf08089D…2f3E` (commits `42bd0e3`, `677ea37`)
- **Scripts** : `redeployLPModule.ts`, `deployLPSourceWrapper.ts`, `clearAndRescueValueOp.ts` (escape hatch pour pendingValueOps coincés)
- **Full CCTP loop validé** : Polygon→Base `0xaf583037…` dispatch → keeper bot autonomement fulfill (`0x4fd0bebf…`). Pipeline contracts end-to-end opérationnel sans intervention humaine.

## 2026-05-28 — patches MG-6 + MG-7, 3 redéploys Polygon+Base, blocage MagnetaPool

- **MG-6 patch** `MagnetaGateway._payNative` override : `msg.value == _nativeFee` (strict) → `>=` ; fan-out multi-dest était structurellement broken (chaque itération comparait `msg.value` au fee d'UN leg) ; 4 nouveaux tests
- **MG-7 patch** `_lzReceive` substitue `address(usdc)` local au `bridgedToken` du payload source-chain (CCTP V1 mint l'USDC LOCAL sur dest, pas le contrat source) + ajout `adminClearPendingValueOp` owner escape ; 3 nouveaux tests (296/297 passing, 1 préexistant flaky pair-address)
- Workflow découvert : modules `address public immutable gateway` → chaque patch Gateway impose redéploy de LP/Swap/TaxClaim/TokenOps + re-`setModule`×13 + re-`setUsdc` + re-`setPauseGuardian` + re-`setCctp` + re-`setEidCctpDomainBatch` + re-`setPeer`
- Stack v3 live Polygon+Base : Polygon Gateway `0x7fd77D02…850cf`, Base `0x05b853e7…cebe9` ; CCTP+LZ peer mesh bidirectionnel
- Polygon→Base CCTP validé end-to-end : burn + Iris attestation + LZ delivery + `fulfillValueOp` atteint ; revert final dans `MagnetaSwap.swap` "no corresponding pool found" → MagnetaPool registry non bootstrappé sur Base (bootstrap par chaîne × token non scalable pour un token launcher)
- **Décision V1.1** : LPModule cross-chain dest passera à V2 router direct + `ISwapProvider` abstraction (V2/LiFi/Jupiter/…) pour port non-EVM facile ; LPSourceWrapper fera native→USDC source-side en 1 tx
- 8 commits poussés sur `origin/main` (`f42fae7` interfaces manquantes → `0419bd0` clear/rescue) ; 6 nouveaux scripts hardhat (`redeployGatewayStack`, `resumeGatewayWiring`, `wireGatewayPair`, `claimAndFulfillCctp`, `clearAndRescueValueOp`, `whitelistMagnetaSwapTokens`) ; 2 Safe batches MagnetaSwap whitelist exécutés

## 2026-05-27

- Scan Sentinelle `MagnetaXChainLpReceiver` (CAUTION 52) trié + corrigé : SC02 cap sortie routeur `min(delta, amounts[last])`, guard `setKeeper` zero-addr, doc nonce/keeper ; 290 tests OK (commit `c02564c`)
- Ajout chemin relayer/intent : `fulfillSigned` (EIP-712 LpIntent, onlyKeeper, replay-guard digest) + keeper ; 32 tests receiver
- Receiver redéployé Gnosis (build durci) `0xeca6092…` ; batch Safe `acceptOwnership` + `setKeeper(0x2B89…)` exécuté + keeper financé 1 xDAI
- **PARQUÉ** : modèle receiver/keeper prouvé inalimentable sur routes non-CCTP (bridges livrent à l'EOA, pas au contrat) — pivot côté Tokens vers bridge→wallet + LP sur destination
- Commits contracts locaux (`c02564c`/`b2b9578`/`66d5c8b`) — **push en attente** (remote HTTPS, creds requises)

## 2026-05-25

- Ajout `MagnetaXChainLpReceiver.sol` (core) — receiver permissionless pour LP cross-chain via LI.FI (chaînes non-CCTP)
- Native-only input : swap moitié → token, puis addLiquidityETH ; non-custodial, donation-safe, Ownable2Step + ReentrancyGuard
- Mock configurable `MockLpReceiverRouter.sol` + 22 tests (dust refund, donation safety, slippage) ; suite full 273 passing
- Slither : findings bénins seulement (unused swap return intentionnel, event-after-call rescue owner, low-level native calls)
- `deployXChainLpReceiver.ts` prêt (lit router + WETH on-chain, transfer owner = proxy existant) — attend scan Sentinelle + wiring frontend avant deploy
- Scan receiver CAUTION 72/100 → fix MEDIUM : floor explicite `tokenReceived < minTokenOut` + MockFeeToken (23 tests) — `72db0b2`
- Triage 6 scans (Gateway/Pool/Swap/V2Router02/V2Library + Bundler) — détail dans memory + ci-dessous
- Gateway FAIL 28/100 : CRITICAL `_lzReceive` = FAUX POSITIF (OAppReceiver.lzReceive enforce déjà OnlyPeer, vérifié dans node_modules LZ 3.0.168) → garde defense-in-depth ajoutée + rescueETH CEI + doc fulfillValueOp — `e35f0d8`
- Pool : check zero-address `createPool` (SC01 MEDIUM) — `e35f0d8`
- V2Router02 + V2Library HIGH = propriétés canoniques UniswapV2 (balanceOf stateless-router / getAmountsOut spot-price) → AUCUN changement (ne pas toucher au code AMM audité)
- ⚠️ PDF Bundler = doublon mal-nommé du rapport Gateway (audit ID a8b7fccd) → re-scanné depuis
- Bundler re-scanné CAUTION 42/100 → full hardening (`608b577`) : router timelock 24h (propose/apply/cancel), disperseEther skip-and-log + pull-payment fallback (withdraw + pendingWithdrawals), rescueETH borné, deadline user partout, per-leg amountOutMins[]/minTokensPerBuy[]
- Bundler = ABI CHANGE → frontend à mettre à jour AU MOMENT du redeploy (pas avant) ; ~10 call sites (BundledBuy/Sell, SellBundledBuy, AntiMEVVolumeBot, Dex*, orchestrator bots) + lib/abis/MagnetaBundler.json
- Swap MEDIUM getAmountOut caller-relative = imprécision bornée à 0.3% (fee), 0 pour user normal → skip / V1.1
- Suite full 281 passing ; commits locaux sur main (pas push)

## 2026-05-07

- Magneta AMM live sur Base (router `0xc1a6e0Ad…bccb`) et Arbitrum (`0xfC232723…3D8d`) — gas total $0.45
- Curve graduations re-câblées vers Magneta AMM sur Polygon + Base + Arb via `setCurveRouterToMagnetaAMM.ts`
- Nouveau script `scripts/util/setCurveRouterToMagnetaAMM.ts` : auto-detect EOA vs Safe owner, génère batch Safe si needed

## 2026-04-26

- **Migration rétroactive Flare + Sei** : 22 contrats transférés de l'EOA deployer vers Safe in-house `0x40ea...b297`. Safe déployé sur les 2 chaînes (gas ~$0.001 chacune), transferOwnership 11/11 sur chaque, batches `flare-acceptOwnership-batch.json` + `sei-acceptOwnership-batch.json` (5 tx Ownable2Step chacune) exécutés via `execBatch.ts`
- Sei RPC : `evm-rpc.sei-apis.com` rate-limited et flaky — switch vers `https://sei-evm-rpc.publicnode.com` via `SEI_MAINNET_RPC_URL` env. execBatch.ts amélioré avec retry x3 + backoff 2s sur les lectures Safe
- **Résultat global** : 212 contrats / 20 chaînes mainnet, 100% sous Safe multisig 2/2 (177 sous Safe Wallet UI `0xC4c9...717a` + 35 sous Safe in-house `0x40ea...b297`). Plus aucune EOA owner.
- Déploiement minimal Core+Gateway **8/11 contrats Magneta sur Abstract mainnet** (chainId 2741, zkSync stack) — LZ V2 endpoint Abstract custom `0x5c6c...4AE7` EID 30324, USDC.e Stargate `0x84A71c...87e1` whitelisté, pas de DEX V2 strict (Reservoir/Moonshot/Kuru = orderbook ou specialized) → LPModule/SwapModule/TaxClaimModule skipped, gas $2
- 2e chaîne avec **Safe in-house** `0x40ea2908Ea490d58E62D1Fd3364464D8A857b297` (gas 447k = $0.07)
- transferOwnership 8/8 OK, batch `abstract-acceptOwnership-batch.json` créé (5 tx Ownable2Step) — exécution via `execBatch.ts`
- Déploiement Magneta Core minimal sur **Cronos mainnet** (chainId 25) — 5/11 contrats : MagnetaPool/Swap/Lending/Factory/Bundler. LZ V2 PAS déployé sur Cronos par LayerZero team → Gateway/Bridge/Modules skipped (laissés à `lzEndpoint: null`). VVS Finance V2 router `0x145863Eb...2Ae` natif (pas d'adapter), USDC.e Crypto.com bridge `0xc21223...0c59` whitelisté, gas total 5.32 CRO ~$0.53
- **1ère chaîne avec Safe in-house** : address `0x40ea2908Ea490d58E62D1Fd3364464D8A857b297` (différente de l'UI canonical `0xC4c9...717a`), déployée via SafeProxyFactory.createProxyWithNonce(saltNonce=0) directement, gas 282k (~$0.011)
- transferOwnership Cronos : 5/5 OK (6 contrats SAFE_DIRECT skip not-deployed)
- batch `cronos-acceptOwnership-batch.json` créé (4 tx Ownable2Step) — exécution via `scripts/safe/inhouse/execBatch.ts` (pas de Safe Wallet UI sur Cronos)
- Phase 1 Safe in-house : créé `scripts/safe/inhouse/` avec 4 scripts (predict/create/exec/deploySafeInfra) + lib helpers + README
- Address Safe in-house déterministe : `0x40ea2908Ea490d58E62D1Fd3364464D8A857b297` (saltNonce=0, SafeL2 v1.4.1, mêmes owners/threshold)
- Vérifié : 5/6 chaînes cibles (Cronos/Abstract/Rootstock/Flare/Sei) ont déjà la canonical Safe infra ; seul Dexalot manque tout
- Address différente du Safe UI `0xC4c9...717a` (Safe Wallet utilise saltNonce timestamp irrécupérable) — sécurité équivalente
- Test fonctionnel sur Cronos OK : check infra ✓, predict ✓, gas estimate ~0.14 CRO (~$0.014)
- Déploiement minimal **8/11 contrats Magneta sur Berachain mainnet** (chainId 80094) — pas de DEX UniV2-strict (BEX=Balancer V2 fork, Kodiak=V3, Ooga Booga=aggregator off-chain). LPModule/SwapModule/TaxClaimModule skipped. USDC.e Stargate `0x549943...3241` whitelisté, EID 30362 Cluster B, gas négligeable
- transferOwnership Berachain : 8/8 OK (3 contrats SAFE_DIRECT skip — not deployed gracefully). batch `berachain-acceptOwnership-batch.json` créé (5 tx Ownable2Step)
- chainConfig.ts Berachain : `defaultRouter: null` + `router: null` (auparavant USDC sans verify, router V2 incertain)
- Migration future possible via `setDefaultRouter` Safe quand un V2 adapter existe
- Déploiement 11 contrats Magneta sur **Linea mainnet** (chainId 59144) — PancakeSwap V2 natif (router `0x8cFe327C...3a2Eb`, factory `0x02a84c1b...749e`, WETH bridged), Circle USDC `0x176211...e1ff` + CCTP V2 domain 11, gas total 0.0011 ETH (~$3.85), 15e chaîne mainnet
- Décision : abandonner SyncSwap (custom pool-per-path, pas V2-router-compat) au profit de Pancake V2 — TVL plus faible mais plug-and-play, migration future possible via `setDefaultRouter` du Safe
- chainConfig.ts Linea : `defaultRouter` + `router: "uniV2"` (auparavant null)
- transferOwnership + linea-acceptOwnership-batch.json + linea-whitelistTokens-batch.json créés
- Préparation déploiement **Cronos mainnet** (chainId 25) — remplace HyperEVM dans la liste cible
- Ajout `cronos` dans `hardhat.config.ts` (RPC `https://evm.cronos.org`, custom Etherscan V2 chain pour Cronoscan)
- Ajout entrée Cronos dans `scripts/deploy/chainConfig.ts` — USDC.e `0xc21223249CA28397B4B6541dfFaEcC539BfF0c59`, VVS Router `0x145863Eb42Cf62847A6Ca784e6416C1682b1b2Ae`, LZ EID 30040, CCTP null
- À faire avant `deployAll.ts --network cronos` : vérifier USDC `symbol()`, VVS code on-chain, EID via metadata.layerzero-api.com, fund deployer ≥5 CRO

## 2026-04-25

- Déploiement 11 contrats Magneta sur **BSC mainnet** (chainId 56) — PancakeSwap V2 natif (no adapter), Wormhole USDC 6-decimals (`0xB04906e9...c2b3`), gas total 0.00135 BNB (~$0.92), 14e chaîne mainnet
- Création `scripts/safe/bsc-acceptOwnership-batch.json` (5 tx pour Safe `0xC4c9...717a`)
- Ajout entrée BSC dans `scripts/deploy/chainConfig.ts` — preflight passé OK
- Fix : Binance-Peg USDC sur BSC a 18 decimals (BEP-20), incompatible avec assumption 6-decimals des modules → switch vers Wormhole USDC
- Déploiement 11 contrats Magneta sur Monad mainnet (chainId 143), transferOwnership → Safe Monad `0xC4c9...717a`
- Uniswap V2 Router02 officiel sur Monad (`0x4b2a...6804`, Factory `0x182a...0f59`, WMON `0x3bd3...433A`) — pas d'adapter (UniV2-compat natif), même pattern que Unichain
- USDC Circle natif Monad (`0x7547...b603`) whitelisté sur MagnetaSwap + Gateway, CCTP non encore live sur Monad (laissé null)
- LayerZero V2 Cluster B endpoint `0x6F47...8DD5B`, EID 30390 (même cluster que Unichain/Sonic/Berachain/Katana/Plasma)
- Gas Monad : 2.78 MON pour 11 contrats + config (un seul shot, aucun retry — 102 gwei stable)
- Étape transferOwnership : 11/11 txs OK (5 Ownable2Step + 6 Ownable), batch Safe Tx Builder `monad-acceptOwnership-batch.json` signé + exécuté → **143/143 contrats mainnet sous Safe** (Arb+Pol+Base+Sonic+Mantle+Celo+Plasma+Unichain+Katana+OP+Avalanche+Gnosis+Monad)
- Reserve Balance Monad : Monad impose **10 MON de réserve obligatoire** par EOA (mécanisme consensus/execution lag, k blocs). Tout value transfer qui ferait descendre le solde sous 10 MON est rejeté (sauf "emptying exception" si EOA inactive). Pour 2/2 Safe : signatures off-chain (gratuites), submission on-chain par 1 seul signer (qui doit avoir >0 MON). Workaround documenté pour les futurs deploys
- Hardhat config : Etherscan V2 supporté pour chainId 143 (monadscan.com), même API key que les autres
- Total mainnet déployé : **165 contrats sur 15 chaînes** (132 sous Safe + Flare 11 + Sei 11 + Monad 11 = 132 sous Safe + 33 EOA temporaire ; après accept, 143/143 sous Safe sauf Flare/Sei)
- Déploiement 11 contrats Magneta sur Sei mainnet (chainId 1329), pattern Flare-style : owner = deployer EOA (Safe officiel non supporté sur Sei via app.safe.global)
- Nouveau `DragonSwapSeiAdapter.sol` déployé sur Sei (`0xb73a41A378Ca508256326B026aC6283a64e177E8`) : facade UniV2 au-dessus de DragonSwap V1 (WETH→WSEI, addLiquidityETH→addLiquiditySEI, swapExactETHForTokens→swapExactSEIForTokens, swapExactTokensForETH→swapExactTokensForSEI)
- DragonSwap V1 Router brut (`0x11DA6463...c7428`) utilise naming SEI — même pattern que Mantle (Moe Native), Celo (Ubeswap CELO-as-ERC20), Avalanche (TraderJoe AVAX)
- USDC Circle natif Sei (`0xe15fC38F...42392`) whitelisté dans MagnetaSwap + Gateway (migration depuis l'ancienne USDC.n Noble bridged en mars 2026)
- LayerZero V2 Standard endpoint utilisé, EID 30280
- Gas Sei : **55 gwei** (très au-dessus des estimations initiales) — 1.6 SEI total dépensé pour adapter + 11 contrats + config (avec 4 contrats orphelins de retries dus aux rate limits RPC public)
- Crash phase deploy sur TokenOpsModule (rate limit `eth_estimateGas` busy) → résume via `deploySeiTokenOps.ts` (11e contrat + checkpoint manuel) puis `configureOnly.ts` (idempotent, 18/18 txs OK)
- Total mainnet déployé : **154 contrats sur 14 chaînes** (132 sous Safe + 22 sous EOA temporaire = Flare 11 + Sei 11)

## 2026-04-24

- Déploiement 11 contrats Magneta sur Gnosis mainnet (chainId 100), transferOwnership → Safe Gnosis `0xC4c9...717a`
- Swapr V2 Router natif utilisé (`0xE43e...c0C0`, Factory `0x5D48...2179`, WETH=WXDAI `0xe91D...97d`) — UniV2-compat direct, pas d'adapter (Swapr garde le naming `WETH()`+`addLiquidityETH`)
- USDC Gnosis bridge (`0xDDAf...7A83`, "USD//C on xDai") whitelisté — pas de CCTP (Gnosis hors Circle CCTP)
- Gas Gnosis : **0.00000049 xDAI** (~$0.0000005) pour 11 contrats + config — la chaîne la moins chère de tout le déploiement, record absolu
- Batch Safe Tx Builder `gnosis-acceptOwnership-batch.json` signé + exécuté → **132/132 contrats mainnet sous Safe** (Arb+Pol+Base+Sonic+Mantle+Celo+Plasma+Unichain+Katana+OP+Avalanche+Gnosis)
- Déploiement 11 contrats Magneta sur Avalanche mainnet (chainId 43114), transferOwnership → Safe AVAX `0xC4c9...717a`
- Nouveau `TraderJoeAvaxAdapter.sol` déployé sur Avalanche (`0xF4A2...315c`) : facade UniV2 au-dessus de TraderJoe V1 (WETH→WAVAX, addLiquidityETH→addLiquidityAVAX, etc.)
- TraderJoe V1 Router brut (`0x60aE...33d4`) utilise naming AVAX (pas ETH) — même pattern que Merchant Moe (Native) sur Mantle et Ubeswap (CELO-as-ERC20) sur Celo
- USDC Circle natif Avalanche (`0xB97E...a6E`) whitelisté, CCTP domain 1
- Gas Avalanche : 0.000679 AVAX (~$0.025) pour 11 contrats + config; adapter 0.004 AVAX supplémentaire
- Batch Safe Tx Builder `avalanche-acceptOwnership-batch.json` signé + exécuté → **121/121 contrats mainnet sous Safe** (Arb+Pol+Base+Sonic+Mantle+Celo+Plasma+Unichain+Katana+OP+Avalanche)
- HyperEVM **reporté** : diagnostic 2026-04-24 révèle que `docs.hyperswap.pro` est très probablement un site de phishing (adresses Factory/Router sont des EOAs vides on-chain). Infrastructure HyperEVM (Safe, LayerZero, USDC, WHYPE, CCTP) toutes validées mais DEX V2 légitime non identifié — à ré-évaluer via DefiLlama + GitHub officiels
- Sweep 0.00238 ETH d'un wallet compromis (`0xc7c8...821e`) vers deployer OP via `cast send` (env var `/tmp/opsweep.key`, shred après) — bypass MetaMask qui rejetait les txs
- Déploiement 11 contrats Magneta sur Optimism mainnet (chainId 10), transferOwnership → Safe OP `0xC4c9...717a`
- Chain config OP mise à jour : Velodrome (`solidly`) → SushiSwap V2 (`uniV2`, router `0x2ABf...25b1`)
- Gas OP : **0.0000044 ETH** (~$0.017) pour les 11 contrats + phase config complète — la chaîne la moins chère de notre déploiement
- Batch Safe Tx Builder `optimism-acceptOwnership-batch.json` signé + exécuté → **110/110 contrats mainnet sous Safe** (Arb+Pol+Base+Sonic+Mantle+Celo+Plasma+Unichain+Katana+OP)
- Déploiement 11 contrats Magneta sur Katana mainnet (chainId 747474, ZK rollup OP-stack) : Pool `0xDe17...`, Swap `0x9F9A...`, Lending `0xB38e...`, Factory `0x1348...`, Bundler `0x3cA7...`, Gateway `0x4D4A...`, Bridge `0x252B...`
- SushiSwap V2 Router natif utilisé (`0x69cC...B68E`, Factory `0x72D1...6Acd9`, WETH `0xEE7D...7aB62`) — vbUSDC whitelisté comme USDC Gateway
- Gas Katana : ~3× Unichain (proofs ZK + DA L1) — 2 attempts OOM avant top-up à 0.0011 ETH, 9 contrats orphelins cumulés (~0.00043 ETH soit ~$1.70)
- Crash RPC "nonce too low" sur phase config → résumé via `configureOnly.ts` (skip-if-already-set, 13/13 modules OK)
- Batch Safe Tx Builder `katana-acceptOwnership-batch.json` signé + exécuté → **99/99 contrats mainnet sous Safe** (Arb+Pol+Base+Sonic+Mantle+Celo+Plasma+Unichain+Katana)
- Déploiement 11 contrats Magneta sur Unichain mainnet (chainId 130), transferOwnership → Safe Unichain `0xC4c9...717a`
- Uniswap V2 Router02 officiel sur Unichain (`0x284F...63FF`) — pas de fork nécessaire, USDC natif `0x078D...7AD6` whitelisté
- Batch Safe Tx Builder `unichain-acceptOwnership-batch.json` signé + exécuté → **88/88 contrats mainnet sous Safe** (Arb+Pol+Base+Sonic+Mantle+Celo+Plasma+Unichain)
- Gas Unichain : 0.000047 ETH total
- Déploiement propre UniV2 fork sur Plasma (aucun DEX V2 audité sur la chaîne) : WXPL `0xF4A2...315c`, Factory `0xDc6B...C726`, `MagnetaV2Router02` `0xDa43...41B9`
- Config multi-pragma hardhat (0.5.16 + 0.6.6 + 0.8.20) + packages `@uniswap/v2-core` + `@uniswap/v2-periphery` en dev-deps; `MagnetaV2Library` avec init code hash patché `0xf407...95d2`
- Déploiement 11 contrats Magneta sur Plasma mainnet (chainId 9745), transferOwnership → Safe Plasma `0xC4c9...717a`
- USDT0 (`0xB8CE...5ebb`) whitelisté sur MagnetaSwap + défini comme USDC Gateway (pas d'USDC natif sur Plasma)
- Gas Plasma : 0.00017 XPL total pour 14 contrats (UniV2 + Magneta) — gas price 0.005 gwei
- Batch Safe Tx Builder `plasma-acceptOwnership-batch.json` signé + exécuté → 77/77 contrats mainnet sous Safe (owner() vérifié on-chain sur les 5 Ownable2Step)
- Nouveau `UbeswapCeloAdapter.sol` déployé sur Celo (`0xF4A2...315c`) : facade UniV2 au-dessus d'Ubeswap (Ubeswap n'a pas `WETH()`/`addLiquidityETH` car CELO est déjà un ERC20 au précompile `0x471EcE...78a438`)
- Déploiement 11 contrats sur Celo mainnet (chainId 42220), transferOwnership → Safe Celo `0xC4c9...717a`
- Gas Celo : 2.95 CELO (~$1.8) pour les 11 contrats + ~0.3 CELO pour l'adapter
- Batch Safe Tx Builder `celo-acceptOwnership-batch.json` prêt (5 contrats Ownable2Step)
- Fix modal Connect Wallet côté Tokens : EVM affiche maintenant MetaMask/Coinbase/Trust/Brave + WalletConnect avec liens d'install (aligné sur le pattern Solana/Aptos/etc)

## 2026-04-23

- Déploiement 11 contrats sur Mantle mainnet (chainId 5000), transferOwnership → Safe Mantle `0xC4c9...717a`
- Nouveau `MoeRouterAdapter.sol` déployé sur Mantle (`0xF4A2...315c`) : facade UniV2 au-dessus de Merchant Moe V1 (rename WETH→wNative, ETH→Native)
- Décision : V2-only pour le product core (auto-LP, LP token fongible) — V3 module reporté jusqu'à ≥3 chaînes V3-only
- Gas Mantle : 2.15 MNT (~$1.36), adapter inclus
- Batch Safe Tx Builder `mantle-acceptOwnership-batch.json` prêt
- Déploiement complet des 11 contrats sur Sonic mainnet (chainId 146), transferOwnership → Safe Sonic `0xC4c9...717a`
- Fix checksum + adresse router Shadow dans chainConfig (l'ancienne `0x5543C617...D318CE3` n'existe pas on-chain, typo)
- Shadow V2-compat router utilisé : `0x1D368773...B330CDc` (factory=0x2dA2...74c8, WETH=wS)
- Gas Sonic : 1.45 S dépensé (~$0.06) — 7 contrats zombies de la 1ère tentative (abort sur checksum error)
- Batch Safe Tx Builder `sonic-acceptOwnership-batch.json` prêt (5 contrats Ownable2Step)
- Déploiement complet des 11 contrats sur Base mainnet (chainId 8453), transferOwnership → Safe Base `0xC4c9...717a`
- Batch Safe Tx Builder `base-acceptOwnership-batch.json` prêt (5 contrats Ownable2Step)
- Confirmation : les 3 Safes (Arb/Pol/Base) ont les mêmes 2 signataires (deployer + PauseGuardian EOA)
- Déploiement complet des 11 contrats sur Flare mainnet (chainId 14), USDC.e Stargate `0xFbDa...d3b6` whitelisté
- Owner Flare = deployer EOA (migration vers Ledger cold-storage quand reçu)
- Safe non supporté par l'UI Safe sur Flare → décision : EOA cold temporairement
- Déploiement complet des 11 contrats sur Polygon mainnet (chainId 137)
- Transfer d'ownership des 22 contrats (11 Arbitrum + 11 Polygon) vers le Safe 2/2 `0x4AeA...EC2F`
- Patch `deployAll.ts` : checkpoint `deployments/<network>.json` avant phase config (résilient aux crash RPC)
- Nouveau script `configureOnly.ts` : résume idempotent de la config post-deploy + retry-on-nonce pour Polygon
- Nouveau script `transferOwnership.ts` Safe-direct (no Timelock), gère Ownable et Ownable2Step
- Safe Tx Builder batches JSON générés pour les 10 `acceptOwnership` (5 Arbitrum + 5 Polygon)

## 2026-04-22

- Création du journal (système de notes cross-sessions mis en place)
