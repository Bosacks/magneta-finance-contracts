# Sentinelle triage — 2026-06-29 (115 CRIT+HIGH findings vérifiés vs code réel)

**Totals:** {"DEFERRED": 40, "GOVERNANCE_MITIGATED": 21, "FALSE_POSITIVE": 22, "ALREADY_FIXED": 11, "REAL": 16}

_115 CRIT+HIGH du rapport (audit 037a2844, 253 findings notés au total) vérifiés un par un contre la source actuelle. 0 critique live sur contrat déployé-et-actif._

## 16 REAL (live) — backlog actionnable

- **MAGCronosToken.sol F113 [CRITICAL]** — Line 100 keys messageId on relayer-supplied `to`+`amount`, so the only on-chain replay guard (no source-proof verification exists) can be re-keyed for the same escrow event; a compromised/tricked relayer mints the same locked MAG more than once.
  - fix: Compute the dedup key only from immutable source identity: keccak256(abi.encode(sourceChainId, sourceBridgeAddress, sourceTxHash, logIndex)), excluding to/amount.
- **MAGCronosToken.sol F36 [CRITICAL]** — Line 113 `if (mintCapPerEpoch == 0) return;` makes the cap inert, and constructor line 79 accepts _mintCapPerEpoch=0 with no require>0; the relayer (an EOA by design, not the Safe) can mint unbounded via fabricated sourceTxHash/logIndex until the Safe sets a cap.
  - fix: Add `require(_mintCapPerEpoch > 0)` in the constructor and treat a zero cap as 'no minting' rather than uncapped (or default to a bounded cap).
- **MagnetaXChainLpReceiver F9 [CRITICAL]** — fulfillSigned binds intent.amountNative only to the signer (line 224 signer==intent.to) and checks only aggregate address(this).balance>=intent.amountNative (line 228); no per-deposit credit, so a signer can over-claim pooled native bridged by other users and mint LP to themselves, reverting victims with InsufficientBridgedNative.
  - fix: Add per-deposit accounting (depositId->amount credited on bridge arrival), include depositId in LP_INTENT_TYPEHASH, and consume only that credited deposit in fulfillSigned.
- **MagnetaBridgeOApp.sol F22 [CRITICAL]** — bridgeTokens encodes the source token address (line 239) and _lzReceive transfers that exact decoded address (lines 311,327) with no per-route canonical mapping; cross-chain address divergence releases wrong asset or locks funds.
  - fix: Add remoteToken[dstEid][localToken] mapping, encode the destination/canonical asset id in the payload, and translate+reject unmapped assets on receipt.
- **LPModule.sol F7 [CRITICAL]** — _createLP (L169-182) and _createLPAndBuy (L249-272) pull full p.tokenAmount and forward full p.ethAmount but never refund the router's leftover (router returns amountToken<=desired); no sweep/rescue exists (only the cross-chain path refunds, L356-361), so dust is permanently stranded in the module.
  - fix: After each addLiquidityETH on local paths, compute tokenDust=p.tokenAmount-amountToken and ethDust via pre/post native balance, safeTransfer/call them back to ctx.caller.
- **MagnetaSwap.sol F112 [HIGH]** — swap() uses nominal amountIn (L96/99/103) with no balanceBefore/after delta, so a fee-on-transfer tokenIn makes the router approve/forward more than it received (DoS or dust-funded shortfall) — genuine code gap, though gated by the owner-curated whitelist at L93.
  - fix: Measure actualReceived = balanceAfter - balanceBefore around safeTransferFrom and use it for fee/amountToSwap, or explicitly reject fee-on-transfer tokens.
- **LPModule.sol F52 [HIGH]** — Local paths forceApprove(router, p.tokenAmount) then router consumes only amountToken, leaving a non-zero standing allowance that is never reset to 0 (contrast cross-chain L351-352 which does reset); plus same dust-stranding as F7.
  - fix: Add IERC20(p.token).forceApprove(router,0) at the end of _createLP/_createLPAndBuy and the pair allowance in _removeLP, alongside the dust refund from F7.
