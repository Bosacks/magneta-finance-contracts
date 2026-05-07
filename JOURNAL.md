# Journal — magneta-finance-contracts

> Fil chronologique des sessions. Anti-chronologique (plus récent en haut).
> Voir `~/CLAUDE.md` pour la règle d'édition.

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
