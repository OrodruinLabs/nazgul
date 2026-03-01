import type Database from 'better-sqlite3';
import { PollManager } from './poll-manager.js';

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
    } catch (err) {
      console.error(`[hydra-poll] Error polling workflow runs:`, err);
    } finally {
      this.running = false;
    }
    // Note: PR comments polling requires a specific PR number, so it's not included
    // in the automatic schedule. Use trigger_poll MCP tool for PR-specific polling.
  }
}
