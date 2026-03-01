import type { Request } from 'express';
import type { HydraEvent } from '../db.js';
import { randomUUID } from 'node:crypto';

const EVENT_MAP: Record<string, (action: string) => string | null> = {
  pull_request: (action) => {
    if (action === 'opened') return 'pr.opened';
    if (action === 'synchronize') return 'pr.updated';
    if (action === 'closed') return 'pr.closed';
    return `pr.${action}`;
  },
  pull_request_review: () => 'pr.review_submitted',
  pull_request_review_comment: () => 'pr.comment.created',
  pull_request_review_thread: (action) => {
    if (action === 'unresolved') return 'pr.comment.unresolved';
    if (action === 'resolved') return 'pr.comment.resolved';
    return null;
  },
  check_run: () => null,
  push: () => 'push',
};

type PartialHydraEvent = Omit<HydraEvent, 'status' | 'processed_at' | 'completed_at' | 'retry_count'>;

export function normalizeGitHub(req: Request): PartialHydraEvent | null {
  const githubEvent = req.headers['x-github-event'] as string;
  const body = req.body;
  const action = body.action ?? '';

  let eventType: string | null = null;

  if (githubEvent === 'check_run' && body.action === 'completed') {
    eventType = body.check_run?.conclusion === 'success'
      ? 'build.succeeded'
      : 'build.failed';
  } else {
    const mapper = EVENT_MAP[githubEvent];
    if (!mapper) return null;
    eventType = mapper(action);
  }

  if (!eventType) return null;

  const repo = body.repository?.full_name ?? 'unknown';

  return {
    id: body.delivery ?? randomUUID(),
    source: 'github',
    event_type: eventType,
    priority: eventType.includes('failed') || eventType.includes('unresolved') ? 'high' : 'normal',
    project_id: null,
    payload: JSON.stringify(body),
    metadata: JSON.stringify({ repo }),
    created_at: Date.now(),
  };
}
