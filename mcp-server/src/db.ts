import Database from 'better-sqlite3';
import { readFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

export interface HydraEvent {
  id: string;
  source: string;
  event_type: string;
  priority: 'critical' | 'high' | 'normal' | 'low';
  status: 'pending' | 'processing' | 'done' | 'failed';
  project_id: string | null;
  payload: string;
  metadata: string | null;
  created_at: number;
  processed_at: number | null;
  completed_at: number | null;
  retry_count: number;
}

export function createDb(path: string): Database.Database {
  mkdirSync(dirname(path), { recursive: true });
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  const schema = readFileSync(join(__dirname, 'schema.sql'), 'utf-8');
  db.exec(schema);
  return db;
}

export function insertEvent(db: Database.Database, event: HydraEvent): void {
  const stmt = db.prepare(`
    INSERT OR IGNORE INTO events
      (id, source, event_type, priority, status, project_id, payload, metadata, created_at, processed_at, completed_at, retry_count)
    VALUES
      (@id, @source, @event_type, @priority, @status, @project_id, @payload, @metadata, @created_at, @processed_at, @completed_at, @retry_count)
  `);
  stmt.run(event);
}

export function getEventById(db: Database.Database, id: string): HydraEvent | null {
  const stmt = db.prepare('SELECT * FROM events WHERE id = ?');
  return (stmt.get(id) as HydraEvent) ?? null;
}

export function getEventsByStatus(
  db: Database.Database,
  status: string,
  options?: { source?: string; event_type?: string; limit?: number }
): HydraEvent[] {
  let sql = 'SELECT * FROM events WHERE status = ?';
  const params: unknown[] = [status];

  if (options?.source) {
    sql += ' AND source = ?';
    params.push(options.source);
  }
  if (options?.event_type) {
    sql += ' AND event_type LIKE ?';
    params.push(options.event_type.replace('*', '%'));
  }

  sql += ` ORDER BY CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 WHEN 'low' THEN 3 END, created_at ASC`;

  if (options?.limit) {
    sql += ' LIMIT ?';
    params.push(options.limit);
  }

  const stmt = db.prepare(sql);
  return stmt.all(...params) as HydraEvent[];
}

export function updateEventStatus(
  db: Database.Database,
  id: string,
  status: 'processing' | 'done' | 'failed'
): void {
  const now = Date.now();
  let sql: string;

  if (status === 'processing') {
    sql = 'UPDATE events SET status = ?, processed_at = ? WHERE id = ?';
  } else {
    sql = 'UPDATE events SET status = ?, completed_at = ? WHERE id = ?';
  }

  db.prepare(sql).run(status, now, id);
}
