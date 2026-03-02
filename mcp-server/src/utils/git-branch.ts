import { execFileSync } from 'node:child_process';

/**
 * Get the current git branch name.
 *
 * @param cwd - Working directory to run git in (defaults to process.cwd())
 * @returns Branch name, or `null` if detached HEAD or git fails.
 */
export function getCurrentBranch(cwd?: string): string | null {
  try {
    return execFileSync('git', ['branch', '--show-current'], {
      cwd, encoding: 'utf-8',
    }).trim() || null;
  } catch { return null; }
}
