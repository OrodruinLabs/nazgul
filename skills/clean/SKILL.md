---
name: nazgul:clean
description: Fully remove Nazgul from a project — deletes all runtime state, generated agents, MCP config, permissions, CLAUDE.md injections, and gitignore entries. Use when user says "remove nazgul", "uninstall nazgul", "clean nazgul", or wants to completely undo /nazgul:init.
allowed-tools: Read, Edit, Bash, Glob, Grep, ToolSearch
metadata:
  author: Jose Mejia
---

# Nazgul Clean

## Examples
- `/nazgul:clean` — Fully remove Nazgul from this project (with confirmation)
- `/nazgul:clean --force` — Remove without confirmation prompt
- `/nazgul:clean --teams` — Sweep dead-session Agent-Teams state for THIS project only (does not uninstall Nazgul)
- `/nazgul:clean --teams --all` — Also list dead teams from OTHER projects and ask per team before deleting

## Arguments
$ARGUMENTS

## Current State
- Nazgul initialized: !`test -f nazgul/config.json && echo "YES" || echo "NO"`
- Install mode: !`test -f nazgul/config.json && jq -r '.install_mode // "shared"' nazgul/config.json 2>/dev/null || echo "unknown"`
- Tasks count: !`ls nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Generated agents: !`ls .claude/agents/generated/*.md 2>/dev/null | wc -l | tr -d ' '`
- CLAUDE.md has nazgul section: !`grep -q "Nazgul Framework" CLAUDE.md 2>/dev/null && echo "YES" || echo "NO"`
- Gitignore has nazgul entries: !`grep -qE "# Nazgul Framework (\(local mode\)|— ephemeral runtime)" .gitignore 2>/dev/null && echo "YES" || echo "NO"`

## Instructions

**Pre-load:** Run `ToolSearch` with query `select:AskUserQuestion` to load the interactive prompt tool (deferred by default). Do this BEFORE any step that uses `AskUserQuestion`.

Fully remove Nazgul from this project. No archiving — permanent deletion.

### Step 1: Check if Nazgul is Present

If `$ARGUMENTS` contains `--teams`, skip this presence check and go directly to Step 2b (the `--all` foreign-team flow works even without local Nazgul state; the project-local sweep in Step 2b item 1 still runs, using the default 24-hour threshold when `nazgul/config.json` is absent).

If none of the current state indicators show Nazgul presence (no config, no agents, no MCP entry, no CLAUDE.md section):
- Output: "Nazgul is not installed in this project. Nothing to clean."
- Stop here.

### Step 2: Parse Arguments

Check `$ARGUMENTS` for `--force` flag. If present, skip confirmation.

### Step 2b: Teams-Only Mode (`--teams`)

If `$ARGUMENTS` contains `--teams`, do ONLY this step, then stop (no uninstall):

1. Sweep this project's dead teams:
   ```bash
   bash -c 'source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/team-teardown.sh"; \
     tt_sweep_orphaned_teams "$(pwd)/nazgul" "$(pwd)" "${CLAUDE_SESSION_ID:-}" \
       "$(jq -r "[.guards.team_sweep_min_age_hours // 24, 1] | max" nazgul/config.json 2>/dev/null || echo 24)"'
   ```
   Report each swept team name; report "no dead teams for this project" when the output is empty.
2. If `--all` is ALSO present: list every remaining team in `~/.claude/teams/` whose `config.json` `leadSessionId` has no transcript in `~/.claude/projects/*/<id>.jsonl` modified within the sweep age threshold (`guards.team_sweep_min_age_hours` from `nazgul/config.json` when present, else 24) hours, and whose lead has no session lock `<member-cwd>/nazgul/sessions/<leadSessionId sanitized per session-tracker>.lock` (check BOTH filename forms, with and without a trailing underscore) in any member cwd that has a `nazgul/` dir. If any lock exists, treat the lead as alive and do not offer the team. For each such FOREIGN team (any member `cwd` outside this project), show its name, member cwds, and creation date, then use `AskUserQuestion` per team: Delete / Keep. Before deleting, require the team name to be a safe basename — it must match `[A-Za-z0-9._-]+`, must not be `.` or `..`, and must contain no `/`; skip and report any team whose directory name fails this check. On Delete:
   ```bash
   rm -rf -- "$HOME/.claude/teams/<team>" "$HOME/.claude/tasks/<team>"
   ```
   NEVER delete a foreign team without an explicit per-team answer. Never touch a team whose lead transcript is fresh.
3. Stop here — `--teams` never proceeds to the uninstall flow.

### Step 3: Confirm with User

Unless `--force` is present, show what will be removed, then use `AskUserQuestion` to confirm:

First, display a summary of what exists:
```
Nazgul Clean — Full Removal
═══════════════════════════════════════════════════════

