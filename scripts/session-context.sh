#!/usr/bin/env bash
set -euo pipefail

# Nazgul Session Context — injects state on startup and after compaction
# Stdout is shown to the agent

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
PLAN="$NAZGUL_DIR/plan.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/task-utils.sh"
source "$SCRIPT_DIR/lib/session-tracker.sh"

# If Nazgul not initialized, nothing to inject
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Session tracking — register this session and warn on concurrent
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)-$$}"
SESSIONS_DIR="$NAZGUL_DIR/sessions"
# Persist generated session ID so stop-hook can unregister it
printf '%s' "$SESSION_ID" > "$NAZGUL_DIR/.session_id"
register_session "$SESSION_ID" "$SESSIONS_DIR"
cleanup_stale_sessions "$SESSIONS_DIR"
CONCURRENT_WARNING=""
if warning_msg=$(is_concurrent_session_warning "$SESSIONS_DIR"); then
  CONCURRENT_WARNING="$warning_msg"
fi

# Auto-migrate config to latest schema version
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
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

# Count tasks and find active task (shared helper; see task-utils.sh:145)
count_tasks_and_find_active "$NAZGUL_DIR/tasks"

# --- Telemetry-dark / stale plan.md detection (MF-060) ---
# Compares plan.md's declared "## Status Summary" counts against the counts
# just recomputed above. Catches an objective running outside the stop-hook
# loop (e.g. Agent-Team SendMessage fan-out), where plan.md's Status Summary
# and loop telemetry go stale/silent while the task manifests keep advancing
# underneath it — the exact condition this repo's own FEAT-013 audit run
# reproduced live. Detection-only and non-blocking: never rewrites plan.md
# (the orchestrator owns it) and never fails session start.
check_plan_staleness() {
  local plan_file="$1"
  local summary declared_total declared_planned declared_active actual_active
  local total_diff active_diff

  summary=$(awk '/^## Status Summary/{flag=1; next} /^## /{flag=0} flag' "$plan_file" 2>/dev/null) || true
  if [ -z "$summary" ]; then
    echo "WARNING: nazgul/plan.md has no parseable '## Status Summary' section — plan.md may be stale or the objective may be running outside the tracked loop (see MF-060)." >&2
    return 0
  fi

  declared_total=$(printf '%s\n' "$summary" | grep -m1 -oE 'Total tasks:[[:space:]]*[0-9]+' | grep -oE '[0-9]+') || true
  if [ -z "$declared_total" ]; then
    echo "WARNING: nazgul/plan.md's Status Summary has no parseable 'Total tasks: N' line — cannot verify against the ${TOTAL_COUNT} actual task manifest(s). Objective may be running outside the tracked loop (see MF-060)." >&2
    return 0
  fi

  declared_planned=$(printf '%s\n' "$summary" | grep -m1 -oE 'PLANNED:[[:space:]]*[0-9]+' | grep -oE '[0-9]+') || true
  declared_planned="${declared_planned:-0}"
  declared_active=$((declared_total - declared_planned))
  actual_active=$((TOTAL_COUNT - PLANNED_COUNT))

  if [ "$declared_total" -ge "$TOTAL_COUNT" ]; then
    total_diff=$((declared_total - TOTAL_COUNT))
  else
    total_diff=$((TOTAL_COUNT - declared_total))
  fi
  if [ "$declared_active" -ge "$actual_active" ]; then
    active_diff=$((declared_active - actual_active))
  else
    active_diff=$((actual_active - declared_active))
  fi

  # A drift of at most 1 (total count, or count of tasks that have left
  # PLANNED) is normal single-iteration lag between the last plan.md write and
  # this SessionStart. Beyond that — especially declared_active far below
  # actual_active, the exact all-PLANNED-but-really-in-progress symptom
  # MF-060 documents — is telemetry-dark and gets a loud, non-blocking flag.
  if [ "$total_diff" -gt 1 ] || [ "$active_diff" -gt 1 ]; then
    echo "WARNING: nazgul/plan.md's Status Summary is stale (declared: total=${declared_total} non-PLANNED=${declared_active} | actual: total=${TOTAL_COUNT} non-PLANNED=${actual_active}) — objective may be running outside the tracked loop (e.g. Agent-Team dispatch bypassing stop-hook.sh's recompute/emit). See MF-060." >&2
  fi
}

if [ -f "$PLAN" ]; then
  check_plan_staleness "$PLAN" || true
fi

# Git-hooks self-heal — first-time installs for an active loop that never
# went through its SKILL.md install call site, else re-asserts on drift;
# self_heal_git_hooks itself no-ops when guards.git_hooks is off or no
# objective is active (MF-034 defense-in-depth, see git-hooks.sh).
GIT_HOOKS_LIB="$PLUGIN_ROOT/scripts/lib/git-hooks.sh"
if [ -f "$GIT_HOOKS_LIB" ]; then
  # shellcheck source=./lib/git-hooks.sh
  source "$GIT_HOOKS_LIB"
  if declare -F self_heal_git_hooks >/dev/null 2>&1; then
    self_heal_git_hooks "$NAZGUL_DIR/.." "$CONFIG" || true
  fi
fi

# Compaction counter (GAP-008 context rot detection)
COMPACTION_FILE="$NAZGUL_DIR/.compaction_count"
HOOK_EVENT="${CLAUDE_HOOK_EVENT:-}"

