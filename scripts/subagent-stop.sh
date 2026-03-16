#!/usr/bin/env bash
set -euo pipefail

# Hydra SubagentStop — detects agent failures and tracks them
# Fires when ANY Task-spawned agent completes or fails.
# Increments consecutive_failures on unexpected stops, marks tasks BLOCKED at threshold.

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"

# If Hydra not initialized, exit silently
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Read agent result from hook environment
# CLAUDE_HOOK_TOOL_RESULT contains the agent's final output
TOOL_RESULT="${CLAUDE_HOOK_TOOL_RESULT:-}"

# Determine if the agent stopped successfully or failed
# A successful agent will have meaningful output; a crashed one may have error indicators
AGENT_FAILED=false

# Check for failure indicators in the result
if [ -z "$TOOL_RESULT" ]; then
  AGENT_FAILED=true
elif echo "$TOOL_RESULT" | grep -qiE '(maxTurns reached|timed out|error:|fatal:|panic:)'; then
  AGENT_FAILED=true
fi

if [ "$AGENT_FAILED" = "true" ]; then
  # Increment consecutive failures
  CURRENT_FAILURES=$(jq -r '.safety.consecutive_failures // 0' "$CONFIG")
  NEW_FAILURES=$((CURRENT_FAILURES + 1))
  MAX_FAILURES=$(jq -r '.safety.max_consecutive_failures // 5' "$CONFIG")

  local_tmp=$(mktemp)
  jq --argjson f "$NEW_FAILURES" '.safety.consecutive_failures = $f' "$CONFIG" > "$local_tmp" && mv "$local_tmp" "$CONFIG"

  # Log the failure
  LOG_DIR="$HYDRA_DIR/logs"
  mkdir -p "$LOG_DIR"
  printf '{"event":"subagent_failure","timestamp":"%s","failures":%d,"max":%d}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$NEW_FAILURES" "$MAX_FAILURES" >> "$LOG_DIR/iterations.jsonl"

  # If threshold hit, mark active task as BLOCKED
  if [ "$NEW_FAILURES" -ge "$MAX_FAILURES" ]; then
    ACTIVE_TASK=""
    if [ -d "$HYDRA_DIR/tasks" ]; then
      for task_file in "$HYDRA_DIR/tasks"/TASK-*.md; do
        [ -f "$task_file" ] || continue
        STATUS=$(grep -m1 -E '(^\- \*\*Status\*\*:|^## Status:)' "$task_file" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "")
        if [ "$STATUS" = "IN_PROGRESS" ]; then
          ACTIVE_TASK="$task_file"
          break
        fi
      done
    fi

    if [ -n "$ACTIVE_TASK" ]; then
      sed -i'' -e 's/Status\*\*: IN_PROGRESS/Status**: BLOCKED/' "$ACTIVE_TASK" 2>/dev/null || true
      sed -i'' -e 's/^## Status: IN_PROGRESS/## Status: BLOCKED/' "$ACTIVE_TASK" 2>/dev/null || true
    fi

    echo "WARNING: Consecutive agent failures ($NEW_FAILURES/$MAX_FAILURES) hit threshold. Active task marked BLOCKED." >&2
  fi

  # Forward webhook if enabled
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
  if [ -f "$PLUGIN_ROOT/scripts/webhook-forward.sh" ]; then
    "$PLUGIN_ROOT/scripts/webhook-forward.sh" "subagent_failure" 2>/dev/null || true
  fi
else
  # Agent succeeded — reset consecutive failures
  local_tmp=$(mktemp)
  jq '.safety.consecutive_failures = 0' "$CONFIG" > "$local_tmp" && mv "$local_tmp" "$CONFIG"
fi