- **LPModule.sol F53 [HIGH]** — _collectFee (L380-384) uses the caller-supplied p.usdcFee verbatim and returns early when amount==0 (L381); there is no on-chain derivation of fee=value*FEE_BPS, so a direct local-op caller can pass usdcFee=0 and evade the 0.15% markup.
  - fix: Derive expectedFee on-chain from the operation USD value and FEE_BPS and require(p.usdcFee>=expectedFee) for local (originChainId==block.chainid) ops.
- **MagnetaBridgeOApp.sol F92 [HIGH]** — Fee and amountAfterFee are computed from the nominal `amount` (lines 230-231) after safeTransferFrom (line 219), never from a balance delta, so fee-on-transfer/deflationary tokens make the bridge release more than it received.
  - fix: Record balanceOf before/after safeTransferFrom and compute fee/payload from the actual received delta (or hard allowlist standard tokens).
- **MagnetaBridgeOApp.sol F93 [HIGH]** — _lzReceive (lines 283-330) has no whenNotPaused/pause check while bridgeTokens does (line 191), so pausing cannot stop inbound liquidity drain from a forged/compromised peer.
  - fix: Add require(!paused) (or an inboundPaused flag) at the top of _lzReceive.
- **MagnetaCurveFactory.sol F80 [HIGH]** — createCurveToken validation (lines 197-201) enforces graduationThreshold >= minGraduationThreshold with no ceiling, so any permissionless creator can pass type(uint256).max for a never-graduating pool that still registers and emits CurveTokenCreated — contradicting the contract's own comment lines 67-68.
  - fix: Add owner-tunable maxGraduationThreshold (via timelocked setParameterBounds) and require(graduationThreshold <= maxGraduationThreshold) plus require(graduationThreshold > virtualNativeReserve) in createCurveToken.
- **MagnetaCurvePool F82 [HIGH]** — finalizeGraduation() lines 349-350 set amountTokenMin/amountETHMin=0 whenever !emptyPair and deposits at the external pair's spot ratio (lines 342-359) with no band vs the curve's terminal price; a pre-seeded/skewed pair lets an attacker arb the burned LP.
  - fix: Derive amountTokenMin/amountETHMin from the curve terminal price (nativeRaised/tokensSold) with a tight band and revert if the existing pair ratio deviates, instead of mins=0.
- **MagnetaCurvePool F83 [HIGH]** — Line 326 uses nativeForLp = address(this).balance while receive() (line 382) is open and unrestricted, so force-sent ETH inflates the migrated native and distorts the V2 launch price (breaks INV001).
  - fix: Use nativeRaised instead of address(this).balance for nativeForLp and reject/segregate unsolicited ETH in receive().
- **MagnetaCurvePool F84 [HIGH]** — Graduation gate (line 263) reads net nativeRaised which sell() decrements at line 285, so a well-capitalized holder can sell near the threshold to suppress graduation indefinitely.
  - fix: Track a monotonic totalNativeBought counter for the graduation check; keep net nativeRaised only for pricing.
- **ERC20Token.sol F107 [HIGH]** — pause() line 128 checks !revokeFreezeEnabled but blacklist() lines 149-155 has no such guard, so after enableRevokeFreeze() the owner can still freeze individual accounts, violating the advertised freeze-revocation immutability (INV-7).
  - fix: Add require(!revokeFreezeEnabled, "ERC20Token: Freezing has been revoked"); at the start of blacklist().
- **MagnetaGateway F38 [HIGH]** — fulfillValueOp line 273 requires available>=totalEarmarked (sum of ALL pending ops); one delayed/stuck CCTP transfer makes balanceOf(this) < totalEarmarked and blocks every other op whose funds already arrived — cross-op liveness coupling, attacker can inflate totalEarmarked with a large never-fulfilled op.
  - fix: Replace the global check with a per-op one that only requires this op's funds: track a separate available pool and require balanceOf(this) >= p.bridgedAmount (and decrement a reserved counter), allowing partial fulfillment when individual op funds have arrived.

## 40 DEFERRED — contrats non déployés (à corriger avant lancement des produits)

