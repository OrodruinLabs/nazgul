import { describe, it, expect, beforeEach } from 'vitest';
import { createDb, getEventById, getEventsByStatus, type HydraEvent } from '../db.js';
import { handleGetPendingEvents } from './get-pending-events.js';
import { handleAcknowledgeEvent } from './acknowledge-event.js';
import { handleCompleteEvent } from './complete-event.js';
import { handleEmitEvent } from './emit-event.js';
import { handleGetEvent } from './get-event.js';
import { handleGetEventHistory } from './get-event-history.js';
import { insertEvent } from '../db.js';

function seedEvent(db: ReturnType<typeof createDb>, overrides: Partial<HydraEvent> = {}): HydraEvent {
  const event: HydraEvent = {
    id: overrides.id ?? 'seed-1',
    source: overrides.source ?? 'github',
    event_type: overrides.event_type ?? 'pr.opened',
    priority: overrides.priority ?? 'normal',
    status: overrides.status ?? 'pending',
    project_id: overrides.project_id ?? null,
    payload: overrides.payload ?? '{"pr_number":42}',
    metadata: overrides.metadata ?? null,
    created_at: overrides.created_at ?? Date.now(),
    processed_at: null,
    completed_at: null,
    retry_count: 0,
  };
  insertEvent(db, event);
  return event;
}

describe('MCP tool handlers', () => {
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
  });

  describe('get_pending_events', () => {
    it('returns pending events sorted by priority', () => {
      seedEvent(db, { id: 'low-1', priority: 'low' });
      seedEvent(db, { id: 'crit-1', priority: 'critical' });
      const result = handleGetPendingEvents(db, {});
      expect(result).toHaveLength(2);
      expect(result[0].id).toBe('crit-1');
    });

    it('filters by source', () => {
      seedEvent(db, { id: 'gh-1', source: 'github' });
      seedEvent(db, { id: 'ci-1', source: 'ci' });
      const result = handleGetPendingEvents(db, { source: 'github' });
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('gh-1');
    });
  });

  describe('acknowledge_event', () => {
    it('transitions event to processing', () => {
      seedEvent(db, { id: 'ack-1' });
      const result = handleAcknowledgeEvent(db, { event_id: 'ack-1' });
      expect(result.success).toBe(true);
      const updated = getEventById(db, 'ack-1');
      expect(updated!.status).toBe('processing');
    });

    it('fails for non-existent event', () => {
      const result = handleAcknowledgeEvent(db, { event_id: 'nope' });
      expect(result.success).toBe(false);
    });
  });

  describe('complete_event', () => {
    it('transitions event to done', () => {
      seedEvent(db, { id: 'comp-1', status: 'processing' });
      const result = handleCompleteEvent(db, { event_id: 'comp-1', status: 'done' });
      expect(result.success).toBe(true);
      const updated = getEventById(db, 'comp-1');
      expect(updated!.status).toBe('done');
      expect(updated!.completed_at).not.toBeNull();
    });
  });

  describe('emit_event', () => {
    it('creates a new event with pending status', () => {
      const result = handleEmitEvent(db, {
        source: 'internal',
        event_type: 'diagnosis.ready',
        priority: 'high',
        payload: '{"task":"TASK-001"}',
      });
      expect(result.event_id).toBeDefined();
      const created = getEventById(db, result.event_id);
      expect(created!.status).toBe('pending');
      expect(created!.source).toBe('internal');
    });
  });

  describe('get_event', () => {
    it('returns full event by id', () => {
      seedEvent(db, { id: 'get-1', payload: '{"data":"test"}' });
      const result = handleGetEvent(db, { event_id: 'get-1' });
      expect(result).not.toBeNull();
      expect(result!.payload).toBe('{"data":"test"}');
    });
  });

  describe('get_event_history', () => {
    it('returns events filtered by source and type', () => {
      seedEvent(db, { id: 'h-1', source: 'github', event_type: 'pr.opened', status: 'done' });
      seedEvent(db, { id: 'h-2', source: 'ci', event_type: 'build.failed', status: 'done' });
      const result = handleGetEventHistory(db, { source: 'github' });
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('h-1');
    });
  });
});
