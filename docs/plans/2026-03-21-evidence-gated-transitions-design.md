# Evidence-Gated Task State Transitions

**Date:** 2026-03-21
**Status:** Implemented
**Problem:** Loop engine does work without transitioning tasks through the state machine, then attempts batch retroactive transitions

## Problem Statement

During `/hydra:start` loops, the orchestrating agent sometimes:
1. Implements all tasks without transitioning any to IN_PROGRESS
2. Completes all work, then tries to batch-mark tasks as DONE
3. Gets blocked by the state guard (correctly), then mechanically walks each task through READY -> IN_PROGRESS -> IMPLEMENTED -> IN_REVIEW -> DONE without actually running reviews

The state guard catches invalid transitions but cannot distinguish between "legitimate work followed by a transition" and "mechanical state-walking with no real work." This is especially likely after context compaction, when the agent loses awareness of the task lifecycle protocol.

## Design

Two enforcement layers that make it structurally impossible to skip real work or real reviews.

### Layer 1: Evidence-Gated Transitions

Extend `task-state-guard.sh` to require **proof of work** for specific transitions.

#### IN_PROGRESS -> IMPLEMENTED: Requires commit SHA

**Rule:** The new task manifest content being written must contain at least one git commit SHA (7+ hex characters) in a `## Commits` or `## Implementation Log` section.

**Enforcement point:** `task-state-guard.sh`, after `valid_transition()` passes, before `exit 0`.

**Logic:**
```bash
if [ "$OLD_STATUS" = "IN_PROGRESS" ] && [ "$NEW_STATUS" = "IMPLEMENTED" ]; then
  # Check for commit SHA in the new content (7+ hex chars on a line with commit-like context)
  if ! echo "$NEW_CONTENT" | grep -qE '[0-9a-f]{7,40}'; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark IMPLEMENTED without a commit SHA" >&2
    echo "Add a ## Commits section with at least one commit hash to the task manifest." >&2
    echo "If you implemented the work, you should have committed it." >&2
    exit 2
  fi
fi
```

**Why this works:**
- The implementer agent already should record commits in the task manifest (step 9 of Implementation Protocol)
- A commit SHA can't be faked — it must reference a real git object
- If there's no commit, no work was done, so IMPLEMENTED is a lie
- Survives compaction: structural check, not instruction-dependent

**Edge case — single commit for multiple files:** Fine. The SHA just needs to exist. We're checking "did you do work and commit it," not "did you do enough work."

#### IMPLEMENTED -> IN_REVIEW: Requires review directory

**Rule:** The directory `hydra/reviews/TASK-NNN/` must exist before transitioning to IN_REVIEW.

**Enforcement point:** `task-state-guard.sh`, after `valid_transition()` passes.

**Logic:**
```bash
if [ "$OLD_STATUS" = "IMPLEMENTED" ] && [ "$NEW_STATUS" = "IN_REVIEW" ]; then
  REVIEW_DIR="$HYDRA_DIR/reviews/$TASK_ID"
  if [ ! -d "$REVIEW_DIR" ]; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot move to IN_REVIEW without a review directory" >&2
    echo "Expected: ${REVIEW_DIR}/" >&2
    echo "The review-gate agent creates this directory when it starts reviewing." >&2
    exit 2
  fi
fi
```

**Why this works:**
- The review-gate agent creates `hydra/reviews/TASK-NNN/` when it begins reviewing
- If the directory doesn't exist, no review process was started
- This prevents the "walk through all states" pattern — you can't get to IN_REVIEW without starting a real review
- The existing Check 1-4 for IN_REVIEW -> DONE already requires reviewer files with APPROVED verdicts inside that directory

**Already enforced (no changes needed):**
- IN_REVIEW -> DONE/APPROVED: requires all configured reviewers to have APPROVED files in `hydra/reviews/TASK-NNN/`

### Layer 2: No Source Edits Without IN_PROGRESS Task

Extend enforcement so that editing project source files is blocked unless at least one task is IN_PROGRESS.

**Enforcement point:** New check in `task-state-guard.sh` (or a new companion hook on Write/Edit that runs before the existing guard).

**Scope:** Any Write/Edit to files **outside** the `hydra/` directory.