- **MagnetaLending.sol** (10): F13[CRITICAL], F14[CRITICAL], F17[CRITICAL], F18[CRITICAL], F19[CRITICAL], F20[CRITICAL], F75[HIGH], F77[HIGH], F88[HIGH], F91[HIGH]
- **MagnetaMultiPool.sol** (9): F28[CRITICAL], F29[CRITICAL], F31[CRITICAL], F32[CRITICAL], F33[CRITICAL], F106[HIGH], F109[HIGH], F110[HIGH], F111[HIGH]
- **MagnetaETFPool** (8): F3[CRITICAL], F4[CRITICAL], F5[CRITICAL], F55[HIGH], F56[HIGH], F57[HIGH], F58[HIGH], F59[HIGH]
- **MagnetaFarm.sol** (7): F26[CRITICAL], F27[CRITICAL], F96[HIGH], F97[HIGH], F98[HIGH], F99[HIGH], F102[HIGH]
- **MagnetaETF.sol** (2): F25[CRITICAL], F101[HIGH]
- **MagnetaStakingRewards.sol** (2): F103[HIGH], F104[HIGH]
- **MagnetaETFFactory.sol** (1): F15[HIGH]
- **MagnetaDLMM.sol** (1): F100[HIGH]

## Déploiement par contrat

