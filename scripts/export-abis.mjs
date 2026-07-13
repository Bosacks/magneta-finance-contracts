#!/usr/bin/env node
/**
 * Centralized ABI export — single source of truth for consumer repos.
 *
 * Copies ABIs from compiled hardhat artifacts (this repo + tokens/) to the
 * frontend/service repos that keep local copies. Default mode is --check:
 * it only REPORTS drift between artifacts and consumer copies.
 *
 * IMPORTANT: consumer ABIs must match the DEPLOYED contracts, not the
 * latest sources. Sources in this repo may carry hardening that is not
 * redeployed yet (e.g. MagnetaBundler V2 ABI). Only run with --write as
 * part of a redeploy/cutover, after the on-chain contracts match the
 * artifacts being exported.
 *
 * Usage:
 *   node scripts/export-abis.mjs           # check mode (no writes)
 *   node scripts/export-abis.mjs --write   # overwrite consumer copies
 *
 * Prerequisite: compile first (root: `npx hardhat compile`,
 * tokens: `cd tokens && npx hardhat compile`).
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJETS = resolve(ROOT, '..');

// shape: 'artifact' = full hardhat artifact JSON (consumer reads `.abi`),
//        'abi'      = bare ABI array.
const EXPORTS = [
  {
    artifact: 'artifacts/contracts/core/MagnetaBundler.sol/MagnetaBundler.json',
    dest: 'magneta-finance-tokens/lib/abis/MagnetaBundler.json',
    shape: 'artifact',
  },
  {
    artifact: 'tokens/artifacts/contracts/MagnetaTokenFactory.sol/MagnetaTokenFactory.json',
    dest: 'magneta-finance-tokens/lib/abis/MagnetaTokenFactory.json',
    shape: 'abi',
  },
  {
    artifact: 'tokens/artifacts/contracts/MagnetaTokenFactory.sol/MagnetaTokenFactory.json',
    dest: 'magneta-finance-MagnetaTerminal/token-sync-service/src/worker/abis/MagnetaTokenFactory.json',
    shape: 'abi',
  },
];

const write = process.argv.includes('--write');
let drift = 0;
let missing = 0;

for (const entry of EXPORTS) {
  const artifactPath = resolve(ROOT, entry.artifact);
  const destPath = resolve(PROJETS, entry.dest);

  if (!existsSync(artifactPath)) {
    console.warn(`SKIP (artifact missing, compile first): ${entry.artifact}`);
    missing++;
    continue;
  }
  if (!existsSync(destPath)) {
    console.warn(`SKIP (consumer repo/file not found): ${entry.dest}`);
    missing++;
    continue;
  }

  const artifact = JSON.parse(readFileSync(artifactPath, 'utf8'));
  const out =
    entry.shape === 'artifact'
      ? JSON.stringify(artifact, null, 2) + '\n'
      : JSON.stringify(artifact.abi, null, 4) + '\n';

  const current = readFileSync(destPath, 'utf8');
  const same =
    JSON.stringify(
      entry.shape === 'artifact' ? JSON.parse(current).abi : JSON.parse(current)
    ) === JSON.stringify(artifact.abi);

  if (same) {
    console.log(`OK   ${entry.dest}`);
    continue;
  }

  drift++;
  if (write) {
    writeFileSync(destPath, out);
    console.log(`WROTE ${entry.dest}`);
  } else {
    console.log(`DRIFT ${entry.dest} (ABI differs from artifact — deployed vs source? use --write only at cutover)`);
  }
}

console.log(`\n${EXPORTS.length} exports: ${drift} drift${write ? ' (written)' : ''}, ${missing} skipped`);
if (drift && !write) process.exit(1);
