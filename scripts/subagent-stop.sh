#!/usr/bin/env bash
set -euo pipefail

# Nazgul SubagentStop — fires when any subagent finishes. Lightweight
# observability: appends one event to the telemetry bus so /nazgul:metrics
# can report how many subagents ran per loop. Never blocks the subagent.
#
# Input: hook JSON on stdin (may include subagent name / type — recorded if
# present, but never required).

INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
fi

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"

# If Nazgul is not initialized here, do nothing.
[ -f "$CONFIG" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/emit-event.sh"

# Best-effort extraction of an agent identifier; default to "unknown".
AGENT="unknown"
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.subagent_type // .agent_type // .name // "unknown"' 2>/dev/null || echo "unknown")
  [ -n "$AGENT" ] || AGENT="unknown"
fi

# Emit subagent_stop to the telemetry bus (replaces legacy subagents.jsonl write).
# CURRENT_ITERATION is intentionally null — script does not read config.
# shellcheck disable=SC2034
CURRENT_ITERATION="null"
emit_event "subagent_stop" agent "$AGENT"

exit 0
