import { describe, it, expect, beforeEach } from 'vitest';
import { createDb, insertEvent, getEventById, getEventsByStatus, updateEventStatus } from './db.js';
import type { HydraEvent } from './db.js';

describe('db', () => {
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
  });

  it('inserts and retrieves an event by id', () => {
    const event: HydraEvent = {
      id: 'test-uuid-1',
      source: 'github',
      event_type: 'pr.opened',
      priority: 'normal',
      status: 'pending',
      project_id: null,
      payload: JSON.stringify({ pr_number: 42 }),
      metadata: null,
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };
    insertEvent(db, event);
    const result = getEventById(db, 'test-uuid-1');
    expect(result).not.toBeNull();
    expect(result!.source).toBe('github');
    expect(result!.event_type).toBe('pr.opened');
  });

  it('returns null for non-existent event', () => {
    const result = getEventById(db, 'does-not-exist');
    expect(result).toBeNull();
  });

  it('queries events by status', () => {
    const base = {
      source: 'ci',
      event_type: 'build.failed',
      priority: 'critical' as const,
      project_id: null,
      payload: '{}',
      metadata: null,
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };
    insertEvent(db, { ...base, id: 'e1', status: 'pending' });
    insertEvent(db, { ...base, id: 'e2', status: 'pending' });
    insertEvent(db, { ...base, id: 'e3', status: 'done' });

    const pending = getEventsByStatus(db, 'pending');
    expect(pending).toHaveLength(2);
  });

  it('updates event status with timestamp', () => {
    const event: HydraEvent = {
      id: 'e-update',
      source: 'github',
      event_type: 'pr.opened',
      priority: 'normal',
      status: 'pending',
      project_id: null,
      payload: '{}',
      metadata: null,
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };
    insertEvent(db, event);
    updateEventStatus(db, 'e-update', 'processing');
    const updated = getEventById(db, 'e-update');
    expect(updated!.status).toBe('processing');
    expect(updated!.processed_at).not.toBeNull();
  });

  it('silently skips duplicate inserts', () => {
    const event: HydraEvent = {
      id: 'dup-1',
      source: 'github',
      event_type: 'push',
      priority: 'normal',
      status: 'pending',
      project_id: null,
      payload: '{}',
      metadata: null,
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };
    insertEvent(db, event);
    insertEvent(db, event);
    const all = getEventsByStatus(db, 'pending');
    expect(all).toHaveLength(1);
  });
});
