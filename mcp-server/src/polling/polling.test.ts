import { describe, it, expect, beforeEach, vi } from 'vitest';
import { createDb, getEventsByStatus } from '../db.js';
import { PollManager } from './poll-manager.js';

describe('PollManager', () => {
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
  });

  it('stores etag and sends If-None-Match on second poll', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({
        status: 200,
        headers: { get: (h: string) => h === 'etag' ? '"abc123"' : null },
        json: async () => ([]),
      })
      .mockResolvedValueOnce({
        status: 304,
        headers: { get: () => null },
      });

    const manager = new PollManager(db, fetchMock as any);
    const key = 'github:owner/repo:pr:1:comments';
    const url = 'https://api.github.com/repos/owner/repo/pulls/1/comments';

    await manager.poll(key, url);
    await manager.poll(key, url);

    expect(fetchMock).toHaveBeenCalledTimes(2);
    const secondCall = fetchMock.mock.calls[1];
    expect(secondCall[1].headers['If-None-Match']).toBe('"abc123"');
  });

  it('returns changed=false on 304', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({
        status: 200,
        headers: { get: (h: string) => h === 'etag' ? '"first"' : null },
        json: async () => ([]),
      })
      .mockResolvedValueOnce({
        status: 304,
        headers: { get: () => null },
      });

    const manager = new PollManager(db, fetchMock as any);
    const key = 'test:resource';
    await manager.poll(key, 'https://example.com');
    const result = await manager.poll(key, 'https://example.com');
    expect(result.changed).toBe(false);
  });

  it('emits summary event for unresolved comments', async () => {
    const comments = [
      { id: 1, body: 'Fix this', user: { login: 'reviewer' }, path: 'src/app.ts', line: 10, created_at: '2026-01-01T00:00:00Z' },
    ];
    const fetchMock = vi.fn().mockResolvedValueOnce({
      status: 200,
      headers: { get: (h: string) => h === 'etag' ? '"first"' : null },
      json: async () => comments,
    });

    const manager = new PollManager(db, fetchMock as any);
    await manager.pollGitHubUnresolvedComments('owner/repo', 1);

    const events = getEventsByStatus(db, 'pending');
    expect(events.length).toBeGreaterThanOrEqual(1);
    expect(events[0].event_type).toBe('pr.comments.unresolved_summary');
  });
});
