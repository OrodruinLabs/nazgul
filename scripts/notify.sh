#!/usr/bin/env bash
#
# notify.sh — Stop hook for loop completion notifications
#
# Fires on Stop and executes a user-configured notification command
# when the Nazgul loop completes (every task terminal — DONE or CANCELLED — or NAZGUL_COMPLETE detected).
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RHP_LIB="$SCRIPT_DIR/lib/read-hook-payload.sh"
# A load that returns 0 having defined nothing is still no payload, so it takes
# this hook's own posture rather than exiting 127 into whatever that means here.
rhp_unavailable() {
  printf 'notify: stdin reader unavailable: %s — fail-open, skipping the notification\n' "$1" >&2
  exit 0
}
[ -r "$RHP_LIB" ] || rhp_unavailable "$RHP_LIB is missing or unreadable"
rhp_rc=0
# shellcheck source=./lib/read-hook-payload.sh
source "$RHP_LIB" || rhp_rc=$?
declare -F read_hook_payload >/dev/null && declare -F hook_payload_timeout_report >/dev/null \
  || rhp_unavailable "$RHP_LIB defines no reader API after sourcing (source returned $rhp_rc)"
source "$SCRIPT_DIR/lib/nazgul-root.sh"

# Guarded so an unreadable lib leaves this Stop hook non-blocking instead of aborting it.
TU_LIB="$SCRIPT_DIR/lib/task-utils.sh"
TU_RC=0
if [ -r "$TU_LIB" ]; then
  # shellcheck source=./lib/task-utils.sh
  source "$TU_LIB" || TU_RC=$?
else
  TU_RC=127
fi

# MF-031: resolve nazgul/ paths against the project root like every sibling guard,
# not bare relative paths that only work when cwd is already the project root.
PROJECT_ROOT="$(resolve_project_root)"

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
read_hook_payload
if [ "$HOOK_PAYLOAD_OUTCOME" = "timeout" ]; then
    hook_payload_timeout_report "notify" "fail-open" "continuing with no session context"
fi
INPUT="$HOOK_PAYLOAD"
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
NAZGUL_OBJECTIVE=$(jq -r '.objective // "unknown"' "$PROJECT_ROOT/nazgul/config.json" 2>/dev/null || echo "unknown")

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

# Check whether every task has reached a terminal status (issue #203)
if [[ "$LOOP_COMPLETE" != "true" ]]; then
    if declare -F count_tasks_and_find_active >/dev/null; then
        count_tasks_and_find_active "$PROJECT_ROOT/nazgul/tasks"
        if [ "$TOTAL_COUNT" -gt 0 ] && [ "$((DONE_COUNT + CANCELLED_COUNT))" -eq "$TOTAL_COUNT" ]; then
            LOOP_COMPLETE="true"
            debug_log "All $TOTAL_COUNT tasks DONE or CANCELLED ($DONE_COUNT DONE, $CANCELLED_COUNT CANCELLED)"
        fi
    else
        debug_log "task-utils.sh unavailable (rc $TU_RC) — task status unreadable, skipping notification"
    fi
fi

if [[ "$LOOP_COMPLETE" != "true" ]]; then
    debug_log "Loop not complete — skipping notification"
    output_result
fi

# --- Get notification command ---
NOTIFY_CMD=""

# Check config.json first
if command -v jq &>/dev/null && [[ -f "$PROJECT_ROOT/nazgul/config.json" ]]; then
    NOTIFY_CMD=$(jq -r '.notifications.on_complete // empty' "$PROJECT_ROOT/nazgul/config.json" 2>/dev/null || true)
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