**Logic:**
```bash
# --- ENFORCE ACTIVE TASK REQUIREMENT ---
# If editing files outside hydra/, require at least one IN_PROGRESS task

# Resolve hydra dir relative to git root
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
HYDRA_DIR_ABS=""
if [ -n "$GIT_ROOT" ]; then
  HYDRA_DIR_ABS="$GIT_ROOT/hydra"
fi

# Check if this file is outside hydra/
if [ -n "$HYDRA_DIR_ABS" ] && [[ "$FILE_PATH" != "$HYDRA_DIR_ABS"* ]]; then
  # Check if any task is IN_PROGRESS
  TASKS_DIR="$HYDRA_DIR_ABS/tasks"
  if [ -d "$TASKS_DIR" ]; then
    HAS_ACTIVE=false
    for task_file in "$TASKS_DIR"/TASK-*.md; do
      [ -f "$task_file" ] || continue
      STATUS=$(get_task_status "$task_file" "")
      if [ "$STATUS" = "IN_PROGRESS" ]; then
        HAS_ACTIVE=true
        break
      fi
    done
    if [ "$HAS_ACTIVE" = false ]; then
      echo "HYDRA STATE GUARD: BLOCKED — No task is IN_PROGRESS" >&2
      echo "Cannot edit source files without an active task." >&2
      echo "Transition a task to IN_PROGRESS before editing: $FILE_PATH" >&2
      exit 2
    fi
  fi
fi
```

**Why this works:**
- Prevents the root cause: doing all the work first without engaging the task lifecycle
- The agent is forced to claim a task (READY -> IN_PROGRESS) before touching any source files
- Survives compaction: even if the agent forgets task protocol, the guard enforces it structurally

**Exceptions — files that are always allowed:**
- Anything inside `hydra/` (config, plan, task manifests, reviews, checkpoints)
- When no `hydra/tasks/` directory exists (project hasn't been initialized with Hydra)

**Escape hatches:**
- `/hydra:patch` mode: sets a lightweight patch task to IN_PROGRESS, satisfying the guard
- Config flag: `hydra/config.json -> guards.requireActiveTask: false` disables Layer 2 for projects that find it too strict (default: `true`)

### Where Each Check Lives

| Transition | Evidence Required | Enforcement File |
|---|---|---|
| IN_PROGRESS -> IMPLEMENTED | Commit SHA in manifest | `task-state-guard.sh` |
| IMPLEMENTED -> IN_REVIEW | `hydra/reviews/TASK-NNN/` exists | `task-state-guard.sh` |
| IN_REVIEW -> DONE/APPROVED | All reviewers APPROVED | `task-state-guard.sh` (existing) |
| Any source file edit | >= 1 task IN_PROGRESS | `task-state-guard.sh` (new early check) |

## Files to Modify

1. **`scripts/task-state-guard.sh`** — Add evidence checks after `valid_transition()` and active-task check for non-hydra files
2. **`agents/implementer.md`** — Strengthen language: "You MUST commit before marking IMPLEMENTED. The guard will block you if you don't."
3. **`skills/start/SKILL.md`** — Add reminder: "Each task must be transitioned to IN_PROGRESS before implementation begins"
4. **`templates/CLAUDE.md.template`** — Mention evidence-gated transitions so target projects are aware

## Files NOT Modified

- `scripts/pre-tool-guard.sh` — Stays focused on destructive command blocking
- `scripts/stop-hook.sh` — Existing reactive safety net remains as-is
- `hooks/hooks.json` — No new hooks needed; existing PreToolUse on Write/Edit already routes to task-state-guard.sh

## Trade-offs

**Pros:**
- Structural enforcement that survives context compaction
- No new hooks or scripts — extends existing guard
- Each check is simple and debuggable
- Error messages tell the agent exactly what to do

**Cons:**
- Layer 2 adds friction for ad-hoc edits (mitigated by `/hydra:patch` and config flag)
- Commit SHA check is a loose heuristic (any 7+ hex chars match) — but false positives are harmless and false negatives are unlikely
- Scanning all task files on every source edit has a performance cost (mitigated: typically < 20 task files)

## Testing

- `tests/test-task-state-guard.sh` — Add cases for:
  - IN_PROGRESS -> IMPLEMENTED blocked without commit SHA
  - IN_PROGRESS -> IMPLEMENTED allowed with commit SHA in content
  - IMPLEMENTED -> IN_REVIEW blocked without review directory
  - IMPLEMENTED -> IN_REVIEW allowed with review directory
  - Source file edit blocked when no IN_PROGRESS task
  - Source file edit allowed when IN_PROGRESS task exists
  - Source file edit allowed when no hydra/tasks/ directory (not initialized)
  - Hydra file edit always allowed regardless of task state
  - Config flag `guards.requireActiveTask: false` disables Layer 2
