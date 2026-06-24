#!/usr/bin/env bash
set -euo pipefail
# scripts/emit-event-cli.sh — CLI entry point for emit-event.sh used by agents.
# Usage: emit-event-cli.sh <event_type> [key val ...] [key:n numeric_val ...]
#
# Example (review-gate agent Bash tool call):
#   "${CLAUDE_PLUGIN_ROOT}/scripts/emit-event-cli.sh" reviewer_verdict \
#     task_id "$TASK_ID" reviewer "$REVIEWER_NAME" \
#     decision "$DECISION" confidence:n "$CONFIDENCE" \
#     blocking_findings:n "$BLOCKING" concerns:n "$CONCERNS"
#
# NAZGUL_DIR and CURRENT_ITERATION must be set in the environment or the emit
# silently no-ops (uninitialised guard in emit-event.sh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/emit-event.sh"
emit_event "$@"
