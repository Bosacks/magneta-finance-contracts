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

## Ce que je ne peux pas trancher seul

- **X Based Token** : on l'ouvre, ou il reste verrouillé et on aligne le menu ?
- **XCommentExporter** : on déploie le backend X/Twitter, ou on le retire de
  Convenient Tools pour l'ouverture ?
- **Ordre** : commencer par la CurveFactory de Base seule pour valider la
  procédure, ou attaquer directement les vagues complètes chaîne par chaîne ?