The following will be PERMANENTLY DELETED:

  nazgul/                        [EXISTS | not found]
  .claude/agents/generated/     [N file(s) | not found]
  .claude/settings.json entries [EXISTS | not found]
  CLAUDE.md nazgul section       [EXISTS | not found]
  .gitignore nazgul entries      [EXISTS | not found]
```

Then use `AskUserQuestion`:
- header: "Confirm"
- question: "This cannot be undone. Remove all Nazgul files from this project?"
- options:
  - "Remove everything" — "Permanently delete all Nazgul runtime state, agents, and config"
  - "Abort" — "Cancel and keep everything as-is"

If Abort: stop immediately.

### Step 3b: Restore Git Hooks BEFORE Deleting nazgul/

`nazgul/.githooks/` lives INSIDE the directory Step 4 deletes, and `core.hooksPath` may point at
it. Deleting first leaves `core.hooksPath` dangling at a nonexistent directory — git then runs NO
hooks at all, including the user's own pre-existing hooks, silently. Restore first:

Resolve the project ROOT first — never `$(pwd)` (PR #223 review #10). Run in bash, not zsh:

```bash
bash -c '
set -u
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/nazgul-root.sh"
# resolve_project_root ALWAYS returns 0 (it falls back to the first candidate on a
# non-git host), so test the VALUE, never the status — `|| { ... }` here is dead code.
ROOT="$(resolve_project_root)"
if [ -z "$ROOT" ] || { [ ! -d "$ROOT/.git" ] && [ ! -f "$ROOT/.git" ]; }; then
  echo "clean: \"$ROOT\" is not a git repository — NOT touching core.hooksPath. Re-run from the project root." >&2
  exit 1
fi
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/git-hooks.sh"
uninstall_git_hooks "$ROOT" "$ROOT/nazgul/config.json"

