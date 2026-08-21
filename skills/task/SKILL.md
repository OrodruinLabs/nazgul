---
name: nazgul:task
description: Task lifecycle management — skip, unblock, add, prioritize, info, and list tasks. Use when you need to manage individual tasks in the Nazgul pipeline.
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
metadata:
  author: Jose Mejia
---

# Nazgul Task

## Examples
- `/nazgul:task` — List all tasks with status summary
- `/nazgul:task info TASK-003` — Show full details and review history for a task
- `/nazgul:task skip TASK-005` — Skip a task and promote unblocked downstream tasks
- `/nazgul:task unblock TASK-004` — Reset a blocked task back to READY
- `/nazgul:task add "Implement rate limiting"` — Create a new task
- `/nazgul:task prioritize TASK-006 --before TASK-003` — Reorder task execution

## Arguments
$ARGUMENTS

## Current State
- Task list: !`ls nazgul/tasks/TASK-*.md 2>/dev/null || echo "No tasks"`
- Plan: !`head -50 nazgul/plan.md 2>/dev/null || echo "No plan"`

## Instructions

Parse `$ARGUMENTS` for a subcommand and its parameters. If no subcommand is provided, default to `list`.

### Changing a task's status

**Every** status change goes through one command. A direct Write/Edit of a manifest's status field is
denied by `task-state-guard.sh`, and a status reached by `sed`, `cp`, `mv`, or a shell redirect is
quarantined as BLOCKED by the stop-hook's reconciliation pass (ADR-020) — validating a write is not the
same as completing one, so only a disk-verified write records authority.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh" transition TASK-NNN FROM TO
# BLOCKED only: append --reason "one line"
```

Name the exact live status as FROM — a stale FROM is rejected and nothing is written. Everything else in
a manifest (`- **Depends on**:`, `- **Blocked reason**:`, `- **Retry count**:`) is ordinary content you
edit directly, and must be written BEFORE the transition that depends on it. A non-zero exit means
nothing changed: read the stderr, fix the cause, re-run. Never `sed` a task manifest.

### Subcommands

---

#### `list` (default)

Produce a quick status table of all tasks:

```
Nazgul Tasks
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

1. Read each `nazgul/tasks/TASK-*.md` file
2. Extract: task ID, status, and the first line of the description
3. Sort by task ID (numeric order)
4. Format as the table above
5. Include a summary line at the bottom with counts by status category

---

#### `skip TASK-NNN`

Take a task out of the run without implementing or reviewing it.

A skipped task is recorded as `CANCELLED`: the operator has declared it unshippable. `CANCELLED` is
terminal like `DONE` — it has no out-edge — and it is explicitly NOT `BLOCKED`, which means "needs
human help, will resume". It satisfies the dependency gate, so downstream tasks promote on their own
and no `Depends on` line is ever edited (ADR-022).

1. Validate the task file exists: `nazgul/tasks/TASK-NNN.md`
2. If not found, error: "Task TASK-NNN not found."
3. Read the task's current status. If it is already `DONE` or `CANCELLED`, report that it is terminal
   and stop.
4. **Route by blocker class, BEFORE any manifest edit.** If the status is `BLOCKED`, read
   `- **Blocked kind**:` from the manifest.
   - Exactly `reconciliation` — do NOT skip, and write NOTHING to the manifest: no
     `- **Cancelled reason**:`, no other field. `ttg_validate_transition` refuses
     `BLOCKED -> CANCELLED` for a typed reconciliation quarantine, so a reason recorded first would
     document a cancellation that never happened — which reads to the next human as one that merely
     failed to save, and invites saving it by hand, which is the forgery route ADR-020 closed. Report:
     "TASK-NNN is in a reconciliation quarantine — cancellation is refused. Its only sanctioned exit
     is `${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh repair TASK-NNN`." Then stop.
   - any other value (`review-evidence`, `review-provenance`, `git-conflict`), or no `Blocked kind`
     line at all — an ordinary blocker; continue with the steps below. The guard matches the whole
     value, anchored and case-insensitively, so only the bare word `reconciliation` is refused and
     every other blocker class still cancels normally (RULES.md §2).
5. Record WHY, as ordinary non-status manifest content, BEFORE the transition — set
   `- **Cancelled reason**: [one line]` under `## Metadata`. `--reason` is rejected by the transition
   command for any target but `BLOCKED`, so the reason is written here or it is not written at all.
