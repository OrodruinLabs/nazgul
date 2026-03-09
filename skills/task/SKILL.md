---
name: task
description: Task lifecycle management — skip, unblock, add, prioritize, info, and list tasks. Use when you need to manage individual tasks in the Hydra pipeline.
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
metadata:
  author: Jose Mejia
  version: 1.1.0
---

# Hydra Task

## Examples
- `/hydra:task` — List all tasks with status summary
- `/hydra:task info TASK-003` — Show full details and review history for a task
- `/hydra:task skip TASK-005` — Skip a task and promote unblocked downstream tasks
- `/hydra:task unblock TASK-004` — Reset a blocked task back to READY
- `/hydra:task add "Implement rate limiting"` — Create a new task
- `/hydra:task prioritize TASK-006 --before TASK-003` — Reorder task execution

## Arguments
$ARGUMENTS

## Current State
- Task list: !`ls hydra/tasks/TASK-*.md 2>/dev/null || echo "No tasks"`
- Plan: !`head -50 hydra/plan.md 2>/dev/null || echo "No plan"`

## Instructions

Parse `$ARGUMENTS` for a subcommand and its parameters. If no subcommand is provided, default to `list`.

### Subcommands

---

#### `list` (default)

Produce a quick status table of all tasks:

```
Hydra Tasks
═══════════════════════════════════════════════════════════
ID         Status              Description
─────────────────────────────────────────────────────────
TASK-001   DONE                Set up project scaffolding
TASK-002   IN_PROGRESS         Implement auth module
TASK-003   READY               Add payment processing
TASK-004   BLOCKED             Deploy to staging
TASK-005   PLANNED             Write integration tests
─────────────────────────────────────────────────────────
Total: 5 | Done: 1 | Active: 2 | Blocked: 1 | Planned: 1
```

1. Read each `hydra/tasks/TASK-*.md` file
2. Extract: task ID, status, and the first line of the description
3. Sort by task ID (numeric order)
4. Format as the table above
5. Include a summary line at the bottom with counts by status category

---

#### `skip TASK-NNN`

Set the specified task's status to SKIPPED.

1. Validate the task file exists: `hydra/tasks/TASK-NNN.md`
2. If not found, error: "Task TASK-NNN not found."
3. Use sed to update the `Status:` field to `SKIPPED` in the task manifest
4. Scan all other task manifests for dependencies that reference TASK-NNN
5. For any task whose ONLY remaining non-DONE/non-SKIPPED dependency was TASK-NNN, promote its status from `PLANNED` to `READY`
6. Output: "TASK-NNN set to SKIPPED. [N] downstream task(s) promoted to READY."

---

#### `unblock TASK-NNN`

Reset a BLOCKED task back to READY so it can be picked up by the loop.

1. Validate the task file exists: `hydra/tasks/TASK-NNN.md`
2. If not found, error: "Task TASK-NNN not found."
3. If the task is not BLOCKED, warn: "TASK-NNN is not blocked (current status: [status])."
4. Update `Status:` to `READY`
5. Clear the `blocked_reason:` field (set to empty or remove the line)
6. Reset `retry:` count to `0/3`
7. Output: "TASK-NNN unblocked and set to READY. It will be picked up in the next iteration."

---

#### `add "description"`

Create a new task manifest and append it to the plan.

1. Scan existing task files to determine the next available TASK-NNN number
2. Create `hydra/tasks/TASK-NNN.md` with the following template:

```markdown
# TASK-NNN: [description]

- **Status:** PLANNED
- **Priority:** medium
- **Dependencies:** none
- **Retry:** 0/3
- **Created:** [ISO 8601 timestamp]
- **Source:** manual (via /hydra:task add)

## Description
[description]

## Acceptance Criteria
- [ ] TBD — define acceptance criteria

## Implementation Notes
_To be filled by implementer._
```

3. If there are no dependencies (check if any were specified in the description), set status to `READY` instead of `PLANNED`
4. Append the task to `hydra/plan.md` in the task list section
5. Output: "Created TASK-NNN: [description]. Status: [PLANNED|READY]."

---

#### `prioritize TASK-NNN --before TASK-MMM`

Reorder tasks in the plan so TASK-NNN appears before TASK-MMM.

1. Validate both task files exist
2. Read `hydra/plan.md`
3. Find the lines referencing both tasks in the plan's task list
4. Remove TASK-NNN's line from its current position
5. Insert it immediately before TASK-MMM's line
6. Write the updated plan.md
7. Output: "TASK-NNN moved before TASK-MMM in the plan."

Note: This changes execution order but does NOT override dependency constraints. If TASK-NNN depends on TASK-MMM, warn the user about the circular dependency.

---

#### `info TASK-NNN`

Show full details for a specific task.

1. Validate the task file exists: `hydra/tasks/TASK-NNN.md`
2. If not found, error: "Task TASK-NNN not found."
3. Read and display the full contents of `hydra/tasks/TASK-NNN.md`
4. Check for review history: look for files matching `hydra/reviews/TASK-NNN-*.md`
5. If review files exist, display them in chronological order:

```
Task Details
═══════════════════════════════════════
[full task manifest contents]

Review History
─────────────────────────────────────
[review 1 contents]
[review 2 contents]
...
```

6. Check for delegation briefs: `hydra/tasks/TASK-NNN-delegation.md`
7. If a delegation brief exists, include it in the output

---

### Error Handling

- If Hydra is not initialized (no `hydra/config.json`): "Hydra not initialized. Run `/hydra:init` first."
- If no tasks exist: "No tasks found. Run `/hydra:start` to generate a plan."
- If an unknown subcommand is provided: "Unknown subcommand: [X]. Available: list, skip, unblock, add, prioritize, info"
