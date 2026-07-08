#!/usr/bin/env bash
set -euo pipefail
# Nazgul Conductor Dispatch Guard — PreToolUse on the Agent tool.
# Enforces agents/conductor.md Step 5: conductor work units dispatch SYNCHRONOUSLY,
# and a completed unit is never re-dispatched. No-op unless a conductor run is active.
# Exit 0 = allow. Exit 2 = deny (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
GRAPH="$NAZGUL_DIR/conductor/graph.json"
SESSION_MARKER="$NAZGUL_DIR/conductor/.session"

# Scope: only during an active conductor run.
[ -f "$CONFIG" ] || exit 0
[ -f "$SESSION_MARKER" ] || exit 0
ENGINE=$(jq -r '.execution.engine // "sequential"' "$CONFIG" 2>/dev/null || echo "sequential")
[ "$ENGINE" = "conductor" ] || exit 0

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .conductor.enforce.dispatch_guard == null then "true" else (.conductor.enforce.dispatch_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

# Only the Agent tool.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Agent" ] || exit 0

SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
BG=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null || echo "false")
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

is_work_unit() {
  case "$1" in
    *implementer*|*review-gate*|*team-orchestrator*) return 0 ;;
    *) return 1 ;;
  esac
}

# Rule 1: work units must be synchronous.
if [ "$BG" = "true" ] && is_work_unit "$SUBAGENT"; then
  echo "NAZGUL CONDUCTOR: Blocked — work-unit dispatch ($SUBAGENT) must be synchronous, not run_in_background (agents/conductor.md Step 5)." >&2
  exit 2
fi

# Rule 2: never re-dispatch a completed unit. Prompt carries `NAZGUL_UNIT: TASK-NNN` (grepped as data — never eval'd).
# The "already done, re-dispatch is wasted work" statuses differ by subagent kind: an IMPLEMENTED unit
# still legitimately needs its review-gate dispatch (that's the very next step in agents/conductor.md
# Step 5.2, not a re-dispatch) — only a DONE unit's review is wasted work. An implementer/team-orchestrator
# re-dispatch is wasted the moment the unit reaches IMPLEMENTED, since the implementation is already done.
UNIT=$(printf '%s' "$PROMPT" | grep -oE 'NAZGUL_UNIT: TASK-[0-9]+' | head -1 | sed 's/^NAZGUL_UNIT: //' || true)
if [ -n "$UNIT" ] && [ -f "$GRAPH" ] && is_work_unit "$SUBAGENT"; then
  STATUS=$(jq -r --arg id "$UNIT" '.tasks[$id].status // ""' "$GRAPH" 2>/dev/null || echo "")
  BLOCK=""
  case "$SUBAGENT" in
    *review-gate*)
      case "$STATUS" in DONE) BLOCK=1 ;; esac ;;
    *)
      case "$STATUS" in IMPLEMENTED|DONE) BLOCK=1 ;; esac ;;
  esac
  if [ -n "$BLOCK" ]; then
    SHA=$(jq -r --arg id "$UNIT" '.tasks[$id].commit // "?"' "$GRAPH" 2>/dev/null || echo "?")
    echo "NAZGUL CONDUCTOR: Blocked — $UNIT already $STATUS at $SHA; re-dispatch is wasted work (agents/conductor.md Step 5)." >&2
    exit 2
  fi
fi

exit 0
