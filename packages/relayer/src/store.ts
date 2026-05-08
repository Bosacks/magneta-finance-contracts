import Database from 'better-sqlite3';
import type { TrackedOp, OpStatus } from './types.js';

export class OpStore {
  private db: Database.Database;

  constructor(dbPath: string) {
    this.db = new Database(dbPath);
    this.db.pragma('journal_mode = WAL');
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS ops (
        guid           TEXT PRIMARY KEY,
        src_chain      TEXT NOT NULL,
        dst_chain      TEXT NOT NULL,
        src_eid        INTEGER NOT NULL,
        dst_eid        INTEGER NOT NULL,
        op             INTEGER NOT NULL,
        caller         TEXT NOT NULL,
        src_tx_hash    TEXT NOT NULL,
        dst_tx_hash    TEXT,
        status         TEXT NOT NULL DEFAULT 'pending',
        created_at     INTEGER NOT NULL,
        updated_at     INTEGER NOT NULL,
        retries        INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_ops_status ON ops(status);
      CREATE INDEX IF NOT EXISTS idx_ops_caller ON ops(caller);
      CREATE INDEX IF NOT EXISTS idx_ops_src_chain ON ops(src_chain);
    `);
  }

  insert(op: TrackedOp): void {
    this.db.prepare(`
      INSERT OR IGNORE INTO ops
        (guid, src_chain, dst_chain, src_eid, dst_eid, op, caller,
         src_tx_hash, dst_tx_hash, status, created_at, updated_at, retries)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      op.guid, op.srcChain, op.dstChain, op.srcEid, op.dstEid,
      op.op, op.caller, op.srcTxHash, op.dstTxHash,
      op.status, op.createdAt, op.updatedAt, op.retries,
    );
  }

  updateStatus(guid: string, status: OpStatus, dstTxHash?: string): void {
    const now = Math.floor(Date.now() / 1000);
    if (dstTxHash) {
      this.db.prepare(
        `UPDATE ops SET status = ?, dst_tx_hash = ?, updated_at = ? WHERE guid = ?`
      ).run(status, dstTxHash, now, guid);
    } else {
      this.db.prepare(
        `UPDATE ops SET status = ?, updated_at = ? WHERE guid = ?`
      ).run(status, now, guid);
    }
  }

  incrementRetries(guid: string): void {
    this.db.prepare(
      `UPDATE ops SET retries = retries + 1, updated_at = ? WHERE guid = ?`
    ).run(Math.floor(Date.now() / 1000), guid);
  }

  getPending(): TrackedOp[] {
    return this.db.prepare(
      `SELECT * FROM ops WHERE status IN ('pending', 'in_transit') ORDER BY created_at ASC`
    ).all().map(rowToOp);
  }

  getByGuid(guid: string): TrackedOp | undefined {
    const row = this.db.prepare(`SELECT * FROM ops WHERE guid = ?`).get(guid);
    return row ? rowToOp(row) : undefined;
  }

  getByCaller(caller: string, limit = 50): TrackedOp[] {
    return this.db.prepare(
      `SELECT * FROM ops WHERE caller = ? ORDER BY created_at DESC LIMIT ?`
    ).all(caller.toLowerCase(), limit).map(rowToOp);
  }

  getRecent(limit = 100): TrackedOp[] {
    return this.db.prepare(
      `SELECT * FROM ops ORDER BY created_at DESC LIMIT ?`
    ).all(limit).map(rowToOp);
  }

  close(): void {
    this.db.close();
  }
}

function rowToOp(row: unknown): TrackedOp {
  const r = row as Record<string, unknown>;
  return {
    guid: r.guid as string,
    srcChain: r.src_chain as string,
    dstChain: r.dst_chain as string,
    srcEid: r.src_eid as number,
    dstEid: r.dst_eid as number,
    op: r.op as number,
    caller: r.caller as string,
    srcTxHash: r.src_tx_hash as string,
    dstTxHash: (r.dst_tx_hash as string) ?? null,
    status: r.status as OpStatus,
    createdAt: r.created_at as number,
    updatedAt: r.updated_at as number,
    retries: r.retries as number,
  };
}
