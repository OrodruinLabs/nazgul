import type Database from 'better-sqlite3';
import { getEventById, type HydraEvent } from '../db.js';

export interface GetEventInput {
  event_id: string;
}

export function handleGetEvent(
  db: Database.Database,
  input: GetEventInput
): HydraEvent | null {
  return getEventById(db, input.event_id);
}
