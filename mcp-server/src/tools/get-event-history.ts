import type Database from 'better-sqlite3';
import type { HydraEvent } from '../db.js';

export interface GetEventHistoryInput {
  source?: string;
  event_type?: string;
  since?: number;
  limit?: number;
}

export function handleGetEventHistory(
  db: Database.Database,
  input: GetEventHistoryInput
): HydraEvent[] {
  let sql = 'SELECT * FROM events WHERE 1=1';
  const params: unknown[] = [];

  if (input.source) {
    sql += ' AND source = ?';
    params.push(input.source);
  }
  if (input.event_type) {
    sql += ' AND event_type LIKE ?';
    params.push(input.event_type.replace('*', '%'));
  }
  if (input.since) {
    sql += ' AND created_at >= ?';
    params.push(input.since);
  }

  sql += ' ORDER BY created_at DESC LIMIT ?';
  params.push(input.limit ?? 50);

  return db.prepare(sql).all(...params) as HydraEvent[];
}
