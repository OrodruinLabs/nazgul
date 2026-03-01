import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';
import { insertEvent, type HydraEvent } from '../db.js';

export interface EmitEventInput {
  source: string;
  event_type: string;
  priority?: 'critical' | 'high' | 'normal' | 'low';
  payload: string;
  metadata?: string;
  project_id?: string;
}

export function handleEmitEvent(
  db: Database.Database,
  input: EmitEventInput
): { event_id: string } {
  const id = randomUUID();
  const event: HydraEvent = {
    id,
    source: input.source,
    event_type: input.event_type,
    priority: input.priority ?? 'normal',
    status: 'pending',
    project_id: input.project_id ?? null,
    payload: input.payload,
    metadata: input.metadata ?? null,
    created_at: Date.now(),
    processed_at: null,
    completed_at: null,
    retry_count: 0,
  };
  insertEvent(db, event);
  return { event_id: id };
}
