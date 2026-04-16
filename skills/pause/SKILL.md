---
name: nazgul:pause
description: Gracefully pause the Nazgul autonomous loop at the next iteration boundary. Use when user says "pause nazgul", "stop the loop", "halt nazgul", or wants to pause work without losing progress.
context: fork
allowed-tools: Read, Write, Edit, Bash
metadata:
  author: Jose Mejia
  version: 1.2.2
---

# Nazgul Pause

## Examples
- `/nazgul:pause` — Pause the loop at the next iteration boundary

## Current State
- Config: !`cat nazgul/config.json 2>/dev/null || echo "NOT_INITIALIZED"`
- Paused: !`jq -r '.paused // false' nazgul/config.json 2>/dev/null || echo "unknown"`

## Instructions

Gracefully pause the Nazgul autonomous loop so it stops at the next iteration boundary.

### Step 1: Check Initialization

If the config shows "NOT_INITIALIZED":
- Output: "Nazgul not initialized. Run `/nazgul:init` first."
- Stop here.

### Step 2: Check Current Pause State

Read `nazgul/config.json` and check the `paused` field.

If already paused (`"paused": true`):
- Output: "Nazgul is already paused. Run `/nazgul:start` to resume."
- Stop here.

### Step 3: Set Pause Flag

Use `jq` to set `"paused": true` in `nazgul/config.json`:

```bash
jq '.paused = true' nazgul/config.json > nazgul/config.json.tmp && mv nazgul/config.json.tmp nazgul/config.json
```

### Step 4: Generate Handoff Document

After setting `paused: true`, generate `nazgul/HANDOFF.md` for human consumption:

1. Read `nazgul/config.json` for: iteration count, max iterations, mode, objective
2. Scan all `nazgul/tasks/TASK-*.md` files to gather status counts and details
3. Read any ADR files in `nazgul/docs/` for decisions made
4. Read blocked tasks for gotchas

Write `nazgul/HANDOFF.md`:

```markdown
# Nazgul Handoff — [date]

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
Run `/nazgul:start` — loop picks up from the current task.
Or `/nazgul:status` to review state before continuing.
```

If no tasks exist yet, write a minimal handoff:
```markdown
# Nazgul Handoff — [date]

## Status
Iteration [current]/[max] | Mode: [mode] | Paused at: [timestamp]
No tasks generated yet.

## To Resume
Run `/nazgul:start` to begin.
```

Use symbols: ✦ for done, ◆ for in-progress, ✗ for blocked.

### Step 5: Confirm

Output:
```
─── ◈ NAZGUL ▸ PAUSED ────────────────────────────────────

Handoff saved to nazgul/HANDOFF.md
Iteration [N]/[max] | [done] tasks done, [active] in flight

─── ◈ NEXT ─────────────────────────────────────────────
  /nazgul:start to resume
────────────────────────────────────────────────────────
```
