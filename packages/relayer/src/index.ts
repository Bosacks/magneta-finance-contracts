import express from 'express';
import cors from 'cors';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { loadConfig } from './config.js';
import { OpStore } from './store.js';
import { ChainWatcher } from './watcher.js';
import { StatusTracker } from './tracker.js';
import { createApi } from './api.js';

const config = loadConfig();

mkdirSync(dirname(config.dbPath), { recursive: true });
const store = new OpStore(config.dbPath);

const watcher = new ChainWatcher(store, config.chains, config.pollIntervalMs);
const tracker = new StatusTracker(store, config.lzScanApiUrl);

const app = express();
app.use(cors());
app.use(express.json());
app.use('/api/v1', createApi(store));

app.listen(config.port, () => {
  console.log(`[relayer] API listening on :${config.port}`);
  console.log(`[relayer] Configured chains: ${config.chains.map(c => c.chainKey).join(', ') || '(none — set MAGNETA_RPC_* and MAGNETA_GATEWAY_* env vars)'}`);

  watcher.start().catch(err => {
    console.error('[relayer] Watcher crashed:', err);
    process.exit(1);
  });

  tracker.start(30_000).catch(err => {
    console.error('[relayer] Tracker crashed:', err);
    process.exit(1);
  });
});

process.on('SIGINT', () => {
  console.log('[relayer] Shutting down…');
  watcher.stop();
  tracker.stop();
  store.close();
  process.exit(0);
});
