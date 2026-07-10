---
name: nazgul:status
description: Check the current state of a Nazgul autonomous loop. Use when asked about loop progress, task status, iteration count, review board status, or how the Nazgul loop is going.
context: fork
allowed-tools: Read, Bash, Glob
metadata:
  author: Jose Mejia
  version: 2.7.1
---

# Nazgul Status

## Examples
- `/nazgul:status` — View current loop progress, task counts, and review board state

## Current State
- Mode: !`jq -r '.mode // "unknown"' nazgul/config.json 2>/dev/null || echo "unknown"`
- Iteration: !`jq -r '"\(.current_iteration // 0)/\(.max_iterations // 40)"' nazgul/config.json 2>/dev/null || echo "0/40"`
- Classification: !`jq -r '.project.classification // "unknown"' nazgul/config.json 2>/dev/null || echo "unknown"`
- Execution engine: !`jq -r '.execution.engine // "sequential"' nazgul/config.json 2>/dev/null || echo "sequential"`
- Conductor graph digest: !`E=$(jq -r '.execution.engine // "sequential"' nazgul/config.json 2>/dev/null); if [ "$E" = "conductor" ] && [ -f nazgul/conductor/graph.json ]; then source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/conductor-graph.sh" 2>/dev/null && graph_wave_digest nazgul/conductor/graph.json; else echo "{}"; fi`
- AFK: !`jq -r 'if .afk.enabled then "enabled" else "disabled" end' nazgul/config.json 2>/dev/null || echo "disabled"`
- Paused: !`jq -r '.paused // false' nazgul/config.json 2>/dev/null || echo "false"`
- Reviewers: !`jq -r '.agents.reviewers // [] | join(", ")' nazgul/config.json 2>/dev/null || echo "none"`
- Specialists: !`jq -r '.agents.specialists // [] | join(", ")' nazgul/config.json 2>/dev/null || echo "none"`
- Consecutive failures: !`jq -r '.safety.consecutive_failures // 0' nazgul/config.json 2>/dev/null || echo "0"`
- Context strategy: !`jq -r '.context.budget_strategy // "unknown"' nazgul/config.json 2>/dev/null || echo "unknown"`
- Objective: !`jq -r '.objective // "none"' nazgul/config.json 2>/dev/null || echo "none"`
- Plan summary: !`head -30 nazgul/plan.md 2>/dev/null || echo "No plan found"`
- Git branch: !`git branch --show-current 2>/dev/null`
- Last commit: !`git log --oneline -1 2>/dev/null`
- Latest checkpoint: !`ls -1t nazgul/checkpoints/iteration-*.json 2>/dev/null | head -1 || echo "No checkpoints"`
- Board enabled: !`jq -r '.board.enabled // false' nazgul/config.json 2>/dev/null || echo "false"`
- Board provider: !`jq -r '.board.provider // "none"' nazgul/config.json 2>/dev/null || echo "none"`
- Board last sync: !`jq -r '.board.last_sync // "never"' nazgul/config.json 2>/dev/null || echo "never"`
- Board failures: !`jq -r '.board.sync_failures // 0' nazgul/config.json 2>/dev/null || echo "0"`
- Board tasks mapped: !`jq -r '.board.task_map | length' nazgul/config.json 2>/dev/null || echo "0"`

## Instructions

Format all output per `references/ui-brand.md` — use stage banners, status symbols, progress bars, and task status display patterns defined there.

Using the live data above, produce a formatted status report.

**Conductor-mode branch**: if Execution engine is `conductor` AND Conductor graph digest is not `{}`, render the
Conductor Wave Progress format below in place of the Task Progress block (everything else — header, Active
Task, Review Board, Context Health, Git, Board Sync — stays the same). If Execution engine is `conductor` but
the digest IS `{}` (no `nazgul/conductor/graph.json` yet — planning phase), show a one-line "no graph yet"
notice under Task Progress's position and fall back to the sequential Status Report Format below; never
error. If Execution engine is `sequential`, always use the sequential Status Report Format below unchanged.

### Status Report Format (sequential engine, or conductor with no graph yet)

```text
Nazgul Status
═══════════════════════════════════════
Objective:      [current objective, truncated to 80 chars]
Mode:           [hitl/afk]
Paused:         [yes/no]
Iteration:      [current]/[max]
Classification: [project type]

Task Progress
─────────────────────────────────────
Total:    [N]
Done:              [N]
In Progress:       [N]
Ready:             [N]
In Review:         [N]
Changes Requested: [N]
Blocked:           [N]
Planned:           [N]

Active Task
─────────────────────────────────────
[TASK-ID]: [description]
Status: [status]
Retry: [N]/3

Review Board
─────────────────────────────────────
[list active reviewers]

Context Health
─────────────────────────────────────
Last checkpoint:    [file]
Strategy:           [budget_strategy]
Consecutive fails:  [N]

Git
─────────────────────────────────────
Branch: [branch]
Last:   [commit]

Board Sync
─────────────────────────────────────
Enabled:      [yes/no]
Provider:     [github/none]
Last sync:    [timestamp]
Tasks mapped: [N]
Failures:     [N]
```

### Conductor Wave Progress Format (conductor engine with a graph)

Replaces the Task Progress block only; parse the Conductor graph digest JSON (`current_wave`, `next_unit`,
`units: {ID: {status, sha, wave}}`) to fill it in. One line per unit, status symbol per `references/ui-brand.md`
(✦ DONE, ◆ IN_PROGRESS/IMPLEMENTED/IN_REVIEW, ✗ BLOCKED, ◇ otherwise); `sha` shown short (7 chars) or `-` if null.

```text
Conductor Wave Progress
─────────────────────────────────────
Current wave: [current_wave or "-"]
Next unit:    [next_unit or "none — all units done"]

  [symbol] [UNIT-ID]  wave [N]  sha [short sha or "-"]
  ...
```

1. Parse the config JSON for mode, iteration count, max iterations
2. Parse plan.md to count tasks by status
3. Check nazgul/reviews/ for any active review feedback
4. Check nazgul/checkpoints/ for the latest checkpoint
5. When Execution engine is `conductor` and the graph digest is non-empty, parse it for the Conductor Wave
   Progress block instead of recomputing wave/unit state — never reimplement `graph_wave_digest`
6. Output the formatted status summary
