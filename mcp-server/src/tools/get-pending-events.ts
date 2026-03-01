import type Database from 'better-sqlite3';
import { getEventsByStatus, type HydraEvent } from '../db.js';

export interface GetPendingEventsInput {
  source?: string;
  event_type?: string;
  limit?: number;
}

export function handleGetPendingEvents(
  db: Database.Database,
  input: GetPendingEventsInput
): HydraEvent[] {
  return getEventsByStatus(db, 'pending', {
    source: input.source,
    event_type: input.event_type,
    limit: input.limit ?? 20,
  });
}
