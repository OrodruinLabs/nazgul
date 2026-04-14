#!/usr/bin/env bash
set -euo pipefail

# Nazgul Pre-Compact Hook — checkpoint state before compaction
# Stdout becomes part of the compaction context summary

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
PLAN="$NAZGUL_DIR/plan.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/task-utils.sh"

# If Nazgul not active, nothing to do
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")
MODE=$(jq -r '.mode // "hitl"' "$CONFIG")

# Write checkpoint
mkdir -p "$NAZGUL_DIR/checkpoints"
CHECKPOINT="$NAZGUL_DIR/checkpoints/iteration-$(printf '%03d' "$ITERATION").json"

# Get active task
ACTIVE_TASK=""
ACTIVE_STATUS=""
ACTIVE_RETRY=0
if [ -d "$NAZGUL_DIR/tasks" ]; then
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file")
    if [ "$STATUS" = "IN_PROGRESS" ] || [ "$STATUS" = "CHANGES_REQUESTED" ] || [ "$STATUS" = "IN_REVIEW" ] || [ "$STATUS" = "IMPLEMENTED" ]; then
      ACTIVE_TASK=$(basename "$task_file" .md)
      ACTIVE_STATUS="$STATUS"
      ACTIVE_RETRY=$(grep -m1 '^\- \*\*Retry count\*\*:' "$task_file" 2>/dev/null | sed 's|.*: \([0-9]*\).*|\1|' || echo "0")
      break
    fi
  done
fi

# Count tasks by status (all 8 states)
DONE_COUNT=0
READY_COUNT=0
IN_PROGRESS_COUNT=0
IN_REVIEW_COUNT=0
APPROVED_COUNT=0
CHANGES_COUNT=0
BLOCKED_COUNT=0
PLANNED_COUNT=0
TOTAL_COUNT=0

if [ -d "$NAZGUL_DIR/tasks" ]; then
  for task_file in "$NAZGUL_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    STATUS=$(get_task_status "$task_file" "PLANNED")
    case "$STATUS" in
      DONE) DONE_COUNT=$((DONE_COUNT + 1)) ;;
      READY) READY_COUNT=$((READY_COUNT + 1)) ;;
      IN_PROGRESS) IN_PROGRESS_COUNT=$((IN_PROGRESS_COUNT + 1)) ;;
      IMPLEMENTED) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
      IN_REVIEW) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
      APPROVED) APPROVED_COUNT=$((APPROVED_COUNT + 1)) ;;
      CHANGES_REQUESTED) CHANGES_COUNT=$((CHANGES_COUNT + 1)) ;;
      BLOCKED) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
      PLANNED) PLANNED_COUNT=$((PLANNED_COUNT + 1)) ;;
    esac
  done
fi

# Capture files modified this iteration as a JSON array
FILES_MODIFIED_JSON=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" diff --name-only HEAD~1 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")

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
