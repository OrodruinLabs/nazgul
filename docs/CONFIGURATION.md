# Configuration

## Flags for `/hydra:start`

- `--afk` — Autonomous mode: no human pauses, auto-commit, security blocks require later review
- `--yolo` — Full berserk mode: `--afk` + `--dangerously-skip-permissions`. Zero prompts, zero pauses. Requires launching Claude Code with `claude --dangerously-skip-permissions`
- `--hitl` — Human-in-the-loop (default): pause for plan review, doc review, blocker resolution
- `--max N` — Maximum iterations (default: 40)
- `--task-pr` — (with `--yolo`) Create stacked per-task PRs targeting the feature branch instead of a single PR at completion
- `--continue` — Explicit resume (backward compat — bare `/hydra:start` auto-detects this)

## Local Mode

By default, `/hydra:init` creates files that are tracked in git (shared mode). If you want to keep all Hydra artifacts out of your project's repository, use local mode:

```bash
/hydra:init --local
```

This automatically adds `hydra/`, `.claude/agents/generated/`, and `.mcp.json` to your `.gitignore` and skips CLAUDE.md injection. All Hydra functionality works identically — the files just stay local to your machine.

## External Board Sync

Hydra can sync task progress to external project boards so your team has visibility without leaving their existing tools.

```bash
# Connect to GitHub Projects
/hydra:board github

# Take over an existing project (archives current items)
/hydra:board github --clean

# Check sync health
/hydra:board status

# Disconnect
/hydra:board disconnect
```

**How it works:**

- **One-way sync**: Hydra is always the source of truth. Local tasks push to GitHub — changes on GitHub are ignored.
- **Automatic**: Discovery detects GitHub repos. `/hydra:start` prompts to connect. After that, the planner creates issues for new tasks and the stop hook syncs status changes — no manual intervention.
- **Non-blocking**: Sync failures never stop local work. After 5 consecutive failures, sync auto-disables with a warning.
- **Provider-pluggable**: GitHub Projects V2 is the first provider. Adding new providers (ADO, Trello) requires only a new `scripts/board-sync-{provider}.sh` — no changes to config schema or agents.

Each Hydra task becomes a GitHub Issue with `hydra:*` labels and custom project fields (Hydra Status, Task ID, Group). Issues close automatically when tasks reach DONE.

## Config Upgrades

When the Hydra plugin template evolves (new fields, new sections), existing projects upgrade automatically:

1. On every session start, Hydra compares your project's `hydra/config.json` schema version against the plugin template
2. If your config is outdated, it creates a backup (`config.json.v1.bak`), applies incremental migrations, and logs to `hydra/logs/migrations.log`
3. Existing settings are preserved — only missing fields are added

No manual action required. You'll see a one-time notice: `"Hydra config migrated from v3 to v4."`

## Webhooks

Hydra can forward loop events to external HTTP endpoints for remote monitoring of AFK/YOLO runs.

```json
{
  "webhooks": {
    "enabled": true,
    "url": "https://hooks.slack.com/services/...",
    "events": ["stop", "compact", "task_complete"],
    "headers": { "Authorization": "Bearer ..." }
  }
}
```

Events are POSTed as JSON with iteration count, task status, objective, and branch info. Webhook failures never block the loop.

## Worktree Sparse Paths

For monorepos, configure sparse checkout to speed up task worktree creation:

```json
{
  "branch": {
    "sparse_paths": ["src/api/", "tests/api/", "package.json"]
  }
}
```

When set, task worktrees only check out the specified directories instead of the full repo.

## Fast Mode

Enable fast mode for implementation agents to get ~2.5x faster inference at higher token cost:

```json
{
  "models": {
    "fast_mode_implementation": true
  }
}
```

## Auto-Enhancement

Hydra can periodically check for new Claude Code features and propose improvements:

```bash
/hydra:enhance              # One-time check
/loop 2w /hydra:enhance     # Auto-check every 2 weeks
```

## Self-Improvement Mode

Enable agent self-rating and improvement reports:

```json
{
  "self_improvement": {
    "enabled": true,
    "threshold": 7
  }
}
```

Agents rating their experience below the threshold file structured JSON reports to `hydra/improvement-reports/`. Reports include task ID, agent name, rating, summary, and improvement suggestions. View aggregated data with `/hydra:metrics`.

## Concurrent Session Detection

Hydra automatically tracks active sessions via filesystem locks in `hydra/sessions/`. Stale locks (>2 hours) are cleaned automatically. If multiple sessions target the same project, a warning is issued on startup. No configuration needed — always active.
