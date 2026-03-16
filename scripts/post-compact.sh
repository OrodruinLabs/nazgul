#!/usr/bin/env bash
set -euo pipefail

# Hydra Post-Compact — re-injects loop state after context compaction
# Fires AFTER compaction completes, BEFORE Claude responds.
# Stdout is shown to the agent as the first thing in the new context.

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"
PLAN="$HYDRA_DIR/plan.md"

# If Hydra not initialized, nothing to inject
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Helper: extract status from task manifest (supports both formats)
get_task_status() {
  grep -m1 -E '(^\- \*\*Status\*\*:|^## Status:)' "$1" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "${2:-}"
}

MODE=$(jq -r '.mode // "hitl"' "$CONFIG")
OBJECTIVE=$(jq -r '.objective // "none"' "$CONFIG")
ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")
MAX_ITER=$(jq -r '.max_iterations // 40' "$CONFIG")

# Count tasks
DONE_COUNT=0
READY_COUNT=0
IN_PROGRESS_COUNT=0
IN_REVIEW_COUNT=0
APPROVED_COUNT=0
CHANGES_COUNT=0
BLOCKED_COUNT=0
TOTAL_COUNT=0
ACTIVE_TASK=""
ACTIVE_STATUS=""

if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    STATUS=$(get_task_status "$task_file" "PLANNED")
    case "$STATUS" in
      DONE) DONE_COUNT=$((DONE_COUNT + 1)) ;;
      READY) READY_COUNT=$((READY_COUNT + 1)) ;;
      IN_PROGRESS) IN_PROGRESS_COUNT=$((IN_PROGRESS_COUNT + 1)) ;;
      IN_REVIEW|IMPLEMENTED) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
      APPROVED) APPROVED_COUNT=$((APPROVED_COUNT + 1)) ;;
      CHANGES_REQUESTED) CHANGES_COUNT=$((CHANGES_COUNT + 1)) ;;
      BLOCKED) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
    esac
    if [ -z "$ACTIVE_TASK" ]; then
      if [ "$STATUS" = "IN_PROGRESS" ] || [ "$STATUS" = "CHANGES_REQUESTED" ] || [ "$STATUS" = "IN_REVIEW" ] || [ "$STATUS" = "IMPLEMENTED" ]; then
        ACTIVE_TASK=$(basename "$task_file" .md)
        ACTIVE_STATUS="$STATUS"
      fi
    fi
  done
fi

# Update compaction counter
COMPACTION_FILE="$HYDRA_DIR/.compaction_count"
if [ -f "$COMPACTION_FILE" ]; then
  PREV_COUNT=$(jq -r '.count // 0' "$COMPACTION_FILE" 2>/dev/null || echo "0")
else
  PREV_COUNT=0
fi
NEW_COUNT=$((PREV_COUNT + 1))
printf '{"count": %d, "last_compaction_iteration": %s}\n' "$NEW_COUNT" "$ITERATION" > "$COMPACTION_FILE"

# Get latest checkpoint
LATEST_CHECKPOINT=$(ls -1t "$HYDRA_DIR/checkpoints/iteration-"*.json 2>/dev/null | head -1 || echo "none")

# Get reviewers
REVIEWERS=$(jq -r '.agents.reviewers // [] | join(", ")' "$CONFIG" 2>/dev/null || echo "none configured")

# Git state
GIT_BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" branch --show-current 2>/dev/null || echo "unknown")
GIT_LAST=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" log --oneline -1 2>/dev/null || echo "unknown")

# Output recovery context
cat << CONTEXT_EOF
Hydra loop state — iteration ${ITERATION}/${MAX_ITER} | Mode: ${MODE} | Objective: ${OBJECTIVE}
Tasks: ${DONE_COUNT} done, ${APPROVED_COUNT} approved, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked | Total: ${TOTAL_COUNT}
Compactions: ${NEW_COUNT}
CONTEXT_EOF

# Output Recovery Pointer if plan exists
if [ -f "$PLAN" ]; then
  echo ""
  sed -n '/^## Recovery Pointer/,/^## /p' "$PLAN" | head -7
fi

cat << CONTEXT_EOF2

Active task: ${ACTIVE_TASK:-none} (${ACTIVE_STATUS:-none})
$([ "$ACTIVE_STATUS" = "IMPLEMENTED" ] && echo "DELEGATE: Spawn review-gate agent (hydra:review-gate) for ${ACTIVE_TASK}. Do NOT skip the review gate." || true)
$([ "$ACTIVE_STATUS" = "IN_REVIEW" ] && echo "DELEGATE: Spawn review-gate agent (hydra:review-gate) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "READY" ] && echo "DELEGATE: Spawn implementer agent (hydra:implementer) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "IN_PROGRESS" ] && echo "DELEGATE: Spawn implementer agent (hydra:implementer) for ${ACTIVE_TASK}." || true)
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "DELEGATE: Spawn implementer agent (hydra:implementer) for ${ACTIVE_TASK}. Read consolidated feedback first." || true)
Reviewers: ${REVIEWERS}

Git: ${GIT_BRANCH} — ${GIT_LAST}
Latest checkpoint: ${LATEST_CHECKPOINT}
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "WARNING: Read hydra/reviews/${ACTIVE_TASK}/consolidated-feedback.md for reviewer feedback." || true)

Read hydra/plan.md for full state. Continue the Hydra pipeline.
CONTEXT_EOF2
