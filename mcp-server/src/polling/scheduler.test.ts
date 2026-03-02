import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { PollScheduler } from './scheduler.js';
import { createDb } from '../db.js';
import type Database from 'better-sqlite3';

// Mock getCurrentBranch so PR discovery is controlled
vi.mock('../utils/git-branch.js', () => ({
  getCurrentBranch: vi.fn(() => null),
}));

import { getCurrentBranch } from '../utils/git-branch.js';
const mockGetCurrentBranch = vi.mocked(getCurrentBranch);

// Mock fetch to prevent real API calls
const mockFetch = vi.fn();

describe('PollScheduler', () => {
  let db: Database.Database;

  beforeEach(() => {
    vi.useFakeTimers();
    // Mock fetch BEFORE creating scheduler so PollManager captures it
    mockFetch.mockResolvedValue({
      status: 304,
      headers: new Map(),
    });
    globalThis.fetch = mockFetch as any;
    db = createDb(':memory:');
    mockGetCurrentBranch.mockReturnValue(null);
  });

  afterEach(() => {
    vi.useRealTimers();
    mockFetch.mockReset();
    mockGetCurrentBranch.mockReset();
    db.close();
  });

  test('polls on start and then at interval', async () => {
    const scheduler = new PollScheduler(db, 'owner/repo', 'token123');
    scheduler.start(30);

    // Should have polled immediately on start
    // Wait for async tick to complete
    await vi.advanceTimersByTimeAsync(0);
    expect(mockFetch).toHaveBeenCalledTimes(1);

    // Advance by 30 seconds — should poll again
    await vi.advanceTimersByTimeAsync(30000);
    expect(mockFetch).toHaveBeenCalledTimes(2);

    scheduler.stop();
  });

  test('stop clears interval', async () => {
    const scheduler = new PollScheduler(db, 'owner/repo');
    scheduler.start(10);
    await vi.advanceTimersByTimeAsync(0);

    scheduler.stop();

    // Advance time — should NOT poll again
    await vi.advanceTimersByTimeAsync(30000);
    expect(mockFetch).toHaveBeenCalledTimes(1); // only the initial call
  });

  test('start is idempotent when already running', async () => {
    const scheduler = new PollScheduler(db, 'owner/repo');
    scheduler.start(10);
    await vi.advanceTimersByTimeAsync(0);

    // Call start again — should not create a second interval
    scheduler.start(10);

    await vi.advanceTimersByTimeAsync(10000);
    // Should have 2 calls total: initial + one interval tick (not doubled)
    expect(mockFetch).toHaveBeenCalledTimes(2);

    scheduler.stop();
  });

  test('skips overlapping ticks when previous is still running', async () => {
    // First fetch hangs (never resolves during the test window)
    let resolveHanging: () => void;
    const hangingPromise = new Promise<void>((resolve) => { resolveHanging = resolve; });
    mockFetch.mockImplementationOnce(() => hangingPromise.then(() => ({
      status: 304,
      headers: new Map(),
    })));

    const scheduler = new PollScheduler(db, 'owner/repo');
    scheduler.start(5);

    // Initial tick starts — fetch is hanging
    await vi.advanceTimersByTimeAsync(0);
    expect(mockFetch).toHaveBeenCalledTimes(1);

    // Interval fires while first tick is still running — should be skipped
    await vi.advanceTimersByTimeAsync(5000);
    expect(mockFetch).toHaveBeenCalledTimes(1); // still 1, not 2

    // Resolve the hanging fetch so the first tick completes
    resolveHanging!();
    await vi.advanceTimersByTimeAsync(0);

    // Next interval should now work
    mockFetch.mockResolvedValueOnce({ status: 304, headers: new Map() });
    await vi.advanceTimersByTimeAsync(5000);
    expect(mockFetch).toHaveBeenCalledTimes(2);

    scheduler.stop();
  });

  test('handles poll errors without crashing', async () => {
    mockFetch.mockRejectedValueOnce(new Error('network failure'));

    const scheduler = new PollScheduler(db, 'owner/repo');
    scheduler.start(10);

    // Tick should not throw
    await vi.advanceTimersByTimeAsync(0);

    // Scheduler should still be running — next tick works
    mockFetch.mockResolvedValueOnce({
      status: 304,
      headers: new Map(),
    });
    await vi.advanceTimersByTimeAsync(10000);
    expect(mockFetch).toHaveBeenCalledTimes(2);

    scheduler.stop();
  });

  test('discovers PR and polls comments when branch has open PR', async () => {
    mockGetCurrentBranch.mockReturnValue('feature-branch');

    // First call: workflow runs poll (304 no change)
    mockFetch.mockResolvedValueOnce({ status: 304, headers: new Map() });
    // Second call: PR discovery — returns an open PR
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: async () => [{ number: 42 }],
    });
    // Third call: PR comments GraphQL poll (empty unresolved threads)
    mockFetch.mockResolvedValueOnce({
      status: 200,
      json: async () => ({
        data: {
          repository: {
            pullRequest: {
              reviewThreads: {
                pageInfo: { hasNextPage: false, endCursor: null },
                nodes: [],
              },
            },
          },
        },
      }),
    });

    const scheduler = new PollScheduler(db, 'owner/repo', 'token123');
    scheduler.start(60);
    await vi.advanceTimersByTimeAsync(0);

    expect(mockFetch).toHaveBeenCalledTimes(3);

    // Verify the PR discovery URL
    const prDiscoveryCall = mockFetch.mock.calls[1];
    expect(prDiscoveryCall[0]).toContain('/repos/owner/repo/pulls?head=');
    expect(prDiscoveryCall[0]).toContain('owner%3Afeature-branch');

    scheduler.stop();
  });

  test('skips PR comment polling when no open PR found', async () => {
    mockGetCurrentBranch.mockReturnValue('feature-branch');

    // First call: workflow runs poll
    mockFetch.mockResolvedValueOnce({ status: 304, headers: new Map() });
    // Second call: PR discovery — no open PRs
    mockFetch.mockResolvedValueOnce({
      ok: true,
      json: async () => [],
    });

    const scheduler = new PollScheduler(db, 'owner/repo', 'token123');
    scheduler.start(60);
    await vi.advanceTimersByTimeAsync(0);

    // Only 2 calls: workflow + PR discovery (no comment poll)
    expect(mockFetch).toHaveBeenCalledTimes(2);

    scheduler.stop();
  });
});
