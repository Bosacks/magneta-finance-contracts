# Journal — magneta-finance-contracts

> Fil chronologique des sessions. Anti-chronologique (plus récent en haut).
> Voir `~/CLAUDE.md` pour la règle d'édition.

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
