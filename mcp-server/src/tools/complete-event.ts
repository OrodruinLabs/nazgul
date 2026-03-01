import type Database from 'better-sqlite3';
import { getEventById, updateEventStatus } from '../db.js';

export interface CompleteEventInput {
  event_id: string;
  status: 'done' | 'failed';
  summary?: string;
}

export function handleCompleteEvent(
  db: Database.Database,
  input: CompleteEventInput
): { success: boolean; error?: string } {
  const event = getEventById(db, input.event_id);
  if (!event) return { success: false, error: 'Event not found' };
  updateEventStatus(db, input.event_id, input.status);
  return { success: true };
}
