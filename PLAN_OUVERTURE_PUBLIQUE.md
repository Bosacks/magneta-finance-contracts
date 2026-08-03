# Plan — ce qu'il reste avant d'ouvrir les sites au public

Établi le 2026-08-03. Le déploiement chaîne par chaîne est **en pause** : il ne
couvrait que cinq contrats sur les sept qui doivent changer, et le reprendre
tel quel aurait laissé le launchpad vulnérable sur dix-huit chaînes.

Tout ce qui suit a été vérifié on-chain ou dans le code le 2026-08-03, pas tiré
du journal. Les constats sont datés parce qu'ils périment.

---

## Le constat qui change le plan

La vague déploie `MagnetaGateway`, `LPModule`, `SwapModule`, `TaxClaimModule`,
`TokenOpsModule`. L'en-tête de `redeployGatewayWave.ts` le dit lui-même :

> `SEPARATE: MagnetaProxy (deployMagnetaProxy.ts), MagnetaCurveFactory (deployCurveLaunchpad.ts), configPeers.ts`

**La CurveFactory n'est touchée par aucune étape de la vague** — y compris sur
Base, pourtant terminée hier : sa factory ne porte toujours pas le correctif.
Terminer les vingt vagues n'aurait donc rien réglé pour le launchpad.

Puisqu'on s'arrête de toute façon, on visite chaque chaîne **une seule fois**
avec les sept contrats au lieu de cinq, plutôt que de repasser trois fois.

---

## Ce qui est cassé, et à quel point

| # | Point | Vérification | Gravité |
|---|-------|--------------|---------|
| 1 | Launchpad ouvert avec le CRITICAL de graduation | `flagPairOutOfBand` absent du bytecode de 8/8 factories sondées ; `paused()` reverte (factory non pausable) ; `getTokenCount() = 0` partout | **Bloquant.** Zéro exposition aujourd'hui — ouvrir la crée |
| 2 | 15 chaînes sur 16 en Gateway pré-remédiation | sélecteur `adminRefundPendingValueOp` absent ; seule Base l'a | **Bloquant** |
| 3 | Adaptateurs sans le correctif fee-on-transfer | `sweepNative` absent sur avalanche/celo/mantle/sei, qui sont les `defaultRouter` réels de ces chaînes | **Bloquant** : tous les jetons du launchpad sont taxés ⇒ ajout de liquidité en revert |
| 4 | `services/` hors Dependabot | dossier gitignoré ⇒ alertes aveugles ; le rpc-proxy y tourne et est exposé | Élevé |
| 5 | X Based Token | `ComingSoonOverlay` dans la page, mais l'entrée de menu n'est pas `comingSoon` | Cosmétique — l'utilisateur voit la vérité en arrivant |
| 6 | XCommentExporter (dans Convenient Tools) | commentaire explicite : « the backend Twitter/X comments API isn't deployed yet » | À trancher |
| 7 | `magneta-discord-bot` en boucle de redémarrage, `magneta-uptime-discord-bot` en échec | `systemctl` | Surveillance dégradée au pire moment |
| 8 | `certbot.service` en échec | certificats valides 63 j, renouvelés par **Caddy** | **Non-problème** — vestige de l'ère nginx, à supprimer |

### Ce qui va bien, et qu'il ne faut pas « corriger »
- **Le bridge du DEX fonctionne** (CCTP + LI.FI). L'indisponibilité de
  `MagnetaBridgeOApp` est une note interne sur le contrat. **Ne pas** marquer
  le menu Bridge en « Soon ».
- La clé déployeur fuitée dans l'historique du DEX dérive vers `0x7900F22d…`,
  qui n'est **pas** le déployeur en service, ne détient aucun rôle en mainnet
  et n'a que de la poussière. Risque éteint.
- Les bots (Market Making, Bundled) tournent **dans** l'app Next
  (`lib/orchestrator/bots/`), sans service externe. Rien à déployer côté infra.
- DLMM : pausé sur 20 chaînes, 0 pool. Non bloquant tant qu'il reste fermé.

---

## Phase 1 — Testsites : corriger et **prouver**

Rien ne part en mainnet sans être passé par là.

1. **CurveFactory corrigée** — bornes d'allocation, `flagPairOutOfBand` +
   `enterRefundMode` à deux temps, `nativeRaised = 0` avant `Graduated`,
   `peakNativeRaised`. Test qui compte : rejouer l'attaque du rapport 21
   (amorcer la paire avec de la poussière, `sync()`, attendre le délai, forcer
   la graduation) et **asserter des soldes**, pas un événement — c'est
   exactement ce que le test H-1 existant rate.
