#!/usr/bin/env bash
set -euo pipefail
# Nazgul Parallel Dispatch Guard — PreToolUse on the Agent tool.
# Enforces two Agent-dispatch contracts: configured reviewers are always
# unnamed foreground one-shot calls, and completed parallel work units are
# never re-dispatched. Reviewer routing applies in both execution modes;
# completed-unit enforcement applies only when execution.parallel is on.
# Exit 0 = allow. Exit 2 = deny (reason on stderr).

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

# A present-but-corrupt config cannot identify the reviewer roster, kill switch,
# or parallel mode, so fail closed instead of silently no-oping (MF-053,
# ADR-003 Decision 3).
[ -f "$CONFIG" ] || exit 0
jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "NAZGUL PARALLEL: Blocked — config.json is unreadable; cannot verify parallel-dispatch safety" >&2; exit 2; }
PARALLEL=$(jq -r '.execution.parallel // false' "$CONFIG")

# Kill-switch (explicit false disables; absent/true enabled).
ENFORCE=$(jq -r 'if .execution.enforce.dispatch_guard == null then "true" else (.execution.enforce.dispatch_guard|tostring) end' "$CONFIG" 2>/dev/null || echo "true")
[ "$ENFORCE" = "false" ] && exit 0

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/emit-event.sh"

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
[ "$TOOL" = "Agent" ] || exit 0
SUBAGENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null || echo "")
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null || echo "")

# Reviewer route invariant. The configured roster is authoritative, including
# project-generated reviewers; plugin namespaces are not part of roster names.
# A nested Agent context may omit run_in_background because the current host's
# nested schema is synchronous-only. The main session must state false
# explicitly because omission is ambiguous on background-by-default versions.
# On hosts whose Agent schema has no run_in_background field at all, omission
# is the ONLY possible payload (#205), so the missing case allows with a named
# event instead of blocking.
SUBAGENT_NAME="${SUBAGENT##*:}"
IS_REVIEWER=false
if jq -e --arg r "$SUBAGENT_NAME" \
  '(.agents.reviewers // []) | type == "array" and (index($r) != null)' \
  "$CONFIG" >/dev/null 2>&1; then
  IS_REVIEWER=true
fi

if [ "$IS_REVIEWER" = "true" ]; then
  DISPATCH_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_input.name // ""' 2>/dev/null || echo "")
  BACKGROUND_TYPE=$(printf '%s' "$INPUT" | jq -r '
    (.tool_input // {}) as $input
    | if ($input | has("run_in_background"))
      then ($input.run_in_background | type)
      else "missing"
      end' 2>/dev/null || echo "invalid")
  BACKGROUND_VALUE=$(printf '%s' "$INPUT" | jq -r '
    (.tool_input // {}) as $input
    | if ($input | has("run_in_background"))
      then ($input.run_in_background | tostring)
      else "missing"
      end' 2>/dev/null || echo "invalid")
  CALLER_TYPE=$(printf '%s' "$INPUT" | jq -r \
    '.agent_type // .agent_name // .caller.agent_type // ""' 2>/dev/null || echo "")
  NESTED_CALLER=false
  case "$CALLER_TYPE" in
    ""|main|primary) ;;
    *) NESTED_CALLER=true ;;
  esac

  if [ -n "$DISPATCH_NAME" ]; then
    echo "NAZGUL REVIEW DISPATCH: Blocked — ${SUBAGENT_NAME} must be an unnamed one-shot Agent call; remove tool_input.name." >&2
    exit 2
  fi
  if [ "$BACKGROUND_TYPE" != "missing" ] \
    && { [ "$BACKGROUND_TYPE" != "boolean" ] || [ "$BACKGROUND_VALUE" != "false" ]; }; then
    echo "NAZGUL REVIEW DISPATCH: Blocked — ${SUBAGENT_NAME} must run in the foreground with run_in_background:false." >&2
    exit 2
  fi
  if [ "$BACKGROUND_TYPE" = "missing" ] && [ "$NESTED_CALLER" != "true" ]; then
    # #205: the hook payload cannot distinguish "schema lacks the field" from
    # "caller omitted it", and on schemas without the field it is unsupplyable
    # — a block here disables the entire review board. ADR-009 cost-weighing:
    # a false BLOCK costs the review discipline; a false ALLOW is bounded by
    # FEAT-024's empty-return detection and this guard's other checks. Allow,
    # and record that verifiability was ABSENT, not confirmed.
    echo "NAZGUL REVIEW DISPATCH: Allowed — run_in_background absent from the payload (#205: unsupplyable on schemas without the field). Background-verifiability recorded as absent, not assumed." >&2
    emit_event "dispatch_guard_background_unverifiable" agent "$SUBAGENT_NAME" caller "${CALLER_TYPE:-main}"
  fi
fi

# Background/concurrent dispatch of non-review work is the intended mechanism
# in parallel mode. The completed-unit check below has no work when it is off.
[ "$PARALLEL" = "true" ] || exit 0

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
# canonical state, no stored graph. An IMPLEMENTED unit still needs its
# review-gate dispatch; a DONE or CANCELLED unit's does not (ADR-022).
UNIT=$(printf '%s' "$PROMPT" | grep -oE 'NAZGUL_UNIT: TASK-[0-9]+' | head -1 | sed 's/^NAZGUL_UNIT: //' || true)
if [ -n "$UNIT" ] && [ -f "$TASKS_DIR/$UNIT.md" ] && is_work_unit "$SUBAGENT"; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/task-utils.sh"
  STATUS=$(get_task_status "$TASKS_DIR/$UNIT.md" "")
  BLOCK=""
  case "$SUBAGENT" in
    *review-gate*) case "$STATUS" in DONE|CANCELLED) BLOCK=1 ;; esac ;;
    *)             case "$STATUS" in IMPLEMENTED|DONE|CANCELLED) BLOCK=1 ;; esac ;;
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
