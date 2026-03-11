#!/usr/bin/env bash
#
# notify.sh — Stop hook for loop completion notifications
#
# Fires on Stop and executes a user-configured notification command
# when the Hydra loop completes (all tasks DONE or HYDRA_COMPLETE detected).
#
# Configuration (checked in order):
#   1. hydra/config.json → notifications.on_complete
#   2. HYDRA_NOTIFY_ON_STOP environment variable
#
# Environment Variables:
#   HYDRA_NOTIFY_ON_STOP   - Command to execute on completion (fallback)
#   HYDRA_NOTIFY_DISABLE   - Set to "1" to disable (default: enabled)
#   HYDRA_NOTIFY_DEBUG     - Enable debug logging to stderr (default: "0")
#
# Exported to notification command:
#   HYDRA_SESSION_ID       - Session ID from hook input
#   HYDRA_CWD              - Working directory
#   HYDRA_TRANSCRIPT_PATH  - Transcript path
#   HYDRA_OBJECTIVE        - Current objective from config
#
# Hook Type: Stop
#   - Only notifies when loop is complete (not every iteration)
#   - Non-blocking: always exits 0
#
# Usage examples:
#   # macOS speech
#   notifications.on_complete: "say 'Hydra loop complete'"
#
#   # Desktop notification (macOS)
#   notifications.on_complete: "osascript -e 'display notification \"Hydra done\" with title \"Hydra\"'"
#
#   # tmux signal
#   HYDRA_NOTIFY_ON_STOP="tmux send-keys -t main 'echo done' Enter"
#
#   # Webhook
#   HYDRA_NOTIFY_ON_STOP="curl -s -X POST https://hooks.example.com/hydra-done"

set -euo pipefail

COMMAND_TIMEOUT=30

debug_log() {
    if [[ "${HYDRA_NOTIFY_DEBUG:-0}" == "1" ]]; then
        echo "[NOTIFY $(date -Iseconds)] $1" >&2
    fi
}

output_result() {
    echo '{"continue": true}'
    exit 0
}

# --- Check if disabled ---
if [[ "${HYDRA_NOTIFY_DISABLE:-0}" == "1" ]]; then
    debug_log "Disabled (HYDRA_NOTIFY_DISABLE=1)"
    output_result
fi

# --- Read input from stdin ---
INPUT=""
if [[ ! -t 0 ]]; then
    INPUT=$(cat)
fi
debug_log "Input: ${INPUT:0:200}..."

# --- Extract session context ---
extract_field() {
    local field="$1"
    local default="${2:-unknown}"
    if command -v jq &>/dev/null && [[ -n "$INPUT" ]]; then
        local val
        val=$(echo "$INPUT" | jq -r ".$field // empty" 2>/dev/null || true)
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

export HYDRA_SESSION_ID
export HYDRA_CWD
export HYDRA_TRANSCRIPT_PATH
export HYDRA_OBJECTIVE

HYDRA_SESSION_ID=$(extract_field "session_id" "unknown")
HYDRA_CWD=$(extract_field "cwd" "$(pwd)")
HYDRA_TRANSCRIPT_PATH=$(extract_field "transcript_path" "unknown")
HYDRA_OBJECTIVE=$(jq -r '.objective // "unknown"' hydra/config.json 2>/dev/null || echo "unknown")

# --- Check if loop is actually complete ---
# Only notify on completion, not every iteration stop

LOOP_COMPLETE="false"

# Check transcript for HYDRA_COMPLETE
if [[ "$HYDRA_TRANSCRIPT_PATH" != "unknown" && -f "$HYDRA_TRANSCRIPT_PATH" ]]; then
    if grep -q "HYDRA_COMPLETE" "$HYDRA_TRANSCRIPT_PATH" 2>/dev/null; then
        LOOP_COMPLETE="true"
        debug_log "HYDRA_COMPLETE found in transcript"
    fi
fi

# Check if all tasks are DONE
if [[ "$LOOP_COMPLETE" != "true" && -d "hydra/tasks" ]]; then
    TOTAL=$(ls hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' ')
    DONE=$(grep -rlE '(Status\*\*:[[:space:]]*DONE|^## Status:[[:space:]]*DONE)' hydra/tasks/TASK-*.md 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$TOTAL" -gt 0 && "$TOTAL" == "$DONE" ]]; then
        LOOP_COMPLETE="true"
        debug_log "All $TOTAL tasks DONE"
    fi
fi

if [[ "$LOOP_COMPLETE" != "true" ]]; then
    debug_log "Loop not complete — skipping notification"
    output_result
fi

# --- Get notification command ---
NOTIFY_CMD=""

# Check config.json first
if command -v jq &>/dev/null && [[ -f "hydra/config.json" ]]; then
    NOTIFY_CMD=$(jq -r '.notifications.on_complete // empty' hydra/config.json 2>/dev/null || true)
fi

# Fall back to env var
if [[ -z "$NOTIFY_CMD" ]]; then
    NOTIFY_CMD="${HYDRA_NOTIFY_ON_STOP:-}"
fi

# Check if whitespace-only
TRIMMED=$(echo "${NOTIFY_CMD:-}" | tr -d '[:space:]')
if [[ -z "$TRIMMED" ]]; then
    debug_log "No notification command configured"
    output_result
fi

debug_log "Executing notification command"

# --- Execute with timeout ---
NOTIFY_EXIT=0
if command -v timeout &>/dev/null; then
    timeout "$COMMAND_TIMEOUT" /bin/sh -c "$NOTIFY_CMD" 2>&1 || NOTIFY_EXIT=$?
elif command -v gtimeout &>/dev/null; then
    gtimeout "$COMMAND_TIMEOUT" /bin/sh -c "$NOTIFY_CMD" 2>&1 || NOTIFY_EXIT=$?
else
    /bin/sh -c "$NOTIFY_CMD" 2>&1 || NOTIFY_EXIT=$?
fi

if [[ $NOTIFY_EXIT -eq 0 ]]; then
    debug_log "Notification sent successfully"
elif [[ $NOTIFY_EXIT -eq 124 ]]; then
    debug_log "Notification timed out after ${COMMAND_TIMEOUT}s"
else
    debug_log "Notification failed (exit $NOTIFY_EXIT)"
fi

# Always non-blocking
output_result
