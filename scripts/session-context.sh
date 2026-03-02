#!/usr/bin/env bash
set -euo pipefail

# Hydra Session Context — injects state on startup and after compaction
# Stdout is shown to the agent

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"
PLAN="$HYDRA_DIR/plan.md"

# If Hydra not initialized, nothing to inject
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Auto-migrate config to latest schema version
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MIGRATE_SCRIPT="$PLUGIN_ROOT/scripts/migrate-config.sh"
MIGRATION_NOTICE=""
if [ -f "$MIGRATE_SCRIPT" ]; then
  MIGRATE_OUTPUT=$("$MIGRATE_SCRIPT" "$HYDRA_DIR" 2>/dev/null) || true
  if [ -n "$MIGRATE_OUTPUT" ]; then
    MIGRATION_NOTICE="$MIGRATE_OUTPUT"
  fi
fi

MODE=$(jq -r '.mode // "hitl"' "$CONFIG")
OBJECTIVE=$(jq -r '.objective // "none"' "$CONFIG")
ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")
MAX_ITER=$(jq -r '.max_iterations // 40' "$CONFIG")

# Count tasks
DONE_COUNT=0
READY_COUNT=0
IN_PROGRESS_COUNT=0
IN_REVIEW_COUNT=0
CHANGES_COUNT=0
BLOCKED_COUNT=0
TOTAL_COUNT=0
ACTIVE_TASK=""
ACTIVE_STATUS=""

if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    STATUS=$(grep -m1 '^\- \*\*Status\*\*:' "$task_file" 2>/dev/null | sed 's/.*: //' || echo "PLANNED")
    case "$STATUS" in
      DONE) DONE_COUNT=$((DONE_COUNT + 1)) ;;
      READY) READY_COUNT=$((READY_COUNT + 1)) ;;
      IN_PROGRESS) IN_PROGRESS_COUNT=$((IN_PROGRESS_COUNT + 1)) ;;
      IN_REVIEW|IMPLEMENTED) IN_REVIEW_COUNT=$((IN_REVIEW_COUNT + 1)) ;;
      CHANGES_REQUESTED) CHANGES_COUNT=$((CHANGES_COUNT + 1)) ;;
      BLOCKED) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
    esac
    if [ -z "$ACTIVE_TASK" ]; then
      if [ "$STATUS" = "IN_PROGRESS" ] || [ "$STATUS" = "CHANGES_REQUESTED" ] || [ "$STATUS" = "IN_REVIEW" ]; then
        ACTIVE_TASK=$(basename "$task_file" .md)
        ACTIVE_STATUS="$STATUS"
      fi
    fi
  done
fi

# Compaction counter (GAP-008 context rot detection)
COMPACTION_FILE="$HYDRA_DIR/.compaction_count"
HOOK_EVENT="${CLAUDE_HOOK_EVENT:-}"

if [ "$HOOK_EVENT" = "compact" ]; then
  # Read current state or initialize
  if [ -f "$COMPACTION_FILE" ]; then
    PREV_COUNT=$(jq -r '.count // 0' "$COMPACTION_FILE" 2>/dev/null || echo "0")
  else
    PREV_COUNT=0
  fi
  NEW_COUNT=$((PREV_COUNT + 1))
  # Write updated compaction state with current iteration
  printf '{"count": %d, "last_compaction_iteration": %s}\n' "$NEW_COUNT" "$ITERATION" > "$COMPACTION_FILE"
fi

# Read compaction count for output
if [ -f "$COMPACTION_FILE" ]; then
  COMPACTION_COUNT=$(jq -r '.count // 0' "$COMPACTION_FILE" 2>/dev/null || echo "0")
else
  COMPACTION_COUNT=0
fi

# Get latest checkpoint
LATEST_CHECKPOINT=$(ls -1t "$HYDRA_DIR/checkpoints/iteration-"*.json 2>/dev/null | head -1 || echo "none")

# Get reviewers
REVIEWERS=$(jq -r '.agents.reviewers // [] | join(", ")' "$CONFIG" 2>/dev/null || echo "none configured")

# Git state
GIT_BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" branch --show-current 2>/dev/null || echo "unknown")
GIT_LAST=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" log --oneline -1 2>/dev/null || echo "unknown")

# Output context
cat << CONTEXT_EOF
Hydra loop state — iteration ${ITERATION}/${MAX_ITER} | Mode: ${MODE} | Objective: ${OBJECTIVE}
Tasks: ${DONE_COUNT} done, ${READY_COUNT} ready, ${IN_PROGRESS_COUNT} in progress, ${IN_REVIEW_COUNT} in review, ${CHANGES_COUNT} changes requested, ${BLOCKED_COUNT} blocked | Total: ${TOTAL_COUNT}
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
Reviewers: ${REVIEWERS}
Git: ${GIT_BRANCH} — ${GIT_LAST}
Latest checkpoint: ${LATEST_CHECKPOINT}
$([ "$ACTIVE_STATUS" = "CHANGES_REQUESTED" ] && echo "WARNING: Read hydra/reviews/${ACTIVE_TASK}/consolidated-feedback.md for reviewer feedback." || true)

Read hydra/plan.md for full state. Continue the Hydra pipeline.
CONTEXT_EOF2

# Check for pending notification events (zero-cost: reads SQLite directly)
NOTIFY_DB="$HYDRA_DIR/notifications.db"
if [ -f "$NOTIFY_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  PENDING=$(sqlite3 "$NOTIFY_DB" "SELECT COUNT(*) FROM events WHERE status='pending';" 2>/dev/null || echo "0")
  if [ "$PENDING" -gt 0 ]; then
    echo "NOTIFICATION_EVENTS: $PENDING pending event(s). Run /hydra-notify to process them."
  fi
fi

# Trigger fresh poll from MCP server on session start and compaction
NOTIFY_ENABLED=$(jq -r '.notifications.enabled // false' "$CONFIG")
if [ "$NOTIFY_ENABLED" = "true" ]; then
  echo "ACTION: Call trigger_poll MCP tool to check for new GitHub events."
fi
