import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { createApp } from './server.js';
import { createDb, getEventsByStatus } from './db.js';

describe('webhook server', () => {
  let app: ReturnType<typeof createApp>;
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
    app = createApp(db, { skipAuth: true });
  });

  it('POST /webhooks/custom inserts an event', async () => {
    const res = await request(app)
      .post('/webhooks/custom')
      .send({
        source: 'test',
        event_type: 'test.event',
        priority: 'normal',
        payload: { hello: 'world' },
      })
      .expect(201);

    expect(res.body.event_id).toBeDefined();
    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe('test.event');
  });

  it('POST /webhooks/github normalizes PR event', async () => {
    const res = await request(app)
      .post('/webhooks/github')
      .set('X-GitHub-Event', 'pull_request')
      .send({
        action: 'opened',
        number: 42,
        pull_request: {
          title: 'Add feature',
          user: { login: 'dev' },
          head: { ref: 'feature-branch' },
          base: { ref: 'main' },
        },
        repository: { full_name: 'owner/repo' },
      })
      .expect(201);

    expect(res.body.event_id).toBeDefined();
    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe('pr.opened');
    expect(events[0].source).toBe('github');
  });

  it('GET /health returns ok', async () => {
    const res = await request(app).get('/health').expect(200);
    expect(res.body.status).toBe('ok');
  });

  it('rejects unknown webhook path', async () => {
    await request(app).post('/webhooks/unknown').send({}).expect(404);
  });
});
