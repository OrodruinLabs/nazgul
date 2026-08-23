#!/usr/bin/env bash
#
# session-staging.sh — SessionEnd hook for staging modified files
#
# Safety net for AFK/YOLO sessions: stages all modified files at session end
# so work isn't lost if the session terminates unexpectedly mid-task.
#
# STAGING only runs when AFK mode is enabled; it never commits, only stages.
# The session-lock RELEASE runs on every SessionEnd path, HITL included.
#
# Environment Variables:
#   NAZGUL_STAGING_DISABLE  - Set to "1" to disable (default: enabled)
#   NAZGUL_STAGING_DEBUG    - Enable debug logging to stderr (default: "0")
#
# Hook Type: SessionEnd
#   - Non-blocking: always exits 0
#
# Exit codes:
#   0 - Always (non-blocking)

set -euo pipefail

debug_log() {
    if [[ "${NAZGUL_STAGING_DEBUG:-0}" == "1" ]]; then
        echo "[STAGING $(date -Iseconds)] $1" >&2
    fi
}

# Returns 0 (skip) when the file is a nazgul/ path in local install mode.
should_skip_local_nazgul() {
    local file="$1" mode="${2:-}"
    if [[ "$mode" == "local" && "$file" == nazgul/* ]]; then
        debug_log "Skipping nazgul/ path in local mode: $file"
        return 0
    fi
    return 1
}

output_result() {
    echo '{"continue": true}'
    exit 0
}

# Session-lock release (#195): the lock's lifetime is the session's, and this is its
# end. The hook payload's session_id is the ONLY identity used.
#
# There is deliberately NO `nazgul/.session_id` fallback (PR #223 review #9). That file
# is last-writer-wins — session-context.sh rewrites it on every SessionStart — so in the
# shared-working-tree case this feature exists to protect (#195), session A ending would
# read B's id and unregister B's LIVE lock while A's own leaked. Releasing the wrong
# session's lock is strictly worse than releasing none, because a wrongly-released one
# silently disarms the collision warning for a session that is STILL RUNNING.
# The honest cost of releasing none (PR #223 re-review): a lock CARRYING a pid is retired
# promptly by the pid-liveness sweep, but after review #5 a lock whose session pid could
# not be determined carries none, and those fall to the AGE rule alone
# (`cleanup_stale_sessions`, 2h default). Slower — and still bounded, unlike a wrong release.
release_session_lock() {
    local sd nd sid
    sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$sd/lib/nazgul-root.sh" 2>/dev/null || return 0
    nd="$(resolve_nazgul_dir 2>/dev/null)" || return 0
    [ -d "$nd/sessions" ] || return 0
    sid=$(printf '%s' "$STAGING_STDIN" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    [ -n "$sid" ] || return 0
    source "$sd/lib/session-tracker.sh" 2>/dev/null || return 0
    unregister_session "$sid" "$nd/sessions" 2>/dev/null || true
}

RHP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/read-hook-payload.sh"
# A load that returns 0 having defined nothing is still no payload, so it takes
# this hook's own posture rather than exiting 127 into whatever that means here.
rhp_unavailable() {
  printf 'session-staging: stdin reader unavailable: %s — fail-open, skipping the staging pass\n' "$1" >&2
  exit 0
}
[ -r "$RHP_LIB" ] || rhp_unavailable "$RHP_LIB is missing or unreadable"
rhp_rc=0
# shellcheck source=./lib/read-hook-payload.sh
source "$RHP_LIB" || rhp_rc=$?
declare -F read_hook_payload >/dev/null && declare -F hook_payload_timeout_report >/dev/null \
  || rhp_unavailable "$RHP_LIB defines no reader API after sourcing (source returned $rhp_rc)"
read_hook_payload
if [ "$HOOK_PAYLOAD_OUTCOME" = "timeout" ]; then
  hook_payload_timeout_report "session-staging" "fail-open" "continuing without a session id"
fi
STAGING_STDIN="$HOOK_PAYLOAD"

# Lock lifetime is the SESSION's, not staging's: released on every SessionEnd path,
# including the four staging gates below and any `set -e` abort (board R2).
trap 'release_session_lock || true' EXIT

# --- Check if disabled ---
if [[ "${NAZGUL_STAGING_DISABLE:-0}" == "1" ]]; then
    debug_log "Disabled (NAZGUL_STAGING_DISABLE=1)"
    output_result
fi

# --- Check if Nazgul is initialized ---
if [[ ! -f "nazgul/config.json" ]]; then
    debug_log "No nazgul/config.json — not a Nazgul project"
    output_result
fi

# --- Check if AFK mode is enabled ---
AFK_ENABLED=$(jq -r '.afk.enabled // false' nazgul/config.json 2>/dev/null || echo "false")

if [[ "$AFK_ENABLED" != "true" ]]; then
    debug_log "AFK mode not enabled — skipping staging"
    output_result
fi

# --- Check if we're in a git repo ---
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    debug_log "Not in a git repository"
    output_result
fi

# --- Determine install_mode to skip nazgul/ in local installs ---
INSTALL_MODE=$(jq -r '.install_mode // ""' nazgul/config.json 2>/dev/null || echo "")

# --- Stage all modified files ---
STAGED_COUNT=0

# Modified but not staged
while IFS= read -r file; do
    if [[ -n "$file" && -e "$file" ]]; then
        should_skip_local_nazgul "$file" "$INSTALL_MODE" && continue
        if git add "$file" 2>/dev/null; then
            STAGED_COUNT=$((STAGED_COUNT + 1))
            debug_log "Staged: $file"
        fi
    fi
done < <(git diff --name-only 2>/dev/null)

# Untracked files (excluding ignored)
while IFS= read -r file; do
    if [[ -n "$file" && -e "$file" ]]; then
        should_skip_local_nazgul "$file" "$INSTALL_MODE" && continue
        # Skip sensitive files
        case "$file" in
            *.env|*.env.*|credentials*|*secret*|*.pem|*.key)
                debug_log "Skipping sensitive file: $file"
                continue
                ;;
        esac
        if git add "$file" 2>/dev/null; then
            STAGED_COUNT=$((STAGED_COUNT + 1))
            debug_log "Staged (new): $file"
        fi
    fi
done < <(git ls-files --others --exclude-standard 2>/dev/null)

if [[ "$STAGED_COUNT" -gt 0 ]]; then
    echo "[NAZGUL] Staged $STAGED_COUNT file(s) at session end (AFK safety net)" >&2
else
    debug_log "No files to stage"
fi

output_result
