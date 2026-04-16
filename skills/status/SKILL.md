---
name: nazgul:status
description: Check the current state of a Nazgul autonomous loop. Use when asked about loop progress, task status, iteration count, review board status, or how the Nazgul loop is going.
context: fork
allowed-tools: Read, Bash, Glob
metadata:
  author: Jose Mejia
  version: 1.2.2
---

# Nazgul Status

## Examples
- `/nazgul:status` — View current loop progress, task counts, and review board state

## Current State
- Mode: !`jq -r '.mode // "unknown"' nazgul/config.json 2>/dev/null || echo "unknown"`
- Iteration: !`jq -r '"\(.current_iteration // 0)/\(.max_iterations // 40)"' nazgul/config.json 2>/dev/null || echo "0/40"`
- Classification: !`jq -r '.project.classification // "unknown"' nazgul/config.json 2>/dev/null || echo "unknown"`
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

Using the live data above, produce a formatted status report:

### Status Report Format

```
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

1. Parse the config JSON for mode, iteration count, max iterations
2. Parse plan.md to count tasks by status
3. Check nazgul/reviews/ for any active review feedback
4. Check nazgul/checkpoints/ for the latest checkpoint
5. Output the formatted status summary
