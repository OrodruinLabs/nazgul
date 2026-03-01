import { PollManager } from '../polling/poll-manager.js';
import { getGitHubRepo } from '../utils/git-remote.js';

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

  const token = process.env.GITHUB_TOKEN;
  const resource = input.resource ?? 'all';
  const polled: string[] = [];

  if (resource === 'workflows' || resource === 'all') {
    await poller.pollGitHubWorkflowRuns(repo, token);
    polled.push('workflows');
  }

  if (resource === 'comments' || resource === 'all') {
    if (input.pr_number != null) {
      await poller.pollGitHubUnresolvedComments(repo, input.pr_number, token);
      polled.push('comments');
    }
  }

  return { polled, repo };
}
