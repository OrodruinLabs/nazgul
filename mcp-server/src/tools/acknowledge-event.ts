import type Database from 'better-sqlite3';
import { getEventById, updateEventStatus } from '../db.js';

export interface AcknowledgeEventInput {
  event_id: string;
}

export function handleAcknowledgeEvent(
  db: Database.Database,
  input: AcknowledgeEventInput
): { success: boolean; error?: string } {
  const event = getEventById(db, input.event_id);
  if (!event) return { success: false, error: 'Event not found' };
  if (event.status !== 'pending') {
    return { success: false, error: `Event status is '${event.status}', expected 'pending'` };
  }
  updateEventStatus(db, input.event_id, 'processing');
  return { success: true };
}
