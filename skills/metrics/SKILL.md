---
name: nazgul:metrics
description: View loop performance metrics — task velocity, approval rates, retry distribution, reviewer stats. Use when asked about loop performance, development metrics, or how the loop is doing.
context: fork
allowed-tools: Read, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 2.1.0
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
- Events bus: !`if [ -s nazgul/logs/events.jsonl ]; then echo "present ($(wc -l < nazgul/logs/events.jsonl | tr -d ' ') events)"; else echo "absent"; fi`
- Legacy iterations: !`test -f nazgul/logs/iterations.jsonl && wc -l < nazgul/logs/iterations.jsonl 2>/dev/null | tr -d ' ' || echo 0`
- Legacy subagent runs: !`test -f nazgul/logs/subagents.jsonl && wc -l < nazgul/logs/subagents.jsonl 2>/dev/null | tr -d ' ' || echo 0`

## Arguments
$ARGUMENTS

## Instructions

Format all output per `references/ui-brand.md` — use stage banners, status symbols, progress bars, and display patterns defined there.

If Nazgul is not initialized, say so and stop.

If the typed arguments (`$ARGUMENTS`, the substituted value — not this literal block) are the standalone token `reviews`, display ONLY the Reviewer Stats section (skip Task Velocity, Approval Rate, Cost, Subagent Activity, and Loop Health). Otherwise render the full dashboard. When in `reviews` mode you only need to collect the Review files data (source 3) and the events bus (source 2) to compute and display Reviewer Stats.

### Collect Data

**Telemetry source selection (dual-read):** Check whether `nazgul/logs/events.jsonl` is present and non-empty (the "Events bus" line in Current State indicates this). Use tolerant parsing: `jq -sc '[.[]|select(.event!=null)]' nazgul/logs/events.jsonl 2>/dev/null || true`. If `events.jsonl` is present and non-empty, it is the authoritative source for sources 2, 5, and 6 below. If absent or empty, fall back to the legacy files for those sources (frozen pre-upgrade history).

Read these sources to compute metrics:

1. **Task manifests** (`nazgul/tasks/TASK-*.md`):
   - Count by status: DONE, APPROVED, IN_PROGRESS, READY, CHANGES_REQUESTED, BLOCKED, PLANNED
   - For each task: count retry attempts (how many times status went to CHANGES_REQUESTED)
   - Extract claimed_at and completed_at timestamps for velocity

2. **Telemetry bus** (`nazgul/logs/events.jsonl`) — **preferred** when present and non-empty:
   - Iteration count: `jq -sc '[.[]|select(.event=="iteration_boundary")]|length' nazgul/logs/events.jsonl`
   - Compaction count: `jq -sc '[.[]|select(.event=="compaction")]|length' nazgul/logs/events.jsonl`
   - First and last iteration timestamps: filter `iteration_boundary` events, read `.ts` from first and last
   - Budget spend (latest cumulative estimate): `jq -sc '[.[]|select(.event=="iteration_boundary" and .budget_spent_usd!=null)]|last|.budget_spent_usd // 0' nazgul/logs/events.jsonl`

   **Legacy fallback** (when `events.jsonl` is absent/empty — frozen pre-upgrade history):
   - Use `nazgul/logs/iterations.jsonl` for iteration count (max `.iteration` or line count), first/last timestamps
   - Read compaction count from `nazgul/.compaction_count`
   - NOTE: `nazgul/checkpoints/` is retention-limited (only the latest ~2 survive — they exist for recovery, not history), so do NOT count checkpoint files for iteration totals or time span.

3. **Review files** (`nazgul/reviews/TASK-*/`):
   - For each task reviewed: count reviewer verdicts (APPROVED vs CHANGES_REQUESTED)
   - Per-reviewer stats: how many times each reviewer approved vs rejected
   - Consolidated feedback files: count blocking vs non-blocking findings
   - **Supplemental from bus (when present):** `jq -sc '[.[]|select(.event=="reviewer_verdict")]|group_by(.reviewer)|map({reviewer:.[0].reviewer,approved:(map(select(.decision=="APPROVE"))|length),rejected:(map(select(.decision=="CHANGES_REQUESTED"))|length)})' nazgul/logs/events.jsonl` — use to cross-check or fill gaps when review files are sparse. Full reviewer-finding breakdowns still read `nazgul/reviews/` files in v1.

4. **Config** (`nazgul/config.json`):
   - Mode, max iterations, consecutive failures
   - Active reviewers list

5. **Budget** — **preferred from bus** when `events.jsonl` is present and non-empty:
   - Latest `budget_spent_usd` from the most recent `iteration_boundary` event (cumulative estimate)
   - `max_usd` and `enabled` still read from `nazgul/config.json → budget`
   - NOTE: this is the cost governor's *estimate*, NOT metered spend, and it resets per objective (`/nazgul:start`). Label it "estimated" and never present it as actual billing.

   **Legacy fallback** (when `events.jsonl` is absent/empty):
   - `spent_usd` (cumulative ESTIMATED spend for the current run), `max_usd` (ceiling, or null), `enabled` from `nazgul/config.json → budget`
   - NOTE: label as "estimated" — not metered spend; resets per objective.

6. **Subagent activity** — **preferred from bus** when `events.jsonl` is present and non-empty:
   - Total subagent runs: `jq -sc '[.[]|select(.event=="subagent_stop")]|length' nazgul/logs/events.jsonl`
   - Breakdown by `.agent`: `jq -sc '[.[]|select(.event=="subagent_stop")]|group_by(.agent)|map({agent:.[0].agent,count:length})' nazgul/logs/events.jsonl`

   **Legacy fallback** (when `events.jsonl` is absent/empty):
   - Use `nazgul/logs/subagents.jsonl` — one `{event:"subagent_stop", agent, timestamp}` line per finished subagent
   - Total subagent runs (line count), breakdown by `.agent`

7. **Learned rules** (`nazgul/learning/learned-rules.md`, if present) — read via `${CLAUDE_PLUGIN_ROOT}/scripts/lib/learned-rules.sh parse` (one JSON object per rule):
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
- **Time span**: first to last timestamp in the active telemetry source
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

If specific data is missing, show a graceful placeholder for that section rather than erroring: no reviews yet → "No data"; **`budget.enabled` false** → "Cost: not tracked (budget governor disabled)"; **enabled but `spent_usd` is 0** → "Est. spend: $0 (no spend recorded yet this run)" — do NOT report an enabled governor as disabled (`spent_usd` resets to 0 on every `/nazgul:start`); subagent data absent/empty → "Subagent Activity: no data yet"; **`nazgul/learning/learned-rules.md` absent** → "Learning: no rules yet".
