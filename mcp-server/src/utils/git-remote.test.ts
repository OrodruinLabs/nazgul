import { describe, it, expect, vi, beforeEach } from 'vitest';
import { execFileSync } from 'node:child_process';
import { getGitHubRepo } from './git-remote.js';

vi.mock('node:child_process', () => ({
  execFileSync: vi.fn(),
}));

const mockExecFileSync = vi.mocked(execFileSync);

describe('getGitHubRepo', () => {
  beforeEach(() => {
    vi.resetAllMocks();
  });

  it('parses SSH format remote', () => {
    mockExecFileSync.mockReturnValue('git@github.com:owner/repo.git\n');
    const result = getGitHubRepo('/some/dir');
    expect(result).toBe('owner/repo');
    expect(mockExecFileSync).toHaveBeenCalledWith(
      'git',
      ['remote', 'get-url', 'origin'],
      { cwd: '/some/dir', encoding: 'utf-8' },
    );
  });

  it('parses HTTPS format remote', () => {
    mockExecFileSync.mockReturnValue('https://github.com/owner/repo.git\n');
    const result = getGitHubRepo();
    expect(result).toBe('owner/repo');
  });

  it('returns null for non-GitHub remote', () => {
    mockExecFileSync.mockReturnValue('https://gitlab.com/owner/repo.git\n');
    const result = getGitHubRepo();
    expect(result).toBeNull();
  });

  it('returns null when git command fails', () => {
    mockExecFileSync.mockImplementation(() => {
      throw new Error('fatal: not a git repository');
    });
    const result = getGitHubRepo();
    expect(result).toBeNull();
  });

  it('handles SSH remote without .git suffix', () => {
    mockExecFileSync.mockReturnValue('git@github.com:owner/repo\n');
    const result = getGitHubRepo();
    expect(result).toBe('owner/repo');
  });

  it('handles HTTPS remote without .git suffix', () => {
    mockExecFileSync.mockReturnValue('https://github.com/owner/repo\n');
    const result = getGitHubRepo();
    expect(result).toBe('owner/repo');
  });
});