- MagnetaLending.sol: deferred (REAL live=0) — MagnetaLending.sol carries an explicit "NOT FOR PRODUCTION / Do NOT deploy until V1.1 audit" header — it is V1.1+ scope and not deployed, so every genuine bug i
- MagnetaMultiPool.sol: deferred (REAL live=0) — MagnetaMultiPool is explicitly marked NOT FOR PRODUCTION (header lines 1-20), is V1.1+ scope, and is gated off behind MagnetaFactory.createMultiPool's liquidity
- MagnetaETFPool: deferred (REAL live=0) — MagnetaETFPool is explicitly BETA/"Coming Soon" (lines 24-26: do not use on mainnet until audit complete) and is not deployed. Every finding describes a genuine
- MagnetaFactory.sol: live (REAL live=0) — All scanner findings target a stale version. Current MagnetaFactory + child constructors (MagnetaDLMM, MagnetaMultiPool, MagnetaPool) already enforce every clai
- MagnetaFarm.sol: deferred (REAL live=0) — MagnetaFarm.sol carries an explicit "NOT FOR PRODUCTION / V1.1+ scope / do NOT register as Gateway target" header — it is undeployed staking code. Findings spli
- MagnetaSwap.sol: live (REAL live=1) — MagnetaSwap is a thin, stateless fee-router over the immutable in-house MagnetaPool: it holds no liquidity, has no tokenReserves/deposit/withdrawLiquidity. F1 i
- LPModule.sol: live (REAL live=3) — LPModule is live (local LP ops on ~20 mainnets). The cross-chain path _createLPFromBridgedUsdc is fully hardened (dust refund + allowance reset, lines 345-361),
- MagnetaBridgeOApp.sol: live (REAL live=3) — MagnetaBridgeOApp is the LayerZero OApp v2 bridge (liquidity-pool model, owner-provisioned per chain). _lzReceive already has the peer-auth guard (_getPeerOrRev
- BexBerachainAdapter.sol: unknown (REAL live=0) — UniV2-facade adapter over BEX (Balancer V2 fork). All 4 findings are non-REAL against current code: F6 (setPair remap) is owner-gated + write-once → Safe-mitiga
- MagnetaBundler.sol: live (REAL live=0) — All 4 findings target a pre-audit version of MagnetaBundler. The current source is the hardened post-audit build (header documents SC01/SC08/SC05/SC03 fixes). F
- MagnetaXChainLpReceiver: live (REAL live=1) — MagnetaXChainLpReceiver is deployed (Gnosis 0xeca6...1fA9, owner = Gnosis Safe). F9 is a REAL fund-segregation flaw: the contract pools bridged native from mult
- MagnetaCurveFactory.sol: live (REAL live=1) — MagnetaCurveFactory is the live permissionless bonding-curve launchpad entry point (deployed on ~16 mainnets). Of 3 HIGH findings: F79 (setParameterBounds has n
- MagnetaCurvePool: live (REAL live=3) — All three HIGH findings map to exact lines in the current source and are genuinely present. F82: finalizeGraduation() sets amountTokenMin/amountETHMin = 0 for a
- TokenCreationModule.sol: live (REAL live=0) — All three findings are misattributed: they describe a CreateTokenDispatcherV2/V3 contract with createTokenAtomic/fanOutCreate/rescueNative/feeVault.call{value:}
- MagnetaPool.sol: live (REAL live=0) — Both findings are non-real against current code. F11 (first-deposit share inflation) is already mitigated: MINIMUM_LIQUIDITY=1000 is minted permanently on first
- MagnetaETFFactory.sol: deferred (REAL live=0) — MagnetaETFFactory is explicitly marked "NOT FOR PRODUCTION / V1.1+ ETF scope" (header lines 1-14) and is part of the not-yet-deployed ETF stack, so live-real fi
- MagnetaETF.sol: deferred (REAL live=0) — MagnetaETF is explicitly NOT FOR PRODUCTION (V1.1+ ETF scope, "Coming Soon", per-header warning). Both Sentinelle findings reflect genuine logic flaws in curren
- ERC20Token.sol: live (REAL live=1) — ERC20Token.sol is live (factory-deployed user tokens). F34 (mint onlyOwner) is the standard single-EOA-compromise mint-and-dump, mitigated by Safe multisig owne
- MAGCronosToken.sol: live (REAL live=2) — MAGCronosToken is a relayer-bridged MAG representation on Cronos where MINTER_ROLE is genuinely a hot-wallet EOA relayer (NOT the Safe — the Safe holds DEFAULT_
- MagnetaGateway: live (REAL live=1) — MagnetaGateway is live cross-chain stack. F37 is a FALSE_POSITIVE: _requiredDVNCount is an explicitly-documented Safe attestation mirror (lines 32-45), not cons
- TokenOpsModule.sol: live (REAL live=0) — Both HIGH findings are scanner misreads of intentional, documented V1 design. F48: _mint deliberately enforces only flatFeeUsdc minimum (PERCENT_FEE_BPS is comm
- TaxClaimModule.sol: live (REAL live=0) — Both HIGH findings on the live TaxClaimModule are non-real. F50 (balanceOf donation inflation) is a FALSE_POSITIVE: execute() is nonReentrant and beforeBal/post
- MagnetaStakingRewards.sol: deferred (REAL live=0) — Both HIGH findings are genuine logic bugs (balanceOf-based solvency double-count in notifyRewardAmount; rescueERC20 ignores outstanding rewards[] liabilities). 
- MagnetaV2Router02: live (REAL live=0) — F2 (SC02 balanceOf-pricing, CVSS 9.1) flags swapExactTokensForETHSupportingFeeOnTransferTokens reading the router's absolute WETH balance at line 383. This is t
- MagnetaERC20OFT: live (REAL live=0) — The sole finding (F23) is a centralization/single-EOA-owner finding. All four cited exploit vectors are onlyOwner/onlyOwnerOrOpsModule gated (mint L223, pause L
- MagnetaOFTStandardFactory.sol: live (REAL live=0) — MagnetaOFTStandardFactory has one CRITICAL finding (F30), and it is purely the generic single-EOA-ownership / no-timelock pattern. All exploit paths it cites (s
- MagnetaBridge.sol: deprecated (REAL live=0) — The current MagnetaBridge.sol is a deprecated placeholder (18 lines) whose constructor unconditionally reverts with "MagnetaBridge: deprecated - use MagnetaBrid
- LPAtomicModule: live (REAL live=0) — F44 is factually correct that the DVN-quorum floor (requiredDVNCount() >= MIN_DVN_QUORUM=2) is only checked in the constructor (lines 231-232) and execute() (26
- MagnetaDLMM.sol: deferred (REAL live=0) — MagnetaDLMM is a Meteora-style DLMM pool deployed permissionlessly via MagnetaFactory.createDLMMPool, but it has NO entries in any deployments/*.json — it is no
- MagnetaMasterChef.sol: deferred (REAL live=0) — MagnetaMasterChef is explicitly marked "NOT FOR PRODUCTION / V1.1+ scope" in its header (lines 4-13) — staking is outside V1 launch and the contract is not depl

## Gouvernance (21) → 1 seul chantier: Safe 3/5 + timelock 24h. FALSE_POSITIVE (22) + ALREADY_FIXED (11) = bruit.
