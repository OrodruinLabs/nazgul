#!/usr/bin/env bash
set -euo pipefail

# Hydra Webhook Forward — POSTs loop events to a configured webhook URL
# Reads webhook config from hydra/config.json. No-ops if webhooks disabled.
# Usage: webhook-forward.sh [event_type]
# Called by hooks (Stop, PostCompact) to notify external systems.

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"

# If Hydra not initialized or no config, exit silently
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Check if webhooks are enabled
ENABLED=$(jq -r '.webhooks.enabled // false' "$CONFIG")
if [ "$ENABLED" != "true" ]; then
  exit 0
fi

WEBHOOK_URL=$(jq -r '.webhooks.url // ""' "$CONFIG")
if [ -z "$WEBHOOK_URL" ]; then
  exit 0
fi

# Determine event type from argument or hook environment
EVENT_TYPE="${1:-${CLAUDE_HOOK_EVENT:-unknown}}"

# Check if this event type is in the configured events list
EVENT_MATCH=$(jq -r --arg evt "$EVENT_TYPE" '.webhooks.events // [] | map(select(. == $evt)) | length' "$CONFIG")
if [ "$EVENT_MATCH" = "0" ]; then
  exit 0
fi

# Build payload
ITERATION=$(jq -r '.current_iteration // 0' "$CONFIG")
MAX_ITER=$(jq -r '.max_iterations // 40' "$CONFIG")
MODE=$(jq -r '.mode // "hitl"' "$CONFIG")
OBJECTIVE=$(jq -r '.objective // "none"' "$CONFIG")
FEAT_ID=$(jq -r '.feat_display_id // ""' "$CONFIG")
GIT_BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-$(pwd)}" branch --show-current 2>/dev/null || echo "unknown")

# Count tasks
DONE_COUNT=0
TOTAL_COUNT=0
ACTIVE_TASK=""
if [ -d "$HYDRA_DIR/tasks" ]; then
  for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    STATUS=$(grep -m1 -E '(^\- \*\*Status\*\*:|^## Status:)' "$task_file" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "PLANNED")
    if [ "$STATUS" = "DONE" ]; then
      DONE_COUNT=$((DONE_COUNT + 1))
    fi
    if [ -z "$ACTIVE_TASK" ]; then
      if [ "$STATUS" = "IN_PROGRESS" ] || [ "$STATUS" = "IN_REVIEW" ] || [ "$STATUS" = "IMPLEMENTED" ]; then
        ACTIVE_TASK=$(basename "$task_file" .md)
      fi
    fi
  done
fi

PAYLOAD=$(jq -n \
  --arg event "$EVENT_TYPE" \
  --arg objective "$OBJECTIVE" \
  --arg mode "$MODE" \
  --arg feat_id "$FEAT_ID" \
  --arg branch "$GIT_BRANCH" \
  --arg active_task "$ACTIVE_TASK" \
  --argjson iteration "$ITERATION" \
  --argjson max_iter "$MAX_ITER" \
  --argjson done "$DONE_COUNT" \
  --argjson total "$TOTAL_COUNT" \
  --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    event: $event,
    timestamp: $timestamp,
    objective: $objective,
    mode: $mode,
    feat_id: $feat_id,
    branch: $branch,
    iteration: $iteration,
    max_iterations: $max_iter,
    tasks_done: $done,
    tasks_total: $total,
    active_task: $active_task
  }')

# Build headers from config
HEADERS_JSON=$(jq -r '.webhooks.headers // {}' "$CONFIG")
HEADER_ARGS=""
if [ "$HEADERS_JSON" != "{}" ]; then
  HEADER_ARGS=$(echo "$HEADERS_JSON" | jq -r 'to_entries[] | "-H\n\(.key): \(.value)"')
fi

# POST to webhook URL (best-effort, don't fail the hook)
if [ -n "$HEADER_ARGS" ]; then
  echo "$HEADER_ARGS" | xargs curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    --max-time 5 \
    "$WEBHOOK_URL" >/dev/null 2>&1 || true
else
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    --max-time 5 \
    "$WEBHOOK_URL" >/dev/null 2>&1 || true
fi
