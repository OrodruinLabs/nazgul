import { execFileSync } from 'node:child_process';

/**
 * Resolve a GitHub API token.
 *
 * Priority:
 * 1. GITHUB_TOKEN environment variable (explicit override)
 * 2. `gh auth token` (uses existing gh CLI authentication)
 *
 * Returns undefined if neither is available.
 */
export function getGitHubToken(): string | undefined {
  if (process.env.GITHUB_TOKEN) return process.env.GITHUB_TOKEN;
  try {
    return execFileSync('gh', ['auth', 'token'], {
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();
  } catch {
    return undefined;
  }
}
