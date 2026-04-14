#!/usr/bin/env bash
#
# notify.sh — Stop hook for loop completion notifications
#
# Fires on Stop and executes a user-configured notification command
# when the Nazgul loop completes (all tasks DONE or NAZGUL_COMPLETE detected).
#
# Configuration (checked in order):
#   1. nazgul/config.json → notifications.on_complete
#   2. NAZGUL_NOTIFY_ON_STOP environment variable
#
# Environment Variables:
#   NAZGUL_NOTIFY_ON_STOP   - Command to execute on completion (fallback)
#   NAZGUL_NOTIFY_DISABLE   - Set to "1" to disable (default: enabled)
#   NAZGUL_NOTIFY_DEBUG     - Enable debug logging to stderr (default: "0")
#
# Exported to notification command:
#   NAZGUL_SESSION_ID       - Session ID from hook input
#   NAZGUL_CWD              - Working directory
#   NAZGUL_TRANSCRIPT_PATH  - Transcript path
#   NAZGUL_OBJECTIVE        - Current objective from config
#
# Hook Type: Stop
#   - Only notifies when loop is complete (not every iteration)
#   - Non-blocking: always exits 0
#
# Usage examples:
#   # macOS speech
#   notifications.on_complete: "say 'Nazgul loop complete'"
#
#   # Desktop notification (macOS)
#   notifications.on_complete: "osascript -e 'display notification \"Nazgul done\" with title \"Nazgul\"'"
#
#   # tmux signal
#   NAZGUL_NOTIFY_ON_STOP="tmux send-keys -t main 'echo done' Enter"
#
#   # Webhook
#   NAZGUL_NOTIFY_ON_STOP="curl -s -X POST https://hooks.example.com/nazgul-done"

set -euo pipefail

COMMAND_TIMEOUT=30

debug_log() {
    if [[ "${NAZGUL_NOTIFY_DEBUG:-0}" == "1" ]]; then
        echo "[NOTIFY $(date -Iseconds)] $1" >&2
    fi
}

output_result() {
    echo '{"continue": true}'
    exit 0
}

# --- Check if disabled ---
if [[ "${NAZGUL_NOTIFY_DISABLE:-0}" == "1" ]]; then
    debug_log "Disabled (NAZGUL_NOTIFY_DISABLE=1)"
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

export NAZGUL_SESSION_ID
export NAZGUL_CWD
export NAZGUL_TRANSCRIPT_PATH
export NAZGUL_OBJECTIVE

NAZGUL_SESSION_ID=$(extract_field "session_id" "unknown")
NAZGUL_CWD=$(extract_field "cwd" "$(pwd)")
NAZGUL_TRANSCRIPT_PATH=$(extract_field "transcript_path" "unknown")
NAZGUL_OBJECTIVE=$(jq -r '.objective // "unknown"' nazgul/config.json 2>/dev/null || echo "unknown")

# --- Check if loop is actually complete ---
# Only notify on completion, not every iteration stop

LOOP_COMPLETE="false"

# Check transcript for NAZGUL_COMPLETE
if [[ "$NAZGUL_TRANSCRIPT_PATH" != "unknown" && -f "$NAZGUL_TRANSCRIPT_PATH" ]]; then
    if grep -q "NAZGUL_COMPLETE" "$NAZGUL_TRANSCRIPT_PATH" 2>/dev/null; then
        LOOP_COMPLETE="true"
        debug_log "NAZGUL_COMPLETE found in transcript"
    fi
fi

# Check if all tasks are DONE
if [[ "$LOOP_COMPLETE" != "true" && -d "nazgul/tasks" ]]; then
    TOTAL=$( (ls nazgul/tasks/TASK-*.md 2>/dev/null || true) | wc -l | tr -d ' ')
    DONE=$( (grep -rlE '(Status\*\*:[[:space:]]*DONE|^## Status:[[:space:]]*DONE)' nazgul/tasks/TASK-*.md 2>/dev/null || true) | wc -l | tr -d ' ')
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
if command -v jq &>/dev/null && [[ -f "nazgul/config.json" ]]; then
    NOTIFY_CMD=$(jq -r '.notifications.on_complete // empty' nazgul/config.json 2>/dev/null || true)
fi

# Fall back to env var
if [[ -z "$NOTIFY_CMD" ]]; then
    NOTIFY_CMD="${NAZGUL_NOTIFY_ON_STOP:-}"
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
