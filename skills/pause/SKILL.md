---
name: hydra:pause
description: Gracefully pause the Hydra autonomous loop at the next iteration boundary. Use when user says "pause hydra", "stop the loop", "halt hydra", or wants to pause work without losing progress.
context: fork
allowed-tools: Read, Write, Edit, Bash
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Pause

## Examples
- `/hydra:pause` — Pause the loop at the next iteration boundary

## Current State
- Config: !`cat hydra/config.json 2>/dev/null || echo "NOT_INITIALIZED"`
- Paused: !`jq -r '.paused // false' hydra/config.json 2>/dev/null || echo "unknown"`

## Instructions

Gracefully pause the Hydra autonomous loop so it stops at the next iteration boundary.

### Step 1: Check Initialization

If the config shows "NOT_INITIALIZED":
- Output: "Hydra not initialized. Run `/hydra:init` first."
- Stop here.

### Step 2: Check Current Pause State

Read `hydra/config.json` and check the `paused` field.

If already paused (`"paused": true`):
- Output: "Hydra is already paused. Run `/hydra:start` to resume."
- Stop here.

### Step 3: Set Pause Flag

Use `jq` to set `"paused": true` in `hydra/config.json`:

```bash
jq '.paused = true' hydra/config.json > hydra/config.json.tmp && mv hydra/config.json.tmp hydra/config.json
```

### Step 4: Generate Handoff Document

After setting `paused: true`, generate `hydra/HANDOFF.md` for human consumption:

1. Read `hydra/config.json` for: iteration count, max iterations, mode, objective
2. Scan all `hydra/tasks/TASK-*.md` files to gather status counts and details
3. Read any ADR files in `hydra/docs/` for decisions made
4. Read blocked tasks for gotchas

Write `hydra/HANDOFF.md`:

```markdown
# Hydra Handoff — [date]

## Status
Iteration [current]/[max] | Mode: [hitl/afk] | Paused at: [timestamp]

## Objective
[current objective from config]

## What's Done
[List each DONE task with ✦ symbol]
- ✦ TASK-001: [title]
- ✦ TASK-002: [title]

## What's In Flight
[List IN_PROGRESS and IN_REVIEW tasks with ◆ symbol and context]
- ◆ TASK-007: [title] — [brief status from implementation log]
- ◆ TASK-008: [title] — in review, awaiting [reviewer name]

## Decisions Made
[List ADRs or key decisions from task manifests]
- ADR-001: [title]
- ADR-002: [title]

## Blockers & Gotchas
[List BLOCKED tasks with ✗ symbol and reasons]
- ✗ TASK-009: [title] — [blocked reason]

## To Resume
Run `/hydra:start` — loop picks up from the current task.
Or `/hydra:status` to review state before continuing.
```

If no tasks exist yet, write a minimal handoff:
```markdown
# Hydra Handoff — [date]

## Status
Iteration [current]/[max] | Mode: [mode] | Paused at: [timestamp]
No tasks generated yet.

## To Resume
Run `/hydra:start` to begin.
```

Use symbols: ✦ for done, ◆ for in-progress, ✗ for blocked.

### Step 5: Confirm

Output:
```
─── ◈ HYDRA ▸ PAUSED ────────────────────────────────────

Handoff saved to hydra/HANDOFF.md
Iteration [N]/[max] | [done] tasks done, [active] in flight

─── ◈ NEXT ─────────────────────────────────────────────
  /hydra:start to resume
────────────────────────────────────────────────────────
```
