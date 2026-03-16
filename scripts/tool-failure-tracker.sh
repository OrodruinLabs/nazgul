#!/usr/bin/env bash
set -euo pipefail

# Hydra Tool Failure Tracker — tracks consecutive Bash failures
# Fires on PostToolUseFailure for Bash tool.
# After 3 consecutive failures, outputs a prompt to escalate to the debugger.

HYDRA_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/hydra"
CONFIG="$HYDRA_DIR/config.json"

# If Hydra not initialized, exit silently
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

FAILURE_FILE="$HYDRA_DIR/.tool_failures"

# Read current failure count
if [ -f "$FAILURE_FILE" ]; then
  FAILURE_COUNT=$(jq -r '.consecutive_bash_failures // 0' "$FAILURE_FILE" 2>/dev/null || echo "0")
else
  FAILURE_COUNT=0
fi

NEW_COUNT=$((FAILURE_COUNT + 1))
THRESHOLD=3

# Write updated count
printf '{"consecutive_bash_failures": %d, "last_failure": "%s"}\n' \
  "$NEW_COUNT" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$FAILURE_FILE"

# Log to iterations.jsonl
LOG_DIR="$HYDRA_DIR/logs"
mkdir -p "$LOG_DIR"
printf '{"event":"tool_failure","tool":"Bash","timestamp":"%s","consecutive":%d}\n' \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$NEW_COUNT" >> "$LOG_DIR/iterations.jsonl"

# On 3rd consecutive failure, escalate
if [ "$NEW_COUNT" -ge "$THRESHOLD" ]; then
  cat << 'ESCALATE_EOF'
WARNING: 3+ consecutive Bash command failures detected. Before retrying:
1. Read the error output carefully — the same approach is failing repeatedly
2. If a test/lint/build command keeps failing, investigate the root cause
3. Consider delegating to the Debugger agent for systematic diagnosis
4. Check hydra/logs/iterations.jsonl for the failure pattern
ESCALATE_EOF
fi
