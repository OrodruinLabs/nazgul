#!/usr/bin/env bash
set -euo pipefail

# Nazgul Pre-Compact Hook — checkpoint state before compaction
# Stdout becomes part of the compaction context summary

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
PLAN="$NAZGUL_DIR/plan.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/task-utils.sh"
source "$SCRIPT_DIR/lib/git-utils.sh"

# If Nazgul not active, nothing to do
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")
MODE=$(jq -r '.mode // "hitl"' "$CONFIG")

# Write checkpoint
mkdir -p "$NAZGUL_DIR/checkpoints"
CHECKPOINT="$NAZGUL_DIR/checkpoints/iteration-$(printf '%03d' "$ITERATION").json"

# Get active task + count tasks by status (all 8 states), shared helper
# (MF-009) — sets ACTIVE_TASK, ACTIVE_STATUS, ACTIVE_RETRY, DONE_COUNT,
# READY_COUNT, IN_PROGRESS_COUNT, IN_REVIEW_COUNT, APPROVED_COUNT,
# CHANGES_COUNT, BLOCKED_COUNT, PLANNED_COUNT, INVALID_COUNT, TOTAL_COUNT
count_tasks_and_find_active "$NAZGUL_DIR/tasks"

# Capture files modified this iteration as a JSON array. Robust against a
# single-commit repo (see scripts/lib/git-utils.sh) — a bare
# `git diff … | jq … || echo "[]"` emits "[]\n[]" under pipefail when HEAD~1
# is missing, breaking the downstream --argjson.
FILES_MODIFIED_JSON=$(files_modified_json "${CLAUDE_PROJECT_DIR:-$(pwd)}")

# Get git state
GIT_BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" branch --show-current 2>/dev/null || echo "unknown")
GIT_SHA=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_MSG=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" log --oneline -1 2>/dev/null | cut -c9- || echo "unknown")
GIT_DIRTY=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" diff --quiet 2>/dev/null && echo "false" || echo "true")

# Get active reviewers
ACTIVE_REVIEWERS=$(jq -c '.agents.reviewers // []' "$CONFIG" 2>/dev/null || echo "[]")

# Build active_task_id and active_task_status for jq
if [ -n "$ACTIVE_TASK" ]; then
  ACTIVE_TASK_ID="$ACTIVE_TASK"
  ACTIVE_TASK_STATUS="$ACTIVE_STATUS"
  NEXT_ACTION="Resume from Recovery Pointer in nazgul/plan.md"
else
  ACTIVE_TASK_ID=""
  ACTIVE_TASK_STATUS=""
  NEXT_ACTION=""
fi

# Write checkpoint JSON via jq (safe escaping for all string values)
jq -n \
  --argjson iteration "$ITERATION" \
  --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg mode "$MODE" \
  --arg active_task_id "$ACTIVE_TASK_ID" \
  --arg active_task_status "$ACTIVE_TASK_STATUS" \
  --argjson retry_count "$ACTIVE_RETRY" \
  --arg next_action "$NEXT_ACTION" \
  --argjson files_modified "$FILES_MODIFIED_JSON" \
  --argjson total_tasks "$TOTAL_COUNT" \
  --argjson done_count "$DONE_COUNT" \
  --argjson approved "$APPROVED_COUNT" \
  --argjson ready "$READY_COUNT" \
  --argjson in_progress "$IN_PROGRESS_COUNT" \
  --argjson in_review "$IN_REVIEW_COUNT" \
  --argjson changes_requested "$CHANGES_COUNT" \
  --argjson blocked "$BLOCKED_COUNT" \
  --argjson planned "$PLANNED_COUNT" \
  --arg git_branch "$GIT_BRANCH" \
  --arg git_sha "$GIT_SHA" \
  --arg git_msg "$GIT_MSG" \
  --argjson git_dirty "$GIT_DIRTY" \
  --argjson reviewers "$ACTIVE_REVIEWERS" \
  --arg recovery "Post-compaction: Read nazgul/plan.md Recovery Pointer, then nazgul/tasks/${ACTIVE_TASK:-none}.md" \
  '{
    iteration: $iteration,
    timestamp: $timestamp,
    mode: $mode,
    active_task: {
      id: (if $active_task_id == "" then null else $active_task_id end),
      status: (if $active_task_status == "" then null else $active_task_status end),
      retry_count: $retry_count,
      last_action: "Pre-compaction checkpoint",
      next_action: (if $next_action == "" then null else $next_action end),
      files_modified_this_iteration: $files_modified
    },
    plan_snapshot: {
      total_tasks: $total_tasks,
      done: $done_count,
      approved: $approved,
      ready: $ready,
      in_progress: $in_progress,
      in_review: $in_review,
      changes_requested: $changes_requested,
      blocked: $blocked,
      planned: $planned
    },
    git: {
      branch: $git_branch,
      last_commit_sha: $git_sha,
      last_commit_message: $git_msg,
      uncommitted_changes: $git_dirty
    },
    reviewers: {
      active: $reviewers
    },
    recovery_instructions: $recovery
  }' > "$CHECKPOINT"

# Output Recovery Pointer to stdout (survives compaction)
echo "=== NAZGUL RECOVERY STATE ==="
if [ -f "$PLAN" ]; then
  sed -n '/^## Recovery Pointer/,/^## /p' "$PLAN" | head -6
fi
echo ""
echo "Iteration: ${ITERATION} | Mode: ${MODE} | Tasks: ${DONE_COUNT}/${TOTAL_COUNT} done"
echo "Active task: ${ACTIVE_TASK:-none} (${ACTIVE_STATUS:-none})"
echo "=== END NAZGUL STATE ==="
