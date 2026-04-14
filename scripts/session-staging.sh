#!/usr/bin/env bash
#
# session-staging.sh — SessionEnd hook for staging modified files
#
# Safety net for AFK/YOLO sessions: stages all modified files at session end
# so work isn't lost if the session terminates unexpectedly mid-task.
#
# Only runs when AFK mode is enabled. No-op for HITL sessions.
# NEVER commits — only stages (git add).
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

output_result() {
    echo '{"continue": true}'
    exit 0
}

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
AFK_ENABLED="false"
if command -v jq &>/dev/null; then
    AFK_ENABLED=$(jq -r '.afk.enabled // false' nazgul/config.json 2>/dev/null || echo "false")
fi

if [[ "$AFK_ENABLED" != "true" ]]; then
    debug_log "AFK mode not enabled — skipping staging"
    output_result
fi

# --- Check if we're in a git repo ---
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    debug_log "Not in a git repository"
    output_result
fi

# --- Stage all modified files ---
STAGED_COUNT=0

# Modified but not staged
while IFS= read -r file; do
    if [[ -n "$file" && -e "$file" ]]; then
        if git add "$file" 2>/dev/null; then
            ((STAGED_COUNT++))
            debug_log "Staged: $file"
        fi
    fi
done < <(git diff --name-only 2>/dev/null)

# Untracked files (excluding ignored)
while IFS= read -r file; do
    if [[ -n "$file" && -e "$file" ]]; then
        # Skip sensitive files
        case "$file" in
            *.env|*.env.*|credentials*|*secret*|*.pem|*.key)
                debug_log "Skipping sensitive file: $file"
                continue
                ;;
        esac
        if git add "$file" 2>/dev/null; then
            ((STAGED_COUNT++))
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
