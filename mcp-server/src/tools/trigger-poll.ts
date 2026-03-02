import { PollManager } from '../polling/poll-manager.js';
import { getGitHubRepo } from '../utils/git-remote.js';
import { getGitHubToken } from '../utils/gh-token.js';
import { getCurrentBranch } from '../utils/git-branch.js';

export interface TriggerPollInput {
  resource?: string;
  pr_number?: number;
}

export async function handleTriggerPoll(
  poller: PollManager,
  input: TriggerPollInput
): Promise<{ polled: string[]; repo: string } | { error: string }> {
  const repo = getGitHubRepo();
  if (!repo) {
    return { error: 'Not a GitHub repository' };
  }

  const token = getGitHubToken();
  const resource = input.resource ?? 'all';
  const polled: string[] = [];

  if (resource === 'workflows' || resource === 'all') {
    await poller.pollGitHubWorkflowRuns(repo, token);
    polled.push('workflows');
  }

  if (resource === 'comments' || resource === 'all') {
    let prNumber = input.pr_number ?? null;

    // Auto-discover PR from current branch if not provided
    if (prNumber == null) {
      prNumber = await discoverPrNumber(repo, token);
    }

    if (prNumber != null) {
      await poller.pollGitHubUnresolvedComments(repo, prNumber, token);
      polled.push('comments');
    }
  }

  return { polled, repo };
}

async function discoverPrNumber(
  repo: string,
  token?: string
): Promise<number | null> {
  const branch = getCurrentBranch();
  if (!branch) return null;

  const [owner] = repo.split('/');
  const url = `https://api.github.com/repos/${repo}/pulls?head=${encodeURIComponent(`${owner}:${branch}`)}&state=open&per_page=1`;
  const headers: Record<string, string> = {
    Accept: 'application/vnd.github.v3+json',
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  try {
    const res = await fetch(url, { headers });
    if (!res.ok) return null;
    const pulls = (await res.json()) as Array<{ number: number }>;
    return pulls.length > 0 ? pulls[0].number : null;
  } catch {
    return null;
  }
}
