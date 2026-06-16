#!/usr/bin/env bash
set -euo pipefail

# Nazgul SubagentStop — fires when any subagent finishes. Lightweight
# observability: appends one line to a subagent metrics log so /nazgul:metrics
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

# Best-effort extraction of an agent identifier; default to "unknown".
AGENT="unknown"
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  AGENT=$(printf '%s' "$INPUT" | jq -r '.subagent_type // .agent_type // .name // "unknown"' 2>/dev/null || echo "unknown")
  [ -n "$AGENT" ] || AGENT="unknown"
fi

LOG_DIR="$NAZGUL_DIR/logs"
mkdir -p "$LOG_DIR"
printf '{"event":"subagent_stop","agent":"%s","timestamp":"%s"}\n' \
  "$AGENT" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$LOG_DIR/subagents.jsonl"

exit 0