6. Record the skip:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh" transition TASK-NNN <CURRENT_STATUS> CANCELLED
```

   Step 4 is a precondition, not the enforcement: the same refusal is applied by the guard here, so a
   quarantine written after Step 4 is still caught. A non-zero exit means nothing was written — report
   the refusal verbatim and stop.
7. Do not promote anything by hand and do not edit any `- **Depends on**:` line: the plan graph is the
   record of what the plan was. The stop-hook auto-promotes each now-unblocked `PLANNED` task to
   `READY` on its next iteration.
8. Count the task manifests whose `- **Depends on**:` line names TASK-NNN — those are the downstream
   tasks this skip releases.
9. Output: "TASK-NNN skipped (recorded as CANCELLED). [N] downstream task(s) will auto-promote."

---

#### `unblock TASK-NNN`

Reset a BLOCKED task back to READY so it can be picked up by the loop.

1. Validate the task file exists: `nazgul/tasks/TASK-NNN.md`
2. If not found, error: "Task TASK-NNN not found."
3. If the status is `DONE` or `CANCELLED`, refuse: "TASK-NNN is [status], which is terminal — it has
   no transition back to READY." Stop; `unblock` cannot reverse a completed or cancelled task.
4. If the task is not BLOCKED, warn: "TASK-NNN is not blocked (current status: [status])."
5. **Route by blocker class.** Read `- **Blocked kind**:` from the manifest BEFORE doing anything else.
   - `reconciliation` — do NOT unblock. This is the stop-hook's integrity quarantine: the code and its
     review may be entirely intact, only the state provenance was lost, so sending it to `READY` would
     throw away reviewed work and re-run the implementer. Run
     `"${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh" repair TASK-NNN`, which revalidates the task's
     commits, red-run evidence, review verdicts, and review provenance and then records
     `BLOCKED -> IN_REVIEW -> DONE`. It never uses `READY` and never dispatches an implementer. If
     repair refuses, report its diagnostic verbatim and stop — do NOT fall back to unblock.
   - any other value (`review-evidence`, `review-provenance`, `git-conflict`), or no `Blocked kind`
     line at all — an ordinary blocker; continue with the steps below. `repair` will refuse these.
6. Clear the `- **Blocked reason**:` line and reset `- **Retry count**:` to `0/3`. Both are non-status
   content, so edit them directly, and do it BEFORE the transition.
7. Return it to the queue:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh" transition TASK-NNN BLOCKED READY
```

8. Output: "TASK-NNN unblocked and set to READY. It will be picked up in the next iteration."

---

#### `add "description"`

Create a new task manifest and append it to the plan.

1. Scan existing task files to determine the next available TASK-NNN number
2. Create `nazgul/tasks/TASK-NNN.md` with the following template:

Use the canonical field spellings below verbatim — `task-utils.sh` reads
`- **Retry count**:` and `ttg_validate_transition` requires exactly one
`- **Depends on**:` line before READY, so a renamed field reads as absent.

```markdown
---
status: PLANNED
---
# TASK-NNN: [description]

## Metadata
- **ID**: TASK-NNN
- **Status**: (see `status:` in the frontmatter block above — that is canonical)
- **Priority**: medium
- **Depends on**: [none, or the comma-separated canonical task ids from step 3]
- **Retry count**: 0/3
- **Created at**: [ISO 8601 timestamp]
- **Source**: manual (via /nazgul:task add)

## Description
[description]

## Acceptance Criteria
- [ ] TBD — define acceptance criteria

## Implementation Notes
_To be filled by implementer._
```

3. Resolve dependencies BEFORE choosing the initial status, and write what you resolved into
   `- **Depends on**:` in the same Write. Scan the description for task ids (`TASK-NNN`) and for
   prose naming a prerequisite; if any are found, record them comma-separated and keep the status
   `PLANNED`. Only when the description names none is `- **Depends on**: none` true, and only then
   write `READY` instead of `PLANNED` in that same initial Write. Never leave `none` standing on a
   task whose description names a prerequisite: `ttg_validate_transition` and the stop hook's
   PLANNED -> READY auto-promotion both read that field as the whole truth about the dependency
   graph, so an unrecorded prerequisite is not a looser gate — it is no gate.
   A brand-new manifest's FIRST status is not a transition —
   `task-state-guard.sh` permits an initial `PLANNED` or `READY` — so do not call the transition command
   here; there is no FROM status for it to compare against.
4. Append the task to `nazgul/plan.md` in the task list section
5. Output: "Created TASK-NNN: [description]. Status: [PLANNED|READY]."

---

#### `prioritize TASK-NNN --before TASK-MMM`

Reorder tasks in the plan so TASK-NNN appears before TASK-MMM.

1. Validate both task files exist
2. Read `nazgul/plan.md`
3. Find the lines referencing both tasks in the plan's task list
4. Remove TASK-NNN's line from its current position
5. Insert it immediately before TASK-MMM's line
6. Write the updated plan.md
7. Output: "TASK-NNN moved before TASK-MMM in the plan."

Note: This changes execution order but does NOT override dependency constraints. If TASK-NNN depends on TASK-MMM, warn the user about the circular dependency.

---

#### `info TASK-NNN`

Show full details for a specific task.

1. Validate the task file exists: `nazgul/tasks/TASK-NNN.md`
2. If not found, error: "Task TASK-NNN not found."
3. Read and display the full contents of `nazgul/tasks/TASK-NNN.md`
4. Check for review history: look for files matching `nazgul/reviews/TASK-NNN-*.md`
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

6. Check for delegation briefs: `nazgul/tasks/TASK-NNN-delegation.md`
7. If a delegation brief exists, include it in the output

---

### Error Handling

- If Nazgul is not initialized (no `nazgul/config.json`): "Nazgul not initialized. Run `/nazgul:init` first."
- If no tasks exist: "No tasks found. Run `/nazgul:start` to generate a plan."
- If an unknown subcommand is provided: "Unknown subcommand: [X]. Available: list, skip, unblock, add, prioritize, info"
