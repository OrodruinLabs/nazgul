---
name: nazgul:metrics
description: View loop performance metrics — task velocity, approval rates, retry distribution, reviewer stats. Use when asked about loop performance, development metrics, or how the loop is doing.
context: fork
allowed-tools: Read, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.0.0
---

# Nazgul Metrics

## Examples
- `/nazgul:metrics` — View full metrics dashboard
- `/nazgul:metrics reviews` — Focus on reviewer stats

## Current State
- Config: !`cat nazgul/config.json 2>/dev/null | head -3 || echo "NOT_INITIALIZED"`
- Tasks dir: !`ls nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Checkpoints dir: !`ls nazgul/checkpoints/iteration-*.json 2>/dev/null | wc -l | tr -d ' '`
- Reviews dir: !`ls -d nazgul/reviews/TASK-*/ 2>/dev/null | wc -l | tr -d ' '`

## Arguments
$ARGUMENTS

## Instructions

Format all output per `references/ui-brand.md` — use stage banners, status symbols, progress bars, and display patterns defined there.

If Nazgul is not initialized, say so and stop.

### Collect Data

Read these sources to compute metrics:

1. **Task manifests** (`nazgul/tasks/TASK-*.md`):
   - Count by status: DONE, APPROVED, IN_PROGRESS, READY, CHANGES_REQUESTED, BLOCKED, PLANNED
   - For each task: count retry attempts (how many times status went to CHANGES_REQUESTED)
   - Extract claimed_at and completed_at timestamps for velocity

2. **Checkpoints** (`nazgul/checkpoints/iteration-*.json`):
   - Total iterations run
   - First and last iteration timestamps (for time span)
   - Compaction count

3. **Review files** (`nazgul/reviews/TASK-*/`):
   - For each task reviewed: count reviewer verdicts (APPROVED vs CHANGES_REQUESTED)
   - Per-reviewer stats: how many times each reviewer approved vs rejected
   - Consolidated feedback files: count blocking vs non-blocking findings

4. **Config** (`nazgul/config.json`):
   - Mode, max iterations, consecutive failures
   - Active reviewers list

### Compute Metrics

- **Task velocity**: tasks DONE / total iterations (tasks per iteration)
- **First-pass approval rate**: tasks approved on first review / total reviewed tasks
- **Retry distribution**: histogram of retry counts (0, 1, 2, 3)
- **Reviewer blocking rate**: per reviewer, rejections / total reviews
- **Avg iterations per task**: total iterations / tasks DONE
- **Time span**: first checkpoint timestamp to last
- **Loop health**: consecutive failures, compaction count, active task status

### Display Format

```
─── ◈ NAZGUL ▸ METRICS ─────────────────────────────────

Objective: [truncated to 80 chars]
Time span: [first timestamp] → [last timestamp]
Iterations: [total] ([compactions] compactions)

Task Velocity
─────────────────────────────────────
  Total tasks:        [N]
  Completed:          [N]  ████████████░░░░ [%]
  Tasks/iteration:    [N.N]
  Avg iters/task:     [N.N]

Approval Rate
─────────────────────────────────────
  First-pass approvals: [N]/[total] ([%])
  Retry distribution:
    0 retries: [N] tasks  ████████████████
    1 retry:   [N] tasks  ████████
    2 retries: [N] tasks  ████
    3 retries: [N] tasks  ██

Reviewer Stats
─────────────────────────────────────
  [reviewer-name]     ✦ [N] approved  ✗ [N] rejected  ([N]% block rate)
  [reviewer-name]     ✦ [N] approved  ✗ [N] rejected  ([N]% block rate)
  ...

Loop Health
─────────────────────────────────────
  Consecutive failures: [N]
  Mode:                 [hitl/afk]
  Status:               [active/paused/complete]

────────────────────────────────────────────────────────
```

If specific data is missing (no checkpoints, no reviews yet), show "No data" for that section rather than erroring.
