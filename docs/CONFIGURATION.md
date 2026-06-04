# Configuration

## Flags for `/nazgul:start`

- `--afk` — Autonomous mode: no human pauses, auto-commit, security blocks require later review
- `--yolo` — Full berserk mode: `--afk` + `--dangerously-skip-permissions`. Zero prompts, zero pauses. Requires launching Claude Code with `claude --dangerously-skip-permissions`
- `--hitl` — Human-in-the-loop (default): pause for plan review, doc review, blocker resolution
- `--max N` — Maximum iterations (default: 40)
- `--task-pr` — (with `--yolo`) Create stacked per-task PRs targeting the feature branch instead of a single PR at completion
- `--continue` — Explicit resume (backward compat — bare `/nazgul:start` auto-detects this)

## Viewing & Changing Settings

```bash
/nazgul:config               # Interactive settings menu
/nazgul:config models        # Jump straight to model settings
```

### Model Routing

Different pipeline stages have different complexity needs. Assign the right model to each stage:

| Stage | Default | Why |
|-------|---------|-----|
| Planning | Opus | Decomposition and dependency ordering need deep reasoning |
| Discovery | Sonnet | Codebase scanning is pattern matching |
| Docs | Sonnet | Technical writing is well within Sonnet's capability |
| Review | Sonnet | Structured checklists, Sonnet handles them well |
| Implementation | Sonnet | Code generation is Sonnet's sweet spot |
| Specialists | Sonnet | Same as implementation |
| Post-loop | Haiku | Changelog and docs updates are mechanical |

Three presets are available: **Balanced** (default), **Quality** (all Opus), and **Fast/cheap** (Haiku where possible). Or pick per stage.

## Local Mode

By default, `/nazgul:init` creates files that are tracked in git (shared mode). To keep all Nazgul artifacts out of your project's repository, use local mode:

```bash
/nazgul:init --local
```

This automatically adds `nazgul/`, `.claude/agents/generated/`, and `.mcp.json` to your `.gitignore` and skips CLAUDE.md injection. All Nazgul functionality works identically — the files just stay local to your machine.

## External Board Sync

Nazgul can sync task progress to external project boards so your team has visibility without leaving their existing tools.

```bash
# Connect to GitHub Projects
/nazgul:board github

# Take over an existing project (archives current items)
/nazgul:board github --clean

# Check sync health
/nazgul:board status

# Disconnect
/nazgul:board disconnect
```

**How it works:**

- **One-way sync**: Nazgul is always the source of truth. Local tasks push to GitHub — changes on GitHub are ignored.
- **Automatic**: Discovery detects GitHub repos. `/nazgul:start` prompts to connect. After that, the planner creates issues for new tasks and the stop hook syncs status changes — no manual intervention.
- **Non-blocking**: Sync failures never stop local work. After 5 consecutive failures, sync auto-disables with a warning.
- **Provider-pluggable**: GitHub Projects V2 is the first provider. Adding new providers (ADO, Trello) requires only a new `scripts/board-sync-{provider}.sh` — no changes to config schema or agents.

Each Nazgul task becomes a GitHub Issue with `nazgul:*` labels and custom project fields (Nazgul Status, Task ID, Group). Issues close automatically when tasks reach DONE.

## Config Upgrades

When the Nazgul plugin template evolves (new fields, new sections), existing projects upgrade automatically:

1. On every session start, Nazgul compares your project's `nazgul/config.json` schema version against the plugin template
2. If your config is outdated, it creates a backup (`config.json.v1.bak`), applies incremental migrations, and logs to `nazgul/logs/migrations.log`
3. Existing settings are preserved — only missing fields are added

No manual action required. You'll see a one-time notice: `"Nazgul config migrated from v4 to v5."`

## Webhooks

Nazgul can forward loop events to external HTTP endpoints for remote monitoring of AFK/YOLO runs.

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

Enable fast mode for implementation agents to get faster inference at higher token cost:

```json
{
  "models": {
    "fast_mode_implementation": true
  }
}
```

## Auto-Enhancement

Nazgul can periodically check for new Claude Code features and propose improvements:

```bash
/nazgul:enhance              # One-time check
/loop 2w /nazgul:enhance     # Auto-check every 2 weeks
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

Agents rating their experience below the threshold file structured JSON reports to `nazgul/improvement-reports/`. Reports include task ID, agent name, rating, summary, and improvement suggestions. View aggregated data with `/nazgul:metrics`.

## Concurrent Session Detection

Nazgul automatically tracks active sessions via filesystem locks in `nazgul/sessions/`. Stale locks (>2 hours) are cleaned automatically. If multiple sessions target the same project, a warning is issued on startup. No configuration needed — always active.