2. **Adaptateurs** avec `pullMeasured`, sur un jeton à taxe réel : l'ajout de
   liquidité doit passer, et la compta ne doit pas diverger.
3. **Un jeton de launchpad de bout en bout** : création → achats sur la
   courbe → graduation → LP brûlée. C'est le seul test qui prouve que la
   chaîne complète tient, taxes comprises.

## Phase 2 — Mainnet, une chaîne à la fois

Séquence par chaîne, en une seule visite (extension du `CHAIN_WAVE_RUNBOOK.md`) :

1. Relever le barème de frais sur **deux** RPC avant de toucher quoi que ce soit.
2. Déployer les 5 contrats de la vague **+ la CurveFactory + l'adaptateur** si
   la chaîne en a un à nous.
3. Vérifier **par sélecteur**, pas par « la transaction est passée ».
4. Reconduire les frais **une transaction à la fois** (les envoyer en boucle a
   collisionné sur les nonces et échoué à moitié en silence sur Base).
5. Transférer la propriété au Safe (Ownable2Step).
6. Autoriser le pauser du disjoncteur sur la **nouvelle** Gateway — un
   redéploiement retire ce filet sans le dire.
7. Régénérer la référence du disjoncteur et **relire le diff** : seule la
   chaîne traitée doit bouger sur `gateway`, `watched`, `modules`.
8. Repointer le site (`gatewayChains.ts` **et** `contracts.ts` pour la
   CurveFactory), déployer, vérifier que le bundle servi porte la nouvelle
   adresse et plus l'ancienne.

Coût : ~12M de gas par vague — **mesuré** (50 976 octets de bytecode, dépôt à
200 gas/octet = 10,2M avant tout constructeur), pas les 5,5M supposés. Ajouter
la CurveFactory augmentera ce chiffre : à re-mesurer avant de chiffrer.

Ordre proposé : Base d'abord (déjà à moitié faite, il n'y manque que la
CurveFactory et c'est un galop d'essai à faible enjeu), puis les chaînes à
gros volume, puis le reste.

## Phase 3 — Hors chaîne, en parallèle

- Mettre `services/` sous Dependabot, ou sortir le rpc-proxy dans un dépôt suivi.
- Réparer `magneta-discord-bot` et le heartbeat Uptime — la surveillance doit
  fonctionner **avant** l'arrivée des utilisateurs, pas après.
- Supprimer l'unité `certbot.service`.
- Trancher X Based Token et XCommentExporter (cf. questions ci-dessous).

---

## Les deux fonctions X — tranché le 2026-08-03

Décision : les deux restent derrière « Soon », mais doivent être **complètes et
vérifiées**, de sorte qu'il ne reste qu'à payer l'abonnement X pour les ouvrir.

**X Based Token — conforme.** `app/api/tweets/route.ts` est complet et soigné :
limitation de débit, validation des identifiants contre l'injection de grammaire
de requête, appel réel à `tweets/search/recent`, et un 503 explicite quand la
clé manque — il ne fabrique jamais de données. Il ne lui manque que
`TWITTER_BEARER_TOKEN`. Menu aligné sur la page (`comingSoon: true`, commit
0d2a6875) : la barre latérale annonçait une fonction que la page refusait.

**XCommentExporter — PAS conforme.** Trois manques indépendants de la clé :
1. il appelle un backend séparé jamais déployé
   (`NEXT_PUBLIC_API_URL || 'http://localhost:8080/api'`, route
   `/twitter/comments`) — à réécrire en route Next, comme `/api/tweets` ;
2. l'état `format` (csv/json/txt) n'est **jamais lu** par `handleExport` — le
   sélecteur ne fait rien ;
3. il n'exporte aucun fichier : il fait un `console.log` et affiche
   « Check Console ».

Payer l'abonnement ne le rendrait donc pas fonctionnel. C'est un vrai poste de
développement, à faire avant l'ouverture si on veut tenir la règle « il ne
reste qu'à payer ».

### ⚠️ Le montant de 100 $/mois est à revérifier
D'après les sources publiques (2026-08-03), le palier **Basic est passé de 100 $
à 200 $/mois en octobre 2024**, et les nouveaux comptes basculent par défaut sur
un modèle **à l'usage** (~0,001 $ la ressource lue). La recherche récente sur
7 jours — `GET /2/tweets/search/recent`, dont dépendent **les deux** fonctions —
reste incluse dans Basic. À confirmer dans la console développeur X avant de
budgéter : ce n'est pas une information que je peux garantir à jour.

## Ordre retenu

CurveFactory de **Base seule** d'abord : Base est déjà à moitié faite, il n'y
manque que ce contrat, et c'est un galop d'essai à faible enjeu pour valider la
procédure étendue avant de l'appliquer aux dix-huit autres chaînes.
