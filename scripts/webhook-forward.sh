#!/usr/bin/env bash
set -euo pipefail

# Nazgul Webhook Forward — POSTs loop events to a configured webhook URL
# Reads webhook config from nazgul/config.json. No-ops if webhooks disabled.
# Usage: webhook-forward.sh [event_type]
# Called by hooks (Stop, PostCompact) to notify external systems.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"
source "$SCRIPT_DIR/lib/task-utils.sh"

PROJECT_ROOT="$(resolve_project_root)"
NAZGUL_DIR="$PROJECT_ROOT/nazgul"
CONFIG="$NAZGUL_DIR/config.json"

# If Nazgul not initialized or no config, exit silently
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
GIT_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")

# Count tasks through the one shared parser. The private grep this replaced
# could not learn CANCELLED when task-utils.sh did, and read no frontmatter.
count_tasks_and_find_active "$NAZGUL_DIR/tasks"

PAYLOAD=$(jq -n \
  --arg event "$EVENT_TYPE" \
  --arg objective "$OBJECTIVE" \
  --arg mode "$MODE" \
  --arg feat_id "$FEAT_ID" \
  --arg branch "$GIT_BRANCH" \
  --arg active_task "$ACTIVE_TASK" \
  --argjson iteration "$ITERATION" \
  --argjson max_iter "$MAX_ITER" \
  --argjson "done" "$DONE_COUNT" \
  --argjson cancelled "$CANCELLED_COUNT" \
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
    tasks_cancelled: $cancelled,
    tasks_total: $total,
    active_task: $active_task
  }')

# Build headers from config. MF-032: a native bash array survives header
# values containing spaces (e.g. "Authorization: Bearer abc 123"); the prior
# xargs pipeline word-split on all whitespace and corrupted such values.
HEADERS_JSON=$(jq -r '.webhooks.headers // {}' "$CONFIG")
HEADER_ARGS=()
if [ "$HEADERS_JSON" != "{}" ]; then
  while IFS= read -r header_line; do
    HEADER_ARGS+=(-H "$header_line")
  done < <(echo "$HEADERS_JSON" | jq -r 'to_entries[] | "\(.key): \(.value)"')
fi

# POST to webhook URL (best-effort, don't fail the hook)
curl -s -X POST \
  -H "Content-Type: application/json" \
  ${HEADER_ARGS[@]+"${HEADER_ARGS[@]}"} \
  -d "$PAYLOAD" \
  --max-time 5 \
  --connect-timeout 2 \
  "$WEBHOOK_URL" >/dev/null 2>&1 || true
