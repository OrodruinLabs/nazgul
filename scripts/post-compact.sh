#!/usr/bin/env bash
set -euo pipefail

# Nazgul Post-Compact — re-injects loop state after context compaction
# Fires AFTER compaction completes, BEFORE Claude responds.
# Stdout is shown to the agent as the first thing in the new context.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"
PROJECT_ROOT="$(resolve_project_root)"
NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"

# The ONE dispatch-brief preamble every DELEGATE line below reuses verbatim —
# every contract-bearing agent spec STOPs without <main_worktree_path>.
DISPATCH_BRIEF="Dispatch brief: <main_worktree_path> = ${PROJECT_ROOT}. Nazgul config: ${CONFIG}. Address every runtime-state path under that root, absolute and verbatim — your cwd is not it."
PLAN="$NAZGUL_DIR/plan.md"

source "$SCRIPT_DIR/lib/task-utils.sh"
source "$SCRIPT_DIR/lib/emit-event.sh"

# If Nazgul not initialized, nothing to inject
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# --- MF-050: mid-session schema migration. session-context.sh already does
# this on every SessionStart; PostCompact had no equivalent call, so a schema
# bump between session start and the next full session restart stayed stale
# for the rest of the session (bounded here to at most one PostCompact cycle).
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MIGRATE_SCRIPT="$PLUGIN_ROOT/scripts/migrate-config.sh"
MIGRATION_NOTICE=""
if [ -f "$MIGRATE_SCRIPT" ]; then
  MIGRATE_OUTPUT=$("$MIGRATE_SCRIPT" "$NAZGUL_DIR" 2>/dev/null) || true
  if [ -n "$MIGRATE_OUTPUT" ]; then
    MIGRATION_NOTICE="$MIGRATE_OUTPUT"
  fi
fi

MODE=$(jq -r '.mode // "hitl"' "$CONFIG")
OBJECTIVE=$(jq -r '.objective // "none"' "$CONFIG")
ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")
MAX_ITER=$(jq -r '.max_iterations // 40' "$CONFIG")

# MF-008: review granularity awareness, mirroring stop-hook.sh's read (its
# GRANULARITY var, ~line 51) — needed below to defer the single-task review
# dispatch suggestion to the aggregate review path in group/feature mode.
GRANULARITY=$(jq -r '.review_gate.granularity // "task"' "$CONFIG" 2>/dev/null || echo "task")
case "$GRANULARITY" in task|group|feature) ;; *) GRANULARITY="task" ;; esac

# Count tasks + find active task, shared helper (MF-009) — sets DONE_COUNT,
# READY_COUNT, IN_PROGRESS_COUNT, IN_REVIEW_COUNT, APPROVED_COUNT,
# CHANGES_COUNT, BLOCKED_COUNT, PLANNED_COUNT, INVALID_COUNT, TOTAL_COUNT,
# ACTIVE_TASK, ACTIVE_STATUS, ACTIVE_RETRY (PLANNED_COUNT/ACTIVE_RETRY unused
# here, same as before the repoint)
count_tasks_and_find_active "$NAZGUL_DIR/tasks"

# --- MF-012: idempotent compaction counter increment. PostCompact and
# SessionStart[matcher=compact] both fire once each, in that order, for the
# SAME physical compaction event (confirmed against the Claude Code hooks
# reference — see pre-compact.sh's reset comment). A plain read-increment-write
# in both hooks double-counts every compaction. A `mkdir` claim on a lock dir
# reset by pre-compact.sh at the START of each compaction cycle makes only the
# FIRST of the two hooks to run actually increment; the second (whichever it
# is) sees the claim already taken and treats the counter as read-only this
# cycle — no lost increment, no double count.
COMPACTION_FILE="$NAZGUL_DIR/.compaction_count"
COMPACTION_LOCK="$NAZGUL_DIR/.compaction_count.lock"
if [ -f "$COMPACTION_FILE" ]; then
  PREV_COUNT=$(jq -r '.count // 0' "$COMPACTION_FILE" 2>/dev/null || echo "0")
else
  PREV_COUNT=0
