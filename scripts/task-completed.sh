#!/usr/bin/env bash
set -euo pipefail

# Nazgul TaskCompleted — fires when a Task-spawned agent finishes
# Logs completion and fires webhook event for real-time monitoring.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/read-hook-payload.sh
source "$SCRIPT_DIR/lib/read-hook-payload.sh"

read_hook_payload
if [ "$HOOK_PAYLOAD_OUTCOME" = "timeout" ]; then
  hook_payload_timeout_report "task-completed" "fail-open" "recording with an unknown task id"
fi
INPUT="$HOOK_PAYLOAD"

source "$SCRIPT_DIR/lib/nazgul-root.sh"

NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"

# If Nazgul not initialized, exit silently
if [ ! -f "$CONFIG" ]; then
  exit 0
fi

source "$SCRIPT_DIR/lib/emit-event.sh"

# task_id is best-effort — the TaskCompleted payload has no reliable task field.
TASK_ID="unknown"
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  TASK_ID=$(printf '%s' "$INPUT" | jq -r '.task_id // .taskId // "unknown"' 2>/dev/null || echo "unknown")
  [ -n "$TASK_ID" ] || TASK_ID="unknown"
fi

# CURRENT_ITERATION intentionally omitted — emit_event treats unset as null.
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
