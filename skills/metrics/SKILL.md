---
name: nazgul:metrics
description: View loop performance metrics — task velocity, approval rates, retry distribution, reviewer stats. Use when asked about loop performance, development metrics, or how the loop is doing.
context: fork
allowed-tools: Read, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.6.0
---

# Nazgul Metrics

## Examples
- `/nazgul:metrics` — View full metrics dashboard
- `/nazgul:metrics reviews` — Focus on reviewer stats

## Current State
- Config: !`cat nazgul/config.json 2>/dev/null | head -3 || echo "NOT_INITIALIZED"`
- Tasks dir: !`ls nazgul/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' '`
- Checkpoints retained (recovery only): !`ls nazgul/checkpoints/iteration-*.json 2>/dev/null | wc -l | tr -d ' '`
- Reviews dir: !`ls -d nazgul/reviews/TASK-*/ 2>/dev/null | wc -l | tr -d ' '`
- Budget (estimated): !`jq -r '(.budget | if type=="object" then . else {} end) | "enabled=\(.enabled // false) spent=$\(.spent_usd // 0) ceiling=\(.max_usd // "none")"' nazgul/config.json 2>/dev/null || echo "n/a"`
- Subagent runs: !`test -f nazgul/logs/subagents.jsonl && wc -l < nazgul/logs/subagents.jsonl 2>/dev/null | tr -d ' ' || echo 0`

## Arguments
$ARGUMENTS

## Instructions

Format all output per `references/ui-brand.md` — use stage banners, status symbols, progress bars, and display patterns defined there.

If Nazgul is not initialized, say so and stop.

If the typed arguments (`$ARGUMENTS`, the substituted value — not this literal block) are the standalone token `reviews`, display ONLY the Reviewer Stats section (skip Task Velocity, Approval Rate, Cost, Subagent Activity, and Loop Health). Otherwise render the full dashboard. When in `reviews` mode you only need to collect the Review files data (source 3) to compute and display Reviewer Stats.

### Collect Data

Read these sources to compute metrics:

1. **Task manifests** (`nazgul/tasks/TASK-*.md`):
   - Count by status: DONE, APPROVED, IN_PROGRESS, READY, CHANGES_REQUESTED, BLOCKED, PLANNED
   - For each task: count retry attempts (how many times status went to CHANGES_REQUESTED)
   - Extract claimed_at and completed_at timestamps for velocity

2. **Iteration log** (`nazgul/logs/iterations.jsonl`) — the durable, never-pruned per-iteration record (one JSON line each: `iteration`, `timestamp`, `done`, `total`, `git_sha`). Use this as the authoritative source for:
   - Total iterations run (max `.iteration`, or line count)
   - First and last iteration timestamps (for time span)

   NOTE: `nazgul/checkpoints/` is retention-limited (only the latest ~2 survive — they exist for recovery, not history), so do NOT count checkpoint files for iteration totals or time span. Use `iterations.jsonl`. Read the compaction count from `nazgul/.compaction_count` (or count `"event":"compaction"`-style markers in the log) rather than from checkpoints.

3. **Review files** (`nazgul/reviews/TASK-*/`):
   - For each task reviewed: count reviewer verdicts (APPROVED vs CHANGES_REQUESTED)
   - Per-reviewer stats: how many times each reviewer approved vs rejected
   - Consolidated feedback files: count blocking vs non-blocking findings

4. **Config** (`nazgul/config.json`):
   - Mode, max iterations, consecutive failures
   - Active reviewers list

5. **Budget** (`nazgul/config.json → budget`):
   - `spent_usd` (cumulative ESTIMATED spend for the current run), `max_usd` (ceiling, or null), `enabled`.
   - NOTE: this is the cost governor's *estimate* (≈ iterations × per-tier rate), NOT metered spend, and it resets per objective (`/nazgul:start`). Label it "estimated" and never present it as actual billing.

6. **Subagent log** (`nazgul/logs/subagents.jsonl`) — one `{event:"subagent_stop", agent, timestamp}` line per finished subagent:
   - Total subagent runs (line count).
   - Breakdown by `.agent` (counts per agent type, e.g. implementer, each reviewer, specialists). Use `jq -r .agent ... | sort | uniq -c` semantics.

7. **Learned rules** (`nazgul/learning/learned-rules.md`, if present) — read via `scripts/lib/learned-rules.sh parse` (one JSON object per rule):
   - Active rules: count of rules with `status == "active"`.
   - Retired rules: count of rules with `status == "retired"`.
   - Total citations: sum of `hits` across ALL rules (active + retired).
   - Top-cited: the active rules with the highest `hits` (id + title + hits).

### Compute Metrics

- **Task velocity**: tasks DONE / total iterations (tasks per iteration)
- **First-pass approval rate**: tasks approved on first review / total reviewed tasks
- **Retry distribution**: histogram of retry counts (0, 1, 2, 3)
- **Reviewer blocking rate**: per reviewer, rejections / total reviews
- **Avg iterations per task**: total iterations / tasks DONE
- **Time span**: first to last `timestamp` in `iterations.jsonl`
- **Estimated cost**: total `budget.spent_usd`; cost/task = `spent_usd / DONE`; cost/iteration = `spent_usd / total iterations`. When `max_usd` is set, also `spent / ceiling (NN%)`. If a denominator is 0 (no DONE tasks or no iterations yet), show `—` instead of dividing (never emit `Infinity`/`NaN`). (Estimate — see source 5.)
- **Subagent activity**: total subagent runs + per-agent-type counts (source 6)
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

Cost (estimated)
─────────────────────────────────────
  Est. spend:         $[spent]  [/ $[ceiling] ([%]) | (no ceiling) | (governor disabled)]
  Cost/task:          $[N.NN]
  Cost/iteration:     $[N.NN]
  (Estimate from the cost governor — not metered spend; resets per objective.)

Subagent Activity
─────────────────────────────────────
  Total runs:         [N]
  [agent-type]:       [N]
  [agent-type]:       [N]
  ...

Learning
─────────────────────────────────────
  Active rules:       [N]  ([R] retired)
  Total citations:    [N]
  Top-cited:          LR-NNN ([H] hits) — [title]
                      LR-NNN ([H] hits) — [title]

Loop Health
─────────────────────────────────────
  Consecutive failures: [N]
  Mode:                 [hitl/afk]
  Status:               [active/paused/complete]

────────────────────────────────────────────────────────
```

If specific data is missing, show a graceful placeholder for that section rather than erroring: no reviews yet → "No data"; **`budget.enabled` false** → "Cost: not tracked (budget governor disabled)"; **enabled but `spent_usd` is 0** → "Est. spend: $0 (no spend recorded yet this run)" — do NOT report an enabled governor as disabled (`spent_usd` resets to 0 on every `/nazgul:start`); `subagents.jsonl` absent/empty → "Subagent Activity: no data yet"; **`nazgul/learning/learned-rules.md` absent** → "Learning: no rules yet".
