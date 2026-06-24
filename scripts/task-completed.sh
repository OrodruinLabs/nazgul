#!/usr/bin/env bash
set -euo pipefail

# Nazgul TaskCompleted — fires when a Task-spawned agent finishes
# Logs completion and fires webhook event for real-time monitoring.

INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"

# If Nazgul not initialized, exit silently
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/emit-event.sh"

# Best-effort task_id from stdin. CONCERN 2: TaskCompleted payload does not
# expose reliable task identity — task_id defaults to "unknown" in most cases.
# Consumers must not depend on task_id in v1.
TASK_ID="unknown"
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  TASK_ID=$(printf '%s' "$INPUT" | jq -r '.task_id // .taskId // "unknown"' 2>/dev/null || echo "unknown")
  [ -n "$TASK_ID" ] || TASK_ID="unknown"
fi

# Emit task_completed to the telemetry bus (replaces legacy iterations.jsonl write).
emit_event "task_completed" task_id "$TASK_ID"

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