fi
if mkdir "$COMPACTION_LOCK" 2>/dev/null; then
  NEW_COUNT=$((PREV_COUNT + 1))
  printf '{"count": %d, "last_compaction_iteration": %s}\n' "$NEW_COUNT" "$ITERATION" > "$COMPACTION_FILE"
else
  # SessionStart[matcher=compact] already claimed this compaction's increment.
  NEW_COUNT="$PREV_COUNT"
fi

# Emit compaction to the telemetry bus (after counter write; pure observer).
# shellcheck disable=SC2034
CURRENT_ITERATION="$ITERATION"
emit_event "compaction" compaction_index:n "$NEW_COUNT" iteration_at_compact:n "$ITERATION"

# Get latest checkpoint
LATEST_CHECKPOINT=$(ls -1t "$NAZGUL_DIR/checkpoints/iteration-"*.json 2>/dev/null | head -1 || echo "none")

# Get reviewers
REVIEWERS=$(jq -r '.agents.reviewers // [] | join(", ")' "$CONFIG" 2>/dev/null || echo "none configured")

# Git state
GIT_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")
GIT_LAST=$(git -C "$PROJECT_ROOT" log --oneline -1 2>/dev/null || echo "unknown")

# Output recovery context
cat << CONTEXT_EOF
Nazgul loop state — iteration ${ITERATION}/${MAX_ITER} | Mode: ${MODE} | Objective: ${OBJECTIVE}
Tasks: ${DONE_COUNT} done, ${APPROVED_COUNT} approved, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked | Total: ${TOTAL_COUNT}
Compactions: ${NEW_COUNT}
CONTEXT_EOF

# Output Recovery Pointer if plan exists
if [ -f "$PLAN" ]; then
  echo ""
  sed -n '/^## Recovery Pointer/,/^## /p' "$PLAN" | head -7
fi

cat << CONTEXT_EOF2
$([ -n "$MIGRATION_NOTICE" ] && echo "NOTICE: $MIGRATION_NOTICE" || true)
Active task: ${ACTIVE_TASK:-none} (${ACTIVE_STATUS:-none})
$([ "$GRANULARITY" = "task" ] && [ "$ACTIVE_STATUS" = "IMPLEMENTED" ] && echo "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF} Do NOT skip the review gate." || true)
$([ "$GRANULARITY" = "task" ] && [ "$ACTIVE_STATUS" = "IN_REVIEW" ] && echo "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF}" || true)
$([ "$GRANULARITY" != "task" ] && { [ "$ACTIVE_STATUS" = "IMPLEMENTED" ] || [ "$ACTIVE_STATUS" = "IN_REVIEW" ]; } && echo "NOTE: review granularity is ${GRANULARITY} — do NOT spawn a single-task review-gate for ${ACTIVE_TASK}; it is parked pending the aggregate review unit (MF-008). Read nazgul/plan.md for aggregate-review readiness before dispatching." || true)
$([ "$ACTIVE_STATUS" = "READY" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF} Create-or-recover its worktree and pass the printed path as <task_worktree>: bash -c 'source \"${SCRIPT_DIR}/worktree-utils.sh\" && create_task_worktree ${ACTIVE_TASK} \"${PROJECT_ROOT}\" \"${CONFIG}\"'" || true)
$([ "$ACTIVE_STATUS" = "IN_PROGRESS" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF} Create-or-recover its worktree and pass the printed path as <task_worktree>: bash -c 'source \"${SCRIPT_DIR}/worktree-utils.sh\" && create_task_worktree ${ACTIVE_TASK} \"${PROJECT_ROOT}\" \"${CONFIG}\"'" || true)
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. ${DISPATCH_BRIEF} Read consolidated feedback first, and pass the retained <task_worktree> for this task." || true)
Reviewers: ${REVIEWERS}

Git: ${GIT_BRANCH} — ${GIT_LAST}
Latest checkpoint: ${LATEST_CHECKPOINT}
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "WARNING: Read nazgul/reviews/${ACTIVE_TASK}/consolidated-feedback.md for reviewer feedback." || true)

Read nazgul/plan.md for full state. Continue the Nazgul pipeline.
CONTEXT_EOF2