# Belt-and-braces: if core.hooksPath STILL points into nazgul/ (e.g. prior_hooks_path
# was never recorded because install ran under an older version), clear it outright.
# Every state is REPORTED — "no match" and "nothing to do" must not print the same
# thing (RULES §15), and an inherited --global value cannot be cleared by --unset.
CURRENT_HP=$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || echo "")
GLOBAL_HP=$(git config --global --get core.hooksPath 2>/dev/null || echo "")
case "$CURRENT_HP" in
  "")                       echo "clean: core.hooksPath is unset locally — nothing to restore." ;;
  nazgul/*|"$ROOT"/nazgul/*) git -C "$ROOT" config --unset core.hooksPath                                && echo "clean: cleared core.hooksPath (was $CURRENT_HP, inside nazgul/)." ;;
  *)                        echo "clean: core.hooksPath is $CURRENT_HP — OUTSIDE nazgul/, left untouched. Verify this is yours." ;;
esac
if [ -n "$GLOBAL_HP" ]; then
  case "$GLOBAL_HP" in
    *nazgul/*) echo "clean: WARNING — a GLOBAL core.hooksPath ($GLOBAL_HP) points into a nazgul/ directory. --unset touches local config only; clear it yourself with: git config --global --unset core.hooksPath" >&2 ;;
  esac
fi
'
```

Verify: `git -C "$ROOT" config --get core.hooksPath` must print nothing or a path OUTSIDE `nazgul/`.
Both the absolute and relative spellings are matched above: `_GH_MANAGED_RELDIR` makes the relative
form correct today, but a pattern that silently stops matching if that ever changes is exactly the
"a guard that finds nothing must know why" failure this repo prosecutes elsewhere.

### Step 4: Remove Runtime State

Delete the entire `nazgul/` directory:

```bash
rm -rf nazgul/
```

### Step 5: Remove Generated Agents

Delete the `.claude/agents/generated/` directory (these are Nazgul-generated reviewer agents):

```bash
rm -rf .claude/agents/generated/
```

If `.claude/agents/` is now empty, remove it too. Do NOT remove `.claude/` itself as it may contain other settings.

### Step 6: Clean .claude/settings.json

If `.claude/settings.json` exists:

1. Read the file
2. Remove `enableAgentTeams` key if set to `true`
3. Use jq:
   ```bash
   jq 'del(.enableAgentTeams)' .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
   ```
4. If the file is now effectively empty (`{}` or only has empty arrays), delete it
5. If `.claude/` directory is now empty, remove it too. But be careful — check first.

### Step 7: Clean CLAUDE.md

If the project's `CLAUDE.md` contains a Nazgul-injected section:

1. Read `CLAUDE.md`
2. Look for the Nazgul section — it starts with `# Nazgul Framework — Project Instructions` (the content from `templates/CLAUDE.md.template`)
3. Remove everything from that header to the end of the Nazgul section. The Nazgul section runs from `# Nazgul Framework — Project Instructions` to the end of the file (it is always appended at the bottom by `/nazgul:init`).
4. Trim any trailing blank lines left behind
5. If CLAUDE.md is now empty (only whitespace), delete the file entirely
6. If CLAUDE.md still has non-Nazgul content, write it back with the Nazgul section removed

### Step 8: Clean .gitignore

`/nazgul:init` writes one of two blocks depending on install mode. Remove **whichever is present** (both, if somehow both exist). Each block is a **delimited region**, and this is the same region definition `skills/init/SKILL.md` Step 2.5 uses for detection and for its `--force` rewrite — remove the region, never a hand-copied list of lines.

**Region** = the start-sentinel line through the end-sentinel line, **inclusive**, regardless of blank lines or comments between them. Match both sentinels and every line between them with leading whitespace allowed: blocks written before that version were appended indented.

**Legacy fallback**, for a v1 region carrying no end sentinel — bound the region by OWNERSHIP, not by adjacency, because this rule is the boundary for two DESTRUCTIVE operations (the `--force` rewrite and `/nazgul:clean` Step 8). A line belongs to the region only if it is a `#` comment or a pattern beginning `nazgul/` — in the local-mode block also `.claude/agents/generated/` or `.mcp.json`. The region runs from the start sentinel through the last consecutive line that qualifies, terminating at the first BLANK line or EOF and, sooner, at the first line that qualifies as neither: stop there and **name the line removal stopped at**, so a user whose own patterns abutted the block learns why the tail was left. Walking THROUGH the block's own justification comments is deliberate — a rule that stops at the first comment orphans everything after it, and in the shipped block that first interior comment arrives after only four entries. **The residual this does not close, recorded here rather than left for the next reviewer:** an abutting user `#` comment is still consumed, because a user comment and the block's own justification comments are indistinguishable by shape alone.

1. Read `.gitignore`
2. Remove the **local-mode** block if present: the region from `# Nazgul Framework (local mode)` — matched by that prefix alone, since the current block appends a ` (vN)` version suffix and older installs carry none — to `# Nazgul Framework — end local mode`. Its entries, for reference: `nazgul/`, `.claude/agents/generated/`, `.mcp.json`.
3. Remove the **shared-mode ephemeral** block if present: the region from `# Nazgul Framework — ephemeral runtime` — matched by that prefix alone, since the current block appends a ` (v2)` version suffix and older installs carry none — to `# Nazgul Framework — end ephemeral runtime`. The block's entries, for reference: `nazgul/checkpoints/`, `nazgul/logs/`, `nazgul/sessions/`, `nazgul/.session_id`, `nazgul/.stop_failure`, `nazgul/.compaction_count`, `nazgul/.compaction_count.lock`, `nazgul/.tool_failures`, `nazgul/archive/`, `nazgul/conductor/`, `nazgul/context.backup.*/`, `nazgul/in-flight/`, `nazgul/locks/`, `nazgul/.heartbeat.lock`, `nazgul/.githooks/`, `nazgul/dispatch/`, `nazgul/improvement-reports/`, `nazgul/self-audit-window.json`, `nazgul/.hitl-pending`, `nazgul/config.json.tmp`, `nazgul/.nazgul-plan.*`, `nazgul/inbox/`, `nazgul/HANDOFF.md`, `nazgul/improvements.md`, `nazgul/reviews/*/test-failures.md`, `nazgul/reviews/*/simplify-report.md`, `nazgul/reviews/*/diff.patch`, `nazgul/reviews/post-loop-simplify-report.md`, `nazgul/learning/proposed-rules.md`, `nazgul/learning/.last-run`.
   The entry list above is **documentation, not the removal mechanism**; removal is by region. `tests/test-shared-ignore-coverage.sh` compares that list against the block in `skills/init/SKILL.md`, so add an entry here when you add one there, verbatim including the trailing slash. **The comparison covers the path entries only** — the block's `#` justification comment lines are checked against nothing, which is precisely why removal keys on the region instead of on this list.
4. Trim any extra blank lines left behind
5. If `.gitignore` is now empty, delete it
6. Otherwise write it back

### Step 9: Output Summary

```
Nazgul Clean Complete
═══════════════════════════════════════════════════════

Removed:
  nazgul/                        [DELETED | was not present]
  .claude/agents/generated/     [DELETED (N files) | was not present]
  .claude/settings.json entries [CLEANED | was not present]
  CLAUDE.md nazgul section       [REMOVED | was not present]
  .gitignore nazgul entries      [REMOVED | was not present]

Nazgul has been fully removed from this project.
To reinstall: /nazgul:init
```
