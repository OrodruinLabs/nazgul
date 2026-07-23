#!/usr/bin/env bash
set -euo pipefail
# Nazgul Parallel Dispatch Guard — PreToolUse on the Agent tool.
# Enforces the no-re-dispatch contract for the execution.parallel dispatch
# option: a work unit already IMPLEMENTED/DONE is never re-dispatched.
# Background/concurrent dispatch itself is the intended mechanism under
# execution.parallel, so it is not restricted here. No-op unless
# execution.parallel is on. Exit 0 = allow. Exit 2 = deny (reason on stderr).

INPUT="${1:-}"
[ -z "$INPUT" ] && INPUT=$(cat 2>/dev/null || echo "")
[ -z "$INPUT" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

NAZGUL_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}/nazgul"
CONFIG="$NAZGUL_DIR/config.json"
TASKS_DIR="$NAZGUL_DIR/tasks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Scope: only when the parallel dispatch option is on. A present-but-corrupt
# config can't be trusted to say "parallel is off", so it fails closed instead
# of silently no-opping (MF-053, ADR-003 Decision 3).
[ -f "$CONFIG" ] || exit 0
jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "NAZGUL PARALLEL: Blocked — config.json is unreadable; cannot verify parallel-dispatch safety" >&2; exit 2; }
PARALLEL=$(jq -r '.execution.parallel // false' "$CONFIG")
[ "$PARALLEL" = "true" ] || exit 0

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .execution.enforce.dispatch_guard == null then "true" else (.execution.enforce.dispatch_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Agent" ] || exit 0
SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

is_work_unit() {
  case "$1" in
    *implementer*|*review-gate*|*team-orchestrator*) return 0 ;;
    *) return 1 ;;
  esac
}

# Never re-dispatch a completed unit. Prompt carries `NAZGUL_UNIT: TASK-NNN`
# (grepped as data — never eval'd). Status source is the task manifest —
# canonical state, no stored graph. An IMPLEMENTED unit still legitimately
# needs its review-gate dispatch; only a DONE unit's review is wasted work.
UNIT=$(printf '%s' "$PROMPT" | grep -oE 'NAZGUL_UNIT: TASK-[0-9]+' | head -1 | sed 's/^NAZGUL_UNIT: //' || true)
if [ -n "$UNIT" ] && [ -f "$TASKS_DIR/$UNIT.md" ] && is_work_unit "$SUBAGENT"; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/task-utils.sh"
  STATUS=$(get_task_status "$TASKS_DIR/$UNIT.md" "")
  BLOCK=""
  case "$SUBAGENT" in
    *review-gate*) case "$STATUS" in DONE) BLOCK=1 ;; esac ;;
    *)             case "$STATUS" in IMPLEMENTED|DONE) BLOCK=1 ;; esac ;;
  esac
  if [ -n "$BLOCK" ]; then
    echo "NAZGUL PARALLEL: Blocked — $UNIT already $STATUS; re-dispatch is wasted work." >&2
    exit 2
  fi
fi
exit 0
