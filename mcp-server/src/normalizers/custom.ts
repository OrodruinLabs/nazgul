import type { Request } from 'express';
import type { HydraEvent } from '../db.js';
import { randomUUID } from 'node:crypto';

type PartialHydraEvent = Omit<HydraEvent, 'status' | 'processed_at' | 'completed_at' | 'retry_count'>;

export function normalizeCustom(req: Request): PartialHydraEvent | null {
  const body = req.body;
  if (!body.source || !body.event_type) return null;

  return {
    id: body.id ?? randomUUID(),
    source: body.source,
    event_type: body.event_type,
    priority: body.priority ?? 'normal',
    project_id: body.project_id ?? null,
    payload: JSON.stringify(body.payload ?? {}),
    metadata: body.metadata ? JSON.stringify(body.metadata) : null,
    created_at: Date.now(),
  };
}
