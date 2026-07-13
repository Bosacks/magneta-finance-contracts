/**
 * Compute predicted Safe addresses for various saltNonces, without deploying.
 * Use this to sanity-check before running createMagnetaSafe.ts on a real chain.
 *
 * Usage: pnpm ts-node scripts/safe/inhouse/predictAddress.ts
 */
import {
  encodeSetupInitializer,
  computeSafeAddress,
  SAFE_OWNERS,
  SAFE_THRESHOLD,
  SAFE_L2_SINGLETON,
  COMPATIBILITY_FALLBACK_HANDLER,
  MAGNETA_SAFE_UI_ADDRESS,
} from "./lib/safe";

function main() {
  const initializer = encodeSetupInitializer();

  console.log("=== Magneta Safe in-house deploy params ===");
  console.log(`  Owners       : [${SAFE_OWNERS.join(", ")}]`);
  console.log(`  Threshold    : ${SAFE_THRESHOLD}`);
  console.log(`  Singleton    : ${SAFE_L2_SINGLETON} (SafeL2 v1.4.1)`);
  console.log(`  FallbackHdlr : ${COMPATIBILITY_FALLBACK_HANDLER}`);
  console.log(`  Initializer  : ${initializer.length / 2 - 1} bytes`);
  console.log();

  console.log("=== Predicted addresses for saltNonce 0..9 ===");
  for (let n = 0n; n < 10n; n++) {
    const addr = computeSafeAddress(initializer, n);
    const matches = addr.toLowerCase() === MAGNETA_SAFE_UI_ADDRESS.toLowerCase();
    console.log(`  saltNonce=${n}: ${addr}${matches ? "  ← matches Safe UI canonical" : ""}`);
  }
  console.log();
  console.log(`(Safe UI canonical address: ${MAGNETA_SAFE_UI_ADDRESS})`);
  console.log();
  console.log(`Default in-house deploys use saltNonce=0. Address will be the first one above.`);
  console.log(`Same address on every EVM chain that has the canonical Safe v1.4.1 contracts.`);
}

main();
