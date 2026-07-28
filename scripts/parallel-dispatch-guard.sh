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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/nazgul-root.sh"

NAZGUL_DIR="$(resolve_nazgul_dir)"
CONFIG="$NAZGUL_DIR/config.json"
TASKS_DIR="$NAZGUL_DIR/tasks"

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

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/emit-event.sh"

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

# Resolution-integrity check — NOT an objective-identity check. It only
# catches TASKS_DIR failing to canonicalize as a real child of NAZGUL_DIR
# (e.g. nazgul/tasks symlinked outside the resolved tree). It CANNOT detect
# a stale or cross-objective NAZGUL_UNIT token that names a real task in a
# different but internally-valid nazgul/ tree: task manifests carry no
# feat_id and NAZGUL_UNIT carries no objective anchor to check it against.
# Closing that gap needs an objective anchor on the dispatch token itself —
# cut from this objective's scope on cost/benefit grounds (plan.md scope
# item 4; TRD.md Proposed Changes items 4-5).
_resolution_integrity_ok() {
  local nd_real td_real
  nd_real=$(cd "$NAZGUL_DIR" 2>/dev/null && pwd -P) || return 1
  td_real=$(cd "$TASKS_DIR" 2>/dev/null && pwd -P) || return 1
  case "$td_real" in "$nd_real"/*) return 0 ;; *) return 1 ;; esac
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
    # Only checked before trusting a BLOCK verdict, so it never emits
    # ambiguity telemetry on requests that would have been allowed anyway.
    if ! _resolution_integrity_ok; then
      echo "NAZGUL PARALLEL: Allowed — $UNIT failed the tasks-dir resolution-integrity check (not an objective-identity check); failing open per PRD AC 3." >&2
      emit_event "dispatch_guard_resolution_unconfirmed" unit "$UNIT" subagent "$SUBAGENT"
      exit 0
    fi
    echo "NAZGUL PARALLEL: Blocked — $UNIT already $STATUS; re-dispatch is wasted work." >&2
    exit 2
  fi
fi
exit 0
