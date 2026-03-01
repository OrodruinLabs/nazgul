---
name: hydra-status
description: Check the current state of a Hydra autonomous loop. Use when asked about loop progress, task status, iteration count, review board status, or how the Hydra loop is going.
context: fork
allowed-tools: Read, Bash, Glob
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Status

## Examples
- `/hydra-status` — View current loop progress, task counts, and review board state

## Current State
- Mode: !`jq -r '.mode // "unknown"' hydra/config.json 2>/dev/null || echo "unknown"`
- Iteration: !`jq -r '"\(.current_iteration // 0)/\(.max_iterations // 40)"' hydra/config.json 2>/dev/null || echo "0/40"`
- Classification: !`jq -r '.project.classification // "unknown"' hydra/config.json 2>/dev/null || echo "unknown"`
- AFK: !`jq -r 'if .afk.enabled then "enabled" else "disabled" end' hydra/config.json 2>/dev/null || echo "disabled"`
- Paused: !`jq -r '.paused // false' hydra/config.json 2>/dev/null || echo "false"`
- Reviewers: !`jq -r '.agents.reviewers // [] | join(", ")' hydra/config.json 2>/dev/null || echo "none"`
- Specialists: !`jq -r '.agents.specialists // [] | join(", ")' hydra/config.json 2>/dev/null || echo "none"`
- Consecutive failures: !`jq -r '.safety.consecutive_failures // 0' hydra/config.json 2>/dev/null || echo "0"`
- Context strategy: !`jq -r '.context.budget_strategy // "unknown"' hydra/config.json 2>/dev/null || echo "unknown"`
- Objective: !`jq -r '.objective // "none"' hydra/config.json 2>/dev/null || echo "none"`
- Plan summary: !`head -30 hydra/plan.md 2>/dev/null || echo "No plan found"`
- Git branch: !`git branch --show-current 2>/dev/null`
- Last commit: !`git log --oneline -1 2>/dev/null`
- Latest checkpoint: !`ls -1t hydra/checkpoints/iteration-*.json 2>/dev/null | head -1 || echo "No checkpoints"`

## Instructions

Using the live data above, produce a formatted status report:

### Status Report Format

```
Hydra Status
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
```

1. Parse the config JSON for mode, iteration count, max iterations
2. Parse plan.md to count tasks by status
3. Check hydra/reviews/ for any active review feedback
4. Check hydra/checkpoints/ for the latest checkpoint
5. Output the formatted status summary
