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

    if (response.status >= 400) {
      console.error(`[hydra-poll] HTTP ${response.status} for ${url}`);
      return { changed: false };
    }

    const etag = response.headers.get('etag');
    const data = await response.json();
    this.saveState(resourceKey, etag, JSON.stringify(data));
    return { changed: true, data };
  }

  async pollGitHubWorkflowRuns(
    repo: string,
    token?: string
  ): Promise<void> {
    const resourceKey = `github:${repo}:workflow_runs`;
    const url = `https://api.github.com/repos/${repo}/actions/runs?status=completed&per_page=10`;
    const headers: Record<string, string> = {
      Accept: 'application/vnd.github.v3+json',
    };
    if (token) headers.Authorization = `Bearer ${token}`;

    // Read previous state BEFORE poll() overwrites it
    const previousState = this.getState(resourceKey);
    const previousRunIds = new Set<number>();
    if (previousState?.last_data) {
      const prev = JSON.parse(previousState.last_data);
      for (const run of prev.workflow_runs ?? []) {
        previousRunIds.add(run.id);
      }
    }

    const result = await this.poll(resourceKey, url, headers);
    if (!result.changed || !result.data) return;

    const response = result.data as {
      workflow_runs: Array<{
        id: number;
        name: string;
        html_url: string;
        head_branch: string;
        head_sha: string;
        conclusion: string;
      }>;
    };

    for (const run of response.workflow_runs ?? []) {
      if (previousRunIds.has(run.id)) continue;
      if (run.conclusion !== 'failure' && run.conclusion !== 'success') continue;

      const event: HydraEvent = {
        id: randomUUID(),
        source: 'github',
        event_type:
          run.conclusion === 'failure' ? 'build.failed' : 'build.succeeded',
        priority: run.conclusion === 'failure' ? 'high' : 'normal',
        status: 'pending',
        project_id: null,
        payload: JSON.stringify({
          repo,
          run_id: run.id,
          name: run.name,
          html_url: run.html_url,
          head_branch: run.head_branch,
          head_sha: run.head_sha,
          conclusion: run.conclusion,
        }),
        metadata: null,
        created_at: Date.now(),
        processed_at: null,
        completed_at: null,
        retry_count: 0,
      };

      insertEvent(this.db, event);
    }
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
