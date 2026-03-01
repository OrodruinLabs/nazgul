import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { PollScheduler } from './scheduler.js';
import { createDb } from '../db.js';
import type Database from 'better-sqlite3';

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
  });

  afterEach(() => {
    vi.useRealTimers();
    mockFetch.mockReset();
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
});
