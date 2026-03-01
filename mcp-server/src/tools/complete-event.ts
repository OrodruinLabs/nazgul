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
  if (event.status !== 'processing') {
    return { success: false, error: `Event status is '${event.status}', expected 'processing'` };
  }
  updateEventStatus(db, input.event_id, input.status);
  if (input.summary) {
    db.prepare(
      `UPDATE events SET metadata = json_set(COALESCE(metadata, '{}'), '$.result_summary', ?) WHERE id = ?`
    ).run(input.summary, input.event_id);
  }
  return { success: true };
}
