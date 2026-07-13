# FEAT-010 — Git-Level Enforcement of Git-Action Guards

- **Date**: 2026-07-10
- **Status**: Approved design (charter for the Nazgul pipeline)
- **Classification**: brownfield / feature
- **Release**: MINOR 2.12.0 → 2.13.0
- **Config schema**: additive v22 → v23 (`migrate_22_to_23`)

## Problem

Two Nazgul guards must prevent a git **action**, and both were previously
implemented by parsing the Bash command string in `PreToolUse(Bash)` hooks.
Both failed to converge under review — proven twice:

- **Base-branch commit guard** (`scripts/base-branch-commit-guard.sh`): 4 bypass
  classes over 3 rounds, plus a cwd false-positive (blocks commits to *other*
  repos when the project repo sits on its base branch) and a `git -C`
  false-negative.
- **H2 conductor pre-merge verdict guard** (deferred TASK-011): ~10 bypasses over
  3 rounds; even the fail-closed redesign leaked (`git ${x:-merge}`
  param-expansion, backslash line-continuation, `bash -c` wrappers).

Root cause: **tokenizing an arbitrary shell string to infer git intent is an
open-ended attack surface** — there is always another bypass. The ambiguity is
in parsing the string at all, not the branch taken afterward.

## Decision

Enforce inside git, after the shell has fully resolved every `$'…'` / `${x:-…}`
/ `bash -c` / continuation, using **git hooks activated via
`git config core.hooksPath`** pointing at a plugin/runtime-managed hooks
directory (approach A, confirmed by architect review).

Rationale for `core.hooksPath` over writing individual files into `.git/hooks`:
install/uninstall is one reversible config toggle (matches the repo's atomic
temp-write-then-swap idiom); worktrees share hooks via the common `.git` dir
either way, so the direct-file approach buys no worktree advantage while adding
the exact "surgically patch text a user owns" fragility FEAT-010 exists to kill;
blast radius under A is a recoverable dangling pointer vs. B's potential
destruction of a user's real `pre-commit`.

## Architecture

### Managed hooks directory
A plugin-owned hooks dir (e.g. `nazgul/.githooks/`) containing:

- `pre-commit` — base-branch guard.
- `pre-merge-commit` — H2 conductor verdict guard.
- A **generic chain-dispatcher**: for *any* hook name git invokes, exec the
  user's previously-installed hook of that name (from the recorded prior
  `hooksPath` / `.git/hooks`), forwarding argv + stdin and propagating the exit
  code. This prevents silently disabling a user's `pre-push`, `commit-msg`,
  husky/lefthook, etc. — one mechanical, testable dispatch function, no per-hook
  special-casing.

### Guard: `pre-commit` (base-branch)
Reads `nazgul/config.json`. If `branch.feature` is set (loop active) **and** the
actual current branch of the committing repo == `branch.base`, block with a
clear message. Because it runs inside the target repo, the old cwd false-positive
is structurally impossible.

### Guard: `pre-merge-commit` (H2 conductor verdict)
Active only when `execution.engine == "conductor"` and
`nazgul/conductor/graph.json` exists. Resolves the merge's source branch from
`GIT_REFLOG_ACTION` (git sets `merge feat/<id>/TASK-NNN` during the merge),
fallback `.git/MERGE_MSG`. Maps branch → unit → recorded verdict in `graph.json`.
Blocks if the verdict is not `APPROVED`.

### Safe degradation (both guards)
Absent/malformed `nazgul/config.json` → allow. For H2 specifically:
non-conductor engine, absent/malformed `graph.json`, or an unresolvable/unrelated
source → allow. Mirrors the existing `base-branch-commit-guard.sh` degradation
block so a sequential-mode merge or an unrelated-repo operation is never wrongly
blocked.

## Removal of the old command-string guard
Delete `scripts/base-branch-commit-guard.sh`, its `hooks/hooks.json`
PreToolUse(Bash) entry, and `tests/test-base-branch-commit-guard.sh` (its git-repo
test harness becomes the template for the new hook tests). The git `pre-commit`
hook fully supersedes it without the cwd false-positive. No advisory string-grep
is retained — it would only re-add the known false-positive with no benefit over
the git hook.

## Lifecycle & self-heal
- **Install** alongside `create_feature_branch()` / `setup_worktree_dir()` in
  `scripts/worktree-utils.sh` (when `branch.feature` is assigned): set
  `core.hooksPath` to the managed dir and durably record the prior value.
- **Uninstall** alongside `cleanup_all_worktrees()` (objective completion):
  restore the recorded prior `core.hooksPath` exactly (or unset if there was
  none).
- **Self-heal** in `scripts/session-context.sh` (SessionStart, existing self-heal
  block): compare recorded state vs actual `git config core.hooksPath`; re-assert
  only on drift, never blindly overwrite (respects an intentional mid-session
  change).

## Config schema v22 → v23
Additive `migrate_22_to_23` in `scripts/migrate-config.sh` (additive-only +
type-guard pattern, per every migration since `migrate_5_to_6`):

- Re-add H2's config key freshly as `conductor.enforce.premerge_guard` (the
  orphan stripped in the v21→v22 deferral — don't ship config for unshipped
  behavior).
- Add `branch.prior_hooks_path` (durable record of pre-install `core.hooksPath`
  for exact restore).
- Add a `guards.git_hooks` enable toggle (default on) gating hook installation.

## Testing
Drive **real git operations** against installed hooks (throwaway repos, actual
`git commit` / `git merge --no-ff`) — template `tests/test-base-branch-commit-guard.sh`:

- base-branch commit blocked; feature-branch commit allowed; commit in an
  unrelated repo allowed.
- chain-dispatch: a pre-existing user `pre-commit` still runs and its exit code
  propagates; a pre-existing `pre-push` (a hook Nazgul does not define) still runs.
- H2: non-APPROVED unit merge blocked; APPROVED merge allowed; sequential-mode
  merge is a no-op.
- install → uninstall round-trip restores prior `core.hooksPath` exactly
  (including the "no prior value" case).
- self-heal re-asserts on drift but not on intentional change.

## Documentation
One **ADR** covering the git-hook approach + install/uninstall lifecycle tied to
loop start / `branch.feature`. Update RULES.md (enforcement tiers), CLAUDE.md
(directory structure — new managed hooks dir + scripts), `docs/` as relevant, and
CHANGELOG. Version bump plugin.json 2.12.0 → 2.13.0 + README badge + git tag.

## Out of scope
- `pre-push` enforcement (mentioned as an option in the charter) — not needed;
  the two hooks above cover the proven failure cases. Chain-dispatch still
  preserves any user `pre-push`.
- Any command-string parsing as a security boundary — explicitly abandoned.
