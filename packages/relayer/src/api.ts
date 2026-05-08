import { Router, type Request, type Response } from 'express';
import type { OpStore } from './store.js';

export function createApi(store: OpStore): Router {
  const router = Router();

  // SEC: Public read-only relayer op lookup by guid; pagination capped at 200. Sentinelleai api-security:API2-1 acknowledged.
  router.get('/ops/:guid', (req: Request, res: Response) => {
    const op = store.getByGuid(req.params.guid);
    if (!op) {
      res.status(404).json({ error: 'not_found' });
      return;
    }
    res.json(op);
  });

  // SEC: Public read-only relayer op list; pagination capped at 200. Sentinelleai api-security:API2-1 acknowledged.
  router.get('/ops', (req: Request, res: Response) => {
    const caller = req.query.caller as string | undefined;
    const limit = Math.min(Number(req.query.limit) || 50, 200);

    if (caller) {
      res.json(store.getByCaller(caller.toLowerCase(), limit));
    } else {
      res.json(store.getRecent(limit));
    }
  });

  // SEC: Public health probe. Sentinelleai api-security:API2-1 acknowledged.
  router.get('/health', (_req: Request, res: Response) => {
    res.json({ ok: true, ts: Date.now() });
  });

  return router;
}
