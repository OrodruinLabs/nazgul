import type Database from 'better-sqlite3';
import { insertEvent, type HydraEvent } from '../db.js';
import { randomUUID, createHash } from 'node:crypto';

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
    if (!token) return; // GraphQL requires authentication

    const resourceKey = `github:${repo}:pr:${prNumber}:comments`;
    const [owner, name] = repo.split('/');

    const query = `
      query($owner: String!, $name: String!, $pr: Int!, $cursor: String) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $pr) {
            reviewThreads(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                isResolved
                comments(first: 100) {
                  nodes {
                    id
                    body
                    author { login }
                    path
                    line
                  }
                }
              }
            }
          }
        }
      }
    `;

    // Paginate through all review threads
    interface ThreadComment {
      id: string;
      body: string;
      author: { login: string } | null;
      path: string;
      line: number | null;
    }
    interface ReviewThread {
      id: string;
      isResolved: boolean;
      comments: { nodes: ThreadComment[] };
    }

    const allThreads: ReviewThread[] = [];
    let cursor: string | null = null;

    do {
      const result = await this.graphql(token, query, {
        owner,
        name,
        pr: prNumber,
        cursor,
      });
      if (!result) return;

      const connection =
        result.data?.repository?.pullRequest?.reviewThreads;
      if (!connection) return;

      allThreads.push(...(connection.nodes as ReviewThread[]));
      cursor = connection.pageInfo.hasNextPage
        ? connection.pageInfo.endCursor
        : null;
    } while (cursor);

    // Filter to unresolved threads and flatten comments with thread IDs
    const unresolvedThreads = allThreads.filter((t) => !t.isResolved);
    const unresolvedComments = unresolvedThreads.flatMap((t) =>
      t.comments.nodes.map((c) => ({ ...c, threadId: t.id }))
    );

    if (unresolvedComments.length === 0) return;

    // Content-hash dedup instead of ETag
    if (!this.hasContentChanged(resourceKey, unresolvedComments)) return;

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
        comments: unresolvedComments.map((c) => ({
          id: c.id,
          thread_id: c.threadId,
          body: c.body,
          author: c.author?.login ?? 'unknown',
          file_path: c.path,
          line: c.line,
        })),
      }),
      metadata: JSON.stringify({
        total_comments: unresolvedComments.length,
        thread_ids: [...new Set(unresolvedComments.map((c) => c.threadId))],
      }),
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

  private async graphql(
    token: string,
    query: string,
    variables: Record<string, unknown>
  ): Promise<{ data?: Record<string, any> } | null> {
    try {
      const response = await this.fetchFn(
        'https://api.github.com/graphql',
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ query, variables }),
        }
      );

      if (response.status >= 400) {
        console.error(
          `[hydra-poll] GraphQL HTTP ${response.status}`
        );
        return null;
      }

      return (await response.json()) as {
        data?: Record<string, any>;
      };
    } catch (err) {
      console.error('[hydra-poll] GraphQL request failed:', err);
      return null;
    }
  }

  private hasContentChanged(
    key: string,
    data: unknown
  ): boolean {
    const serialized = JSON.stringify(data);
    const hash = createHash('sha256').update(serialized).digest('hex');
    const state = this.getState(key);

    if (state?.etag === hash) {
      this.updatePollTime(key);
      return false;
    }

    this.saveState(key, hash, serialized);
    return true;
  }
}
