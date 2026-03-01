import { execFileSync } from 'node:child_process';

/**
 * Parse the GitHub owner/repo slug from the local git remote "origin".
 *
 * Handles both SSH (`git@github.com:owner/repo.git`) and HTTPS
 * (`https://github.com/owner/repo.git`) formats.
 *
 * @param cwd - Working directory to run git in (defaults to process.cwd())
 * @returns `"owner/repo"` string, or `null` if the remote is not GitHub or
 *          the git command fails.
 */
export function getGitHubRepo(cwd?: string): string | null {
  let url: string;
  try {
    url = execFileSync('git', ['remote', 'get-url', 'origin'], {
      cwd,
      encoding: 'utf-8',
    }).trim();
  } catch {
    return null;
  }

  // SSH format: git@github.com:owner/repo.git
  const sshMatch = url.match(/^git@github\.com:(.+?\/.+?)(?:\.git)?$/);
  if (sshMatch) {
    return sshMatch[1];
  }

  // HTTPS format: https://github.com/owner/repo.git
  const httpsMatch = url.match(/^https?:\/\/github\.com\/(.+?\/.+?)(?:\.git)?$/);
  if (httpsMatch) {
    return httpsMatch[1];
  }

  return null;
}
