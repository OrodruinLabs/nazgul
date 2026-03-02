import type Database from 'better-sqlite3';
import { PollManager } from './poll-manager.js';
import { getCurrentBranch } from '../utils/git-branch.js';

export class PollScheduler {
  private interval: ReturnType<typeof setInterval> | null = null;
  private running = false;
  private pollManager: PollManager;
  private repo: string;
  private token: string | undefined;

  constructor(db: Database.Database, repo: string, token?: string) {
    this.pollManager = new PollManager(db);
    this.repo = repo;
    this.token = token;
  }

  start(intervalSeconds: number): void {
    if (this.interval) return; // already running

    // Run immediately on start
    this.tick();

    this.interval = setInterval(() => this.tick(), intervalSeconds * 1000);
  }

  stop(): void {
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
  }

  private async tick(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      await this.pollManager.pollGitHubWorkflowRuns(this.repo, this.token);
      console.error(`[hydra-poll] Polled workflow runs for ${this.repo}`);

      // Auto-discover open PR for the current branch and poll its comments
      const prNumber = await this.discoverPrNumber();
      if (prNumber != null) {
        await this.pollManager.pollGitHubUnresolvedComments(this.repo, prNumber, this.token);
        console.error(`[hydra-poll] Polled PR #${prNumber} comments for ${this.repo}`);
      }
    } catch (err) {
      console.error(`[hydra-poll] Error during poll tick:`, err);
    } finally {
      this.running = false;
    }
  }

  private async discoverPrNumber(): Promise<number | null> {
    const branch = getCurrentBranch();
    if (!branch) return null;

    const [owner] = this.repo.split('/');
    const url = `https://api.github.com/repos/${this.repo}/pulls?head=${encodeURIComponent(`${owner}:${branch}`)}&state=open&per_page=1`;
    const headers: Record<string, string> = {
      Accept: 'application/vnd.github.v3+json',
    };
    if (this.token) headers.Authorization = `Bearer ${this.token}`;

    try {
      const res = await fetch(url, { headers });
      if (!res.ok) return null;
      const pulls = (await res.json()) as Array<{ number: number }>;
      return pulls.length > 0 ? pulls[0].number : null;
    } catch {
      return null;
    }
  }
}
