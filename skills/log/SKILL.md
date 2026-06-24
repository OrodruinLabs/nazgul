---
name: nazgul:log
description: View Nazgul run history — iteration timeline, task completions, review verdicts, git commits. Use after an overnight run to see what happened.
context: fork
allowed-tools: Read, Bash, Glob
metadata:
  author: Jose Mejia
  version: 2.1.0
---

# Nazgul Log

## Examples
- `/nazgul:log` — View unified timeline of all Nazgul activity (iterations, commits, reviews)

## Current State
- Events bus: !`if [ -s nazgul/logs/events.jsonl ]; then echo "present"; else echo "absent"; fi`
- Events (last 20): !`if [ -s nazgul/logs/events.jsonl ]; then tail -20 nazgul/logs/events.jsonl; else echo "No events"; fi`
- Legacy iterations (last 20): !`tail -20 nazgul/logs/iterations.jsonl 2>/dev/null || echo "No legacy iteration logs"`
- Recent commits: !`git log --oneline --grep="$(jq -r '.afk.commit_prefix // "feat("' nazgul/config.json 2>/dev/null)" -20 2>/dev/null || echo "No commits found"`
- Checkpoints: !`ls -1t nazgul/checkpoints/iteration-*.json 2>/dev/null | head -2 || echo "No checkpoints"`

## Instructions

Build a unified timeline from all Nazgul activity sources and present it as a formatted run history.

### Step 1: Select Timeline Source (TIMELINE_SOURCE)

Set `TIMELINE_SOURCE` based on whether the events bus is available:

- **`TIMELINE_SOURCE=events`**: `nazgul/logs/events.jsonl` is present and non-empty (the "Events bus" line shows "present"). Use it as the primary timeline spine. The unified stream is already multi-event-type and sorted: `jq -sc 'sort_by(.ts)[]' nazgul/logs/events.jsonl`.

- **`TIMELINE_SOURCE=legacy`**: `events.jsonl` is absent/empty. Fall back to `nazgul/logs/iterations.jsonl`. These lines are heterogeneous in shape — iteration-boundary lines carry `iteration`, `timestamp`, `active_task`, `status`, `done`, `total`, `git_sha`, `blocked_reason`; some lines from other writers carry an `event` field (e.g. `stop_failure`, `task_completed`) plus `timestamp`. Use the `timestamp` field for sorting regardless of shape.

In either mode, also collect git commits and checkpoints as supplemental sources (steps 2–3 below).

**V1 gaps (events source):** When `TIMELINE_SOURCE=events`, note these known gaps in the event stream:
- `task_completed` events carry `task_id:"unknown"` — the TaskCompleted hook payload does not expose reliable task identity (CONCERN 2). Display the event but note the missing task ID.
- Most task state transitions (READY→IN_PROGRESS, IMPLEMENTED→IN_REVIEW, IN_REVIEW→DONE) are NOT captured as `task_transition` events in v1. They are bounded by `reviewer_verdict` + the next `iteration_boundary`. The timeline will not show these intermediate state changes.

### Step 2: Collect Supplemental Sources

2. **Git commits** (filtered by commit prefix from config): Commits with the configured prefix represent state changes committed to disk. Read `afk.commit_prefix` from config to determine the grep pattern. Extract the timestamp, short hash, and message.

3. **Checkpoints** (`nazgul/checkpoints/iteration-*.json`): Each file captures a full snapshot at an iteration boundary. Checkpoints are **retention-limited** (only the latest ~2 survive — they exist for recovery, not full history), so read the most recent for context-recovery detail and rely on the active timeline source (step 1) for the full history.

### Step 3: Build Unified Timeline

Merge all events into a single list sorted by timestamp (oldest first). For each event, format as:

```
[HH:MM:SS] [TYPE]  [details]
```

Map event types to display TYPE labels:

| Event type (bus) | Legacy equivalent | Display TYPE |
|---|---|---|
| `iteration_boundary` | iteration-boundary lines | ITERATION |
| `task_completed` | `task_completed` lines | TASK (task_id may show "unknown" — v1 gap) |
| `reviewer_verdict` | — | VERDICT |
| `retry` | — | RETRY |
| `blocked` | — | BLOCKED |
| `compaction` | `.compaction_count` | COMPACT |
| `subagent_stop` | — | AGENT |
| `stop_failure` | `stop_failure` lines | ERROR |
| `budget_threshold` | — | BUDGET |
| `objective_complete` | — | COMPLETE |

### Step 4: Output Formatted Timeline

```
Nazgul Run Log
═══════════════════════════════════════════════════════════

[YYYY-MM-DD]
─────────────────────────────────────────────────────────
[14:30:01] ITERATION   #1 started
[14:30:05] TASK        TASK-001 → IN_PROGRESS
[14:31:12] COMMIT      abc1234 feat(FEAT-003): implement auth module
[14:31:15] TASK        TASK-001 → IMPLEMENTED
[14:31:16] REVIEW      TASK-001 review started (3 reviewers)
[14:32:00] VERDICT     TASK-001 APPROVED (qa: 92, perf: 85, type: 88)
[14:32:01] TASK        TASK-001 → DONE
[14:32:02] ITERATION   #1 completed

[14:32:05] ITERATION   #2 started
[14:32:08] TASK        TASK-002 → IN_PROGRESS
[14:33:45] COMMIT      def5678 feat(FEAT-003): add payment routes
[14:33:50] TASK        TASK-002 → IMPLEMENTED
[14:33:51] REVIEW      TASK-002 review started (3 reviewers)
[14:34:30] VERDICT     TASK-002 CHANGES_REQUESTED (qa: 75, perf: 60)
[14:34:31] TASK        TASK-002 → CHANGES_REQUESTED
[14:34:32] ITERATION   #2 completed (with feedback)

[14:34:35] ITERATION   #3 started
[14:34:38] TASK        TASK-002 → IN_PROGRESS (retry 1/3)
...

─────────────────────────────────────────────────────────

Summary
═══════════════════════════════════════════════════════════
Time span:        14:30:01 — 15:45:22 (1h 15m)
Iterations:       8 completed
Tasks completed:  5 / 7
Tasks blocked:    1 (TASK-006: missing API key)
Reviews:          12 total (9 approved, 3 changes requested)
Commits:          14
Errors:           0
```

### Step 5: Handle Edge Cases

- If no iteration logs exist: check if there are at least git commits. Show whatever is available.
- If nothing exists at all: "No Nazgul activity recorded yet. Run `/nazgul:start` to begin."
- If checkpoints exist but no logs: reconstruct a partial timeline from checkpoint data, noting gaps.

### Step 6: Additional Detail (if few events)

If the total number of events is small (< 20), also include:
- The contents of the most recent checkpoint (parsed as a summary, not raw JSON)
- Any blocker or error details in full
