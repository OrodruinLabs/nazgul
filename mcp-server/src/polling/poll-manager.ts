import type Database from 'better-sqlite3';
import { insertEvent, type HydraEvent } from '../db.js';
import { randomUUID } from 'node:crypto';

type FetchFn = typeof globalThis.fetch;

interface PollState {
  resource_key: string;
  etag: string | null;
  last_data: string | null;
  last_polled: number;
  poll_count: number;
}

export class PollManager {
  constructor(
    private db: Database.Database,
    private fetchFn: FetchFn = globalThis.fetch
  ) {}

  async poll(
    resourceKey: string,
    url: string,
    headers: Record<string, string> = {}
  ): Promise<{ changed: boolean; data?: unknown }> {
    const state = this.getState(resourceKey);
    const reqHeaders: Record<string, string> = { ...headers };
    if (state?.etag) {
      reqHeaders['If-None-Match'] = state.etag;
    }

    const response = await this.fetchFn(url, { headers: reqHeaders });

    if (response.status === 304) {
      this.updatePollTime(resourceKey);
      return { changed: false };
    }

    const etag = response.headers.get('etag');
    const data = await response.json();
    this.saveState(resourceKey, etag, JSON.stringify(data));
    return { changed: true, data };
  }

  async pollGitHubUnresolvedComments(
    repo: string,
    prNumber: number,
    token?: string
  ): Promise<void> {
    const resourceKey = `github:${repo}:pr:${prNumber}:comments`;
    const url = `https://api.github.com/repos/${repo}/pulls/${prNumber}/comments`;
    const headers: Record<string, string> = {
      Accept: 'application/vnd.github.v3+json',
    };
    if (token) headers.Authorization = `Bearer ${token}`;

    const result = await this.poll(resourceKey, url, headers);
    if (!result.changed || !result.data) return;

    const comments = result.data as Array<{
      id: number;
      body: string;
      user: { login: string };
      path: string;
      line: number | null;
      created_at: string;
    }>;

    if (comments.length === 0) return;

    const event: HydraEvent = {
      id: randomUUID(),
      source: 'github',
      event_type: 'pr.comments.unresolved_summary',
      priority: 'high',
      status: 'pending',
      project_id: null,
      payload: JSON.stringify({
        repo,
        pr_number: prNumber,
        comments: comments.map((c) => ({
          id: c.id,
          body: c.body,
          author: c.user.login,
          file_path: c.path,
          line: c.line,
        })),
      }),
      metadata: JSON.stringify({ total_comments: comments.length }),
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };

    insertEvent(this.db, event);
  }

  private getState(key: string): PollState | null {
    const stmt = this.db.prepare(
      'SELECT * FROM poll_state WHERE resource_key = ?'
    );
    return (stmt.get(key) as PollState) ?? null;
  }

  private saveState(key: string, etag: string | null, data: string): void {
    const stmt = this.db.prepare(`
      INSERT INTO poll_state (resource_key, etag, last_data, last_polled, poll_count)
      VALUES (?, ?, ?, ?, 1)
      ON CONFLICT(resource_key) DO UPDATE SET
        etag = excluded.etag,
        last_data = excluded.last_data,
        last_polled = excluded.last_polled,
        poll_count = poll_count + 1
    `);
    stmt.run(key, etag, data, Date.now());
  }

  private updatePollTime(key: string): void {
    this.db
      .prepare(
        'UPDATE poll_state SET last_polled = ?, poll_count = poll_count + 1 WHERE resource_key = ?'
      )
      .run(Date.now(), key);
  }
}
