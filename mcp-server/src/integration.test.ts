import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { createApp } from './server.js';
import { createDb, getEventById } from './db.js';
import { handleGetPendingEvents } from './tools/get-pending-events.js';
import { handleAcknowledgeEvent } from './tools/acknowledge-event.js';
import { handleCompleteEvent } from './tools/complete-event.js';
import { handleEmitEvent } from './tools/emit-event.js';

describe('end-to-end: webhook to MCP tool flow', () => {
  let app: ReturnType<typeof createApp>;
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
    app = createApp(db, { skipAuth: true });
  });

  it('full lifecycle: ingest, query, acknowledge, complete', async () => {
    // 1. Ingest via webhook
    const webhookRes = await request(app)
      .post('/webhooks/custom')
      .send({
        source: 'ci',
        event_type: 'build.failed',
        priority: 'critical',
        payload: { build_id: 'B-123', logs_url: 'https://ci.example.com/B-123' },
      })
      .expect(201);

    const eventId = webhookRes.body.event_id;

    // 2. Query pending events via tool handler
    const pending = handleGetPendingEvents(db, {});
    expect(pending).toHaveLength(1);
    expect(pending[0].id).toBe(eventId);
    expect(pending[0].priority).toBe('critical');

    // 3. Acknowledge
    const ackResult = handleAcknowledgeEvent(db, { event_id: eventId });
    expect(ackResult.success).toBe(true);

    // Verify no longer pending
    const pendingAfterAck = handleGetPendingEvents(db, {});
    expect(pendingAfterAck).toHaveLength(0);

    // 4. Complete
    const completeResult = handleCompleteEvent(db, {
      event_id: eventId,
      status: 'done',
    });
    expect(completeResult.success).toBe(true);

    const final = getEventById(db, eventId);
    expect(final!.status).toBe('done');
    expect(final!.completed_at).not.toBeNull();
  });

  it('event chaining: agent emits follow-up event', async () => {
    // Ingest original event
    await request(app)
      .post('/webhooks/custom')
      .send({ source: 'ci', event_type: 'build.failed', payload: {} })
      .expect(201);

    // Agent processes and emits follow-up
    handleEmitEvent(db, {
      source: 'internal',
      event_type: 'diagnosis.ready',
      priority: 'high',
      payload: '{"diagnosis":"missing dependency"}',
    });

    // Both events now in queue
    const all = handleGetPendingEvents(db, {});
    expect(all).toHaveLength(2);
    expect(all.some((e) => e.event_type === 'diagnosis.ready')).toBe(true);
  });
});