# --- MF-012: idempotent compaction counter increment. This SessionStart
# (matcher=compact) fires AFTER post-compact.sh for the SAME physical
# compaction event (PreCompact -> compaction -> PostCompact -> SessionStart
# [compact], confirmed against the Claude Code hooks reference — see
# pre-compact.sh's reset comment and post-compact.sh's matching guard). A
# plain read-increment-write here as well as in post-compact.sh double-counts
# every compaction. The `mkdir` lock post-compact.sh claims first (it always
# runs first in the lifecycle) means this branch normally just skips its own
# increment; it still claims the lock itself as a defensive fallback in case
# PostCompact ever fails to run for a given compaction.
if [ "$HOOK_EVENT" = "compact" ]; then
  COMPACTION_LOCK="$NAZGUL_DIR/.compaction_count.lock"
  # Read current state or initialize
  if [ -f "$COMPACTION_FILE" ]; then
    PREV_COUNT=$(jq -r '.count // 0' "$COMPACTION_FILE" 2>/dev/null || echo "0")
  else
    PREV_COUNT=0
  fi
  if mkdir "$COMPACTION_LOCK" 2>/dev/null; then
    NEW_COUNT=$((PREV_COUNT + 1))
    # Write updated compaction state with current iteration
    printf '{"count": %d, "last_compaction_iteration": %s}\n' "$NEW_COUNT" "$ITERATION" > "$COMPACTION_FILE"
  fi
  # else: post-compact.sh already claimed and incremented for this compaction.
fi

# Read compaction count for output
if [ -f "$COMPACTION_FILE" ]; then
  COMPACTION_COUNT=$(jq -r '.count // 0' "$COMPACTION_FILE" 2>/dev/null || echo "0")
else
  COMPACTION_COUNT=0
fi

# Get latest checkpoint
LATEST_CHECKPOINT=$(ls -1t "$NAZGUL_DIR/checkpoints/iteration-"*.json 2>/dev/null | head -1 || echo "none")

# Get reviewers
REVIEWERS=$(jq -r '.agents.reviewers // [] | join(", ")' "$CONFIG" 2>/dev/null || echo "none configured")

# Git state
GIT_BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" branch --show-current 2>/dev/null || echo "unknown")
GIT_LAST=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" log --oneline -1 2>/dev/null || echo "unknown")

# Branch isolation state
FEATURE_BRANCH=$(jq -r '.branch.feature // ""' "$CONFIG" 2>/dev/null || echo "")
BASE_BRANCH=$(jq -r '.branch.base // ""' "$CONFIG" 2>/dev/null || echo "")
WORKTREE_DIR=$(jq -r '.branch.worktree_dir // ""' "$CONFIG" 2>/dev/null || echo "")
WORKTREE_COUNT=0
if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
  WORKTREE_COUNT=$(find "$WORKTREE_DIR" -maxdepth 1 -name 'TASK-*' -type d 2>/dev/null | wc -l | tr -d ' ')
fi

# Output context
cat << CONTEXT_EOF
Nazgul loop state — iteration ${ITERATION}/${MAX_ITER} | Mode: ${MODE} | Objective: ${OBJECTIVE}
Tasks: ${DONE_COUNT} done, ${APPROVED_COUNT} approved, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked | Total: ${TOTAL_COUNT}
Compactions: ${COMPACTION_COUNT}
CONTEXT_EOF

# Output Recovery Pointer if plan exists
if [ -f "$PLAN" ]; then
  echo ""
  sed -n '/^## Recovery Pointer/,/^## /p' "$PLAN" | head -7
fi

cat << CONTEXT_EOF2
$([ -n "$MIGRATION_NOTICE" ] && echo "NOTICE: $MIGRATION_NOTICE" || true)
Active task: ${ACTIVE_TASK:-none} (${ACTIVE_STATUS:-none})
$([ "$GRANULARITY" = "task" ] && [ "$ACTIVE_STATUS" = "IMPLEMENTED" ] && echo "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}. Do NOT skip the review gate." || true)
$([ "$GRANULARITY" = "task" ] && [ "$ACTIVE_STATUS" = "IN_REVIEW" ] && echo "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for ${ACTIVE_TASK}." || true)
$([ "$GRANULARITY" != "task" ] && { [ "$ACTIVE_STATUS" = "IMPLEMENTED" ] || [ "$ACTIVE_STATUS" = "IN_REVIEW" ]; } && echo "NOTE: review granularity is ${GRANULARITY} — do NOT spawn a single-task review-gate for ${ACTIVE_TASK}; it is parked pending the aggregate review unit (MF-008). Read nazgul/plan.md for aggregate-review readiness before dispatching." || true)
$([ "$ACTIVE_STATUS" = "READY" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "IN_PROGRESS" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "DELEGATE: Spawn implementer agent (nazgul:implementer) for ${ACTIVE_TASK}. Read consolidated feedback first." || true)
Reviewers: ${REVIEWERS}
$([ -n "$FEATURE_BRANCH" ] && echo "Branch: ${FEATURE_BRANCH} → ${BASE_BRANCH} | Worktrees: ${WORKTREE_COUNT}" || true)
Git: ${GIT_BRANCH} — ${GIT_LAST}
Latest checkpoint: ${LATEST_CHECKPOINT}
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "WARNING: Read nazgul/reviews/${ACTIVE_TASK}/consolidated-feedback.md for reviewer feedback." || true)
$([ -n "$CONCURRENT_WARNING" ] && echo "$CONCURRENT_WARNING" || true)

Read nazgul/plan.md for full state. Continue the Nazgul pipeline.
CONTEXT_EOF2
