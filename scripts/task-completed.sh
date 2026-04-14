#!/usr/bin/env bash
set -euo pipefail

# Nazgul TaskCompleted — fires when a Task-spawned agent finishes
# Logs completion and fires webhook event for real-time monitoring.

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"

# If Nazgul not initialized, exit silently
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

# Log task completion
LOG_DIR="$NAZGUL_DIR/logs"
mkdir -p "$LOG_DIR"
printf '{"event":"task_completed","timestamp":"%s"}\n' \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$LOG_DIR/iterations.jsonl"

# Reset tool failure counter on successful task completion
FAILURE_FILE="$NAZGUL_DIR/.tool_failures"
if [ -f "$FAILURE_FILE" ]; then
  printf '{"consecutive_bash_failures": 0, "last_failure": null}\n' > "$FAILURE_FILE"
fi

# Forward webhook if enabled
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ -f "$PLUGIN_ROOT/scripts/webhook-forward.sh" ]; then
  "$PLUGIN_ROOT/scripts/webhook-forward.sh" "task_complete" 2>/dev/null || true
fi
