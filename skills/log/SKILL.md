---
name: hydra:log
description: View Hydra run history — iteration timeline, task completions, review verdicts, git commits. Use after an overnight run to see what happened.
context: fork
allowed-tools: Read, Bash, Glob
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Log

## Examples
- `/hydra:log` — View unified timeline of all Hydra activity (iterations, commits, reviews)

## Current State
- Iteration logs: !`tail -20 hydra/logs/iterations.jsonl 2>/dev/null || echo "No iteration logs"`
- Recent commits: !`git log --oneline --grep="$(jq -r '.afk.commit_prefix // "feat("' hydra/config.json 2>/dev/null)" -20 2>/dev/null || echo "No commits found"`
- Checkpoints: !`ls -1t hydra/checkpoints/iteration-*.json 2>/dev/null | head -5 || echo "No checkpoints"`

## Instructions

Build a unified timeline from all Hydra activity sources and present it as a formatted run history.

### Step 1: Parse All Sources

Gather events from the preprocessor data above. Each source provides different event types:

1. **Iteration logs** (`hydra/logs/iterations.jsonl`): Each line is a JSON object with `timestamp`, `iteration`, `task_id`, `action`, `result`. These are the primary timeline markers.

2. **Git commits** (filtered by commit prefix from config): Commits with the configured prefix represent state changes committed to disk. Read `afk.commit_prefix` from config to determine the grep pattern. Extract the timestamp, short hash, and message.

3. **Checkpoints** (`hydra/checkpoints/iteration-*.json`): Each file captures a full snapshot at an iteration boundary. Read the latest 5 for context recovery info.

### Step 2: Build Unified Timeline

Merge all events into a single list sorted by timestamp (oldest first). For each event, format as:

```
[HH:MM:SS] [TYPE]  [details]
```

### Step 3: Output Formatted Timeline

```
Hydra Run Log
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

### Step 4: Handle Edge Cases

- If no iteration logs exist: check if there are at least git commits. Show whatever is available.
- If nothing exists at all: "No Hydra activity recorded yet. Run `/hydra:start` to begin."
- If checkpoints exist but no logs: reconstruct a partial timeline from checkpoint data, noting gaps.

### Step 5: Additional Detail (if few events)

If the total number of events is small (< 20), also include:
- The contents of the most recent checkpoint (parsed as a summary, not raw JSON)
- Any blocker or error details in full
