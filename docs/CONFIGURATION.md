# Configuration

## Flags for `/hydra:start`

- `--afk` — Autonomous mode: no human pauses, auto-commit, security blocks require later review
- `--yolo` — Full berserk mode: `--afk` + `--dangerously-skip-permissions`. Zero prompts, zero pauses. Requires launching Claude Code with `claude --dangerously-skip-permissions`
- `--hitl` — Human-in-the-loop (default): pause for plan review, doc review, blocker resolution
- `--max N` — Maximum iterations (default: 40)
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

No manual action required. You'll see a one-time notice: `"Hydra config migrated from v1 to v2."`
