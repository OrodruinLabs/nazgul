#!/usr/bin/env bash
# Nazgul conductor-gates — gate evaluation + hard stops for the Conductor
# engine (FEAT-007). Autonomous-first: conductor.gates.* default false, so a
# stored gate degrades to "no pause" whenever it can't be read. The two hard
# stops (BLOCKED task, security rejection) are the opposite: they fail CLOSED
# on ambiguity and are not routable-around by any gate/mode value, including
# yolo. mode == "hitl" flips the EFFECTIVE approve_graph value on without
# mutating the stored config (TASK-001 keeps the stored default false).
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into hook shells
# alongside conductor-graph.sh / review-evidence.sh.

[ -n "${_NAZGUL_CONDUCTOR_GATES_SOURCED:-}" ] && return 0
_NAZGUL_CONDUCTOR_GATES_SOURCED=1

_CGATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CGATE_DIR/task-utils.sh"

# conductor_execution_engine <config_file> -> prints execution.engine,
# default "sequential" when missing/unreadable.
conductor_execution_engine() {
  local config="$1"
  [ -f "$config" ] || { echo "sequential"; return 0; }
  jq -r '.execution.engine // "sequential"' "$config" 2>/dev/null || echo "sequential"
}

# conductor_max_parallel <config_file> -> prints conductor.max_parallel,
# default 3 when missing/unreadable.
conductor_max_parallel() {
  local config="$1"
  [ -f "$config" ] || { echo "3"; return 0; }
  jq -r '.conductor.max_parallel // 3' "$config" 2>/dev/null || echo "3"
}

# conductor_gate_stored <config_file> <gate> -> prints the raw stored
# conductor.gates.<gate> value ("true"/"false"). Degrades to allow (prints
# "false") when the config is missing/unreadable or <gate> is not a
# recognized key — an unknown key resolves through jq's own `// false`.
conductor_gate_stored() {
  local config="$1" gate="$2" val
  [ -f "$config" ] || { echo "false"; return 0; }
  val=$(jq -r --arg g "$gate" '.conductor.gates[$g] // false' "$config" 2>/dev/null)
  [ "$val" = "true" ] && { echo "true"; return 0; }
  echo "false"
}

# conductor_gate_effective <config_file> <gate> <mode> -> prints the
# EFFECTIVE gate value ("true"/"false") for <mode>, computed at read time
# (never mutates the stored config): approve_graph is true when stored true
# OR mode == "hitl"; every other gate equals its stored value in every mode.
conductor_gate_effective() {
  local config="$1" gate="$2" mode="$3" stored
  stored=$(conductor_gate_stored "$config" "$gate")
  if [ "$gate" = "approve_graph" ] && [ "$mode" = "hitl" ]; then
    echo "true"
    return 0
  fi
  echo "$stored"
}

# conductor_should_pause <config_file> <gate> <mode> -> 0 if the conductor
# should pause for a human at <gate> under <mode>, else 1.
conductor_should_pause() {
  [ "$(conductor_gate_effective "$1" "$2" "$3")" = "true" ]
}

# _cgate_blocked_tasks <tasks_dir> -> one "BLOCKED_TASK <id>" line per task
# whose status is BLOCKED, or "BLOCKED_TASKS_AMBIGUOUS <id>" for a task whose
# status is INVALID/unparseable (also fails closed); 1 if any found. Fails
# CLOSED (prints "BLOCKED_TASKS_UNREADABLE", returns 1) when tasks_dir does
# not exist or is not readable — ambiguity about BLOCKED state is never
# degraded to allow.
_cgate_blocked_tasks() {
  local tasks_dir="$1" file id status found=0
  if [ ! -d "$tasks_dir" ] || [ ! -r "$tasks_dir" ]; then
    echo "BLOCKED_TASKS_UNREADABLE"
    return 1
  fi
  for file in "$tasks_dir"/TASK-*.md; do
    [ -f "$file" ] || continue
    id=$(basename "$file" .md)
    status=$(get_task_status "$file" "")
    case "$status" in
      BLOCKED) echo "BLOCKED_TASK $id"; found=1 ;;
      INVALID|"") echo "BLOCKED_TASKS_AMBIGUOUS $id"; found=1 ;;
    esac
  done
  [ "$found" -eq 0 ]
}

# _cgate_security_rejections <nazgul_dir> -> one "SECURITY_REJECTION <id>"
# line per task whose reviews/<id>/security-reviewer.md is not an APPROVE,
# or "SECURITY_REJECTION_AMBIGUOUS <id>" when the file is present but its
# verdict is missing (rc=1) or unparseable (rc=2) — both fail closed; 1 if
# any found. Fails CLOSED (prints "SECURITY_REVIEWS_UNREADABLE", returns 1)
# when nazgul_dir or reviews_dir exists but is not readable. A missing
# nazgul_dir/reviews_dir, or a task with no security-reviewer.md yet, is a
# normal not-yet-reviewed state — not ambiguous, no halt.
_cgate_security_rejections() {
  local nazgul_dir="$1" reviews_dir file id verdict rc found=0
  if [ ! -d "$nazgul_dir" ] || [ ! -r "$nazgul_dir" ]; then
    echo "SECURITY_REVIEWS_UNREADABLE"
    return 1
  fi
  reviews_dir="$nazgul_dir/reviews"
  [ -d "$reviews_dir" ] || return 0
  if [ ! -r "$reviews_dir" ]; then
    echo "SECURITY_REVIEWS_UNREADABLE"
    return 1
  fi
  for file in "$reviews_dir"/*/security-reviewer.md; do
    [ -f "$file" ] || continue
    id=$(basename "$(dirname "$file")")
    verdict=$(read_verdict "$file") && rc=0 || rc=$?
    case "$rc" in
      0) [ "$verdict" = "APPROVE" ] || { echo "SECURITY_REJECTION $id"; found=1; } ;;
      1|2) echo "SECURITY_REJECTION_AMBIGUOUS $id"; found=1 ;;
      *) : ;;
    esac
  done
  [ "$found" -eq 0 ]
}

# conductor_should_halt <nazgul_dir> -> prints one machine-parseable line per
# active hard stop (see _cgate_blocked_tasks / _cgate_security_rejections);
# 0 silently if clear to continue, 1 if the conductor must halt for a human.
# UNCONDITIONAL: not affected by any conductor.gates value or mode, incl.
# yolo — these two signals are never routable-around.
conductor_should_halt() {
  local nazgul_dir="$1" problems=0
  _cgate_blocked_tasks "$nazgul_dir/tasks" || problems=1
  _cgate_security_rejections "$nazgul_dir" || problems=1
  [ "$problems" -eq 0 ]
}
