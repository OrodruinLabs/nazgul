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

  it('returns changed=false on HTTP 4xx/5xx without corrupting state', async () => {
    // First poll succeeds and saves state
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({
        status: 200,
        headers: { get: (h: string) => h === 'etag' ? '"good"' : null },
        json: async () => ({ workflow_runs: [] }),
      })
      // Second poll returns 403 rate limit
      .mockResolvedValueOnce({
        status: 403,
        headers: { get: () => null },
      });

    const manager = new PollManager(db, fetchMock as any);
    const key = 'test:error-handling';

    const first = await manager.poll(key, 'https://api.example.com/test');
    expect(first.changed).toBe(true);

    const second = await manager.poll(key, 'https://api.example.com/test');
    expect(second.changed).toBe(false);

    // Verify last_data was NOT overwritten by the error response
    const state = db.prepare('SELECT last_data FROM poll_state WHERE resource_key = ?').get(key) as { last_data: string };
    expect(JSON.parse(state.last_data)).toEqual({ workflow_runs: [] });
  });

  it('pollGitHubWorkflowRuns emits events for new runs', async () => {
    const workflowData = {
      workflow_runs: [
        {
          id: 100,
          name: 'CI',
          html_url: 'https://github.com/owner/repo/actions/runs/100',
          head_branch: 'main',
          head_sha: 'abc123',
          conclusion: 'failure',
        },
        {
          id: 101,
          name: 'Deploy',
          html_url: 'https://github.com/owner/repo/actions/runs/101',
          head_branch: 'main',
          head_sha: 'def456',
          conclusion: 'success',
        },
      ],
    };
    const fetchMock = vi.fn().mockResolvedValueOnce({
      status: 200,
      headers: { get: (h: string) => (h === 'etag' ? '"wf1"' : null) },
      json: async () => workflowData,
    });

    const manager = new PollManager(db, fetchMock as any);
    await manager.pollGitHubWorkflowRuns('owner/repo');

    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(2);

    const failed = events.find((e) => e.event_type === 'build.failed')!;
    expect(failed).toBeDefined();
    expect(failed.priority).toBe('high');
    const failedPayload = JSON.parse(failed.payload);
    expect(failedPayload.run_id).toBe(100);
    expect(failedPayload.conclusion).toBe('failure');

    const succeeded = events.find((e) => e.event_type === 'build.succeeded')!;
    expect(succeeded).toBeDefined();
    expect(succeeded.priority).toBe('normal');
    const succeededPayload = JSON.parse(succeeded.payload);
    expect(succeededPayload.run_id).toBe(101);
    expect(succeededPayload.conclusion).toBe('success');
  });

  it('pollGitHubWorkflowRuns only emits for new runs not in previous data', async () => {
    // First poll: seed previous state with run 200
    const firstData = {
      workflow_runs: [
        {
          id: 200,
          name: 'CI',
          html_url: 'https://github.com/owner/repo/actions/runs/200',
          head_branch: 'main',
          head_sha: 'aaa111',
          conclusion: 'success',
        },
      ],
    };
    // Second poll: returns run 200 (old) + run 201 (new)
    const secondData = {
      workflow_runs: [
        {
          id: 200,
          name: 'CI',
          html_url: 'https://github.com/owner/repo/actions/runs/200',
          head_branch: 'main',
          head_sha: 'aaa111',
          conclusion: 'success',
        },
        {
          id: 201,
          name: 'CI',
          html_url: 'https://github.com/owner/repo/actions/runs/201',
          head_branch: 'feature',
          head_sha: 'bbb222',
          conclusion: 'failure',
        },
      ],
    };

    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        status: 200,
        headers: { get: (h: string) => (h === 'etag' ? '"wf2a"' : null) },
        json: async () => firstData,
      })
      .mockResolvedValueOnce({
        status: 200,
        headers: { get: (h: string) => (h === 'etag' ? '"wf2b"' : null) },
        json: async () => secondData,
      });

    const manager = new PollManager(db, fetchMock as any);

    // First poll seeds state — emits 1 event for run 200
    await manager.pollGitHubWorkflowRuns('owner/repo');
    const firstEvents = getEventsByStatus(db, 'pending');
    expect(firstEvents).toHaveLength(1);
    expect(JSON.parse(firstEvents[0].payload).run_id).toBe(200);

    // Second poll — should only emit for the NEW run 201
    await manager.pollGitHubWorkflowRuns('owner/repo');
    const allEvents = getEventsByStatus(db, 'pending');
    expect(allEvents).toHaveLength(2);

    const newEvent = allEvents.find(
      (e) => JSON.parse(e.payload).run_id === 201
    )!;
    expect(newEvent).toBeDefined();
    expect(newEvent.event_type).toBe('build.failed');
    expect(newEvent.priority).toBe('high');
  });

  it('pollGitHubWorkflowRuns skips on 304', async () => {
    // First poll to seed state
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({
        status: 200,
        headers: { get: (h: string) => (h === 'etag' ? '"wf3"' : null) },
        json: async () => ({
          workflow_runs: [
            {
              id: 300,
              name: 'CI',
              html_url: 'https://github.com/owner/repo/actions/runs/300',
              head_branch: 'main',
              head_sha: 'ccc333',
              conclusion: 'success',
            },
          ],
        }),
      })
      .mockResolvedValueOnce({
        status: 304,
        headers: { get: () => null },
      });

    const manager = new PollManager(db, fetchMock as any);

    // First poll seeds state and emits 1 event
    await manager.pollGitHubWorkflowRuns('owner/repo');
    const eventsAfterFirst = getEventsByStatus(db, 'pending');
    expect(eventsAfterFirst).toHaveLength(1);

    // Second poll returns 304 — no new events
    await manager.pollGitHubWorkflowRuns('owner/repo');
    const eventsAfterSecond = getEventsByStatus(db, 'pending');
    expect(eventsAfterSecond).toHaveLength(1); // unchanged
  });

  it('emits summary event for unresolved comments via GraphQL', async () => {
    const graphqlResponse = {
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              pageInfo: { hasNextPage: false, endCursor: null },
              nodes: [
                {
                  id: 'T_1',
                  isResolved: false,
                  comments: {
                    nodes: [
                      { id: 'C_1', body: 'Fix this', author: { login: 'reviewer' }, path: 'src/app.ts', line: 10 },
                    ],
                  },
                },
                {
                  id: 'T_2',
                  isResolved: true,
                  comments: {
                    nodes: [
                      { id: 'C_2', body: 'Looks good', author: { login: 'reviewer' }, path: 'src/app.ts', line: 20 },
                    ],
                  },
                },
              ],
            },
          },
        },
      },
    };

    const fetchMock = vi.fn().mockResolvedValueOnce({
      status: 200,
      json: async () => graphqlResponse,
    });

    const manager = new PollManager(db, fetchMock as any);
    await manager.pollGitHubUnresolvedComments('owner/repo', 1, 'token123');

    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe('pr.comments.unresolved_summary');

    const payload = JSON.parse(events[0].payload);
    expect(payload.comments).toHaveLength(1);
    expect(payload.comments[0].id).toBe('C_1');
    expect(payload.comments[0].thread_id).toBe('T_1');
    expect(payload.comments[0].body).toBe('Fix this');
  });

  it('filters out resolved threads from unresolved comments', async () => {
    const graphqlResponse = {
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              pageInfo: { hasNextPage: false, endCursor: null },
              nodes: [
                {
                  id: 'T_resolved',
                  isResolved: true,
                  comments: {
                    nodes: [
                      { id: 'C_resolved', body: 'Done', author: { login: 'dev' }, path: 'a.ts', line: 1 },
                    ],
                  },
                },
              ],
            },
          },
        },
      },
    };

    const fetchMock = vi.fn().mockResolvedValueOnce({
      status: 200,
      json: async () => graphqlResponse,
    });

    const manager = new PollManager(db, fetchMock as any);
    await manager.pollGitHubUnresolvedComments('owner/repo', 1, 'token123');

    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(0);
  });

  it('returns early with no event when token is missing', async () => {
    const fetchMock = vi.fn();

    const manager = new PollManager(db, fetchMock as any);
    await manager.pollGitHubUnresolvedComments('owner/repo', 1);

    expect(fetchMock).not.toHaveBeenCalled();
    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(0);
  });

  it('deduplicates via content hash — same data twice emits only 1 event', async () => {
    const graphqlResponse = {
      data: {
        repository: {
          pullRequest: {
            reviewThreads: {
              pageInfo: { hasNextPage: false, endCursor: null },
              nodes: [
                {
                  id: 'T_dup',
                  isResolved: false,
                  comments: {
                    nodes: [
                      { id: 'C_dup', body: 'Please fix', author: { login: 'reviewer' }, path: 'b.ts', line: 5 },
                    ],
                  },
                },
              ],
            },
          },
        },
      },
    };

    const fetchMock = vi.fn()
      .mockResolvedValueOnce({ status: 200, json: async () => graphqlResponse })
      .mockResolvedValueOnce({ status: 200, json: async () => graphqlResponse });

    const manager = new PollManager(db, fetchMock as any);
    await manager.pollGitHubUnresolvedComments('owner/repo', 1, 'token123');
    await manager.pollGitHubUnresolvedComments('owner/repo', 1, 'token123');

    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(1);
  });
});
