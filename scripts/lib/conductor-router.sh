#!/usr/bin/env bash
# Nazgul conductor-router — thin backend router + wave-parallelism safety for
# the Conductor engine (FEAT-007). Pure policy + jq; agents/conductor.md (a
# later task) calls these functions and executes the returned decision with
# the real Task tool / team-orchestrator / EnterWorktree.
#
# Backend-agnostic choke point: route_unit() maps a unit descriptor to one of
# three in-session backends by required isolation — a future `claude -p`
# backend slots in later without changing callers (not built here).
#
# Wave-parallelism policy (route_wave()): a wave runs parallel ONLY when the
# Planner explicitly marked it a parallel group (never inferred from zero
# overlap alone) AND every unit's file_scope is overlap-free; ANY overlap
# aborts the whole wave to sequential (mirrors team-orchestrator's "verify NO
# file overlaps, abort if overlap detected" rule — not reimplemented here).
# Concurrency is capped at conductor.max_parallel (default 3, read via
# conductor-gates.sh's conductor_max_parallel); an over-cap group is chunked
# into ordered batches, never exceeding the cap.
#
# file_scope shape guard: defense-in-depth on the CONSUMING side — a unit
# whose file_scope contains a multi-line or diff-shaped entry is untrustworthy
# for overlap detection, so the whole wave falls back to sequential rather
# than risk a false "no overlap" read. (conductor-graph.sh's write-boundary
# validation is a separate follow-up; this guard only covers what this lib
# reads.)
#
# Idempotent source guard; NOT `set -euo pipefail` — sourced into hook shells
# alongside conductor-graph.sh / conductor-gates.sh.

[ -n "${_NAZGUL_CONDUCTOR_ROUTER_SOURCED:-}" ] && return 0
_NAZGUL_CONDUCTOR_ROUTER_SOURCED=1

_CR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CR_DIR/conductor-gates.sh"

# _router_entry_valid <entry> -> 0 iff a bare path: single-line, non-empty,
# not diff-shaped.
_router_entry_valid() {
  case "$1" in
    "") return 1 ;;
    *$'\n'*) return 1 ;;
    "diff --git"*|"@@"*|"+++"*|"--- "*|"index "*) return 1 ;;
  esac
  return 0
}

# router_validate_file_scope <file_scope_json> -> 0 silently if every entry is
# a valid bare path; else prints "INVALID_FILE_SCOPE_ENTRY <index>" per bad
# entry and returns 1. Malformed (non-array) JSON also returns 1.
router_validate_file_scope() {
  local file_scope_json="$1" count i entry problems=0
  count=$(jq 'length' <<< "$file_scope_json" 2>/dev/null) || { echo "INVALID_FILE_SCOPE_SHAPE"; return 1; }
  i=0
  while [ "$i" -lt "$count" ]; do
    entry=$(jq -r --argjson i "$i" '.[$i]' <<< "$file_scope_json" 2>/dev/null)
    if ! _router_entry_valid "$entry"; then
      echo "INVALID_FILE_SCOPE_ENTRY $i"
      problems=1
    fi
    i=$((i + 1))
  done
  [ "$problems" -eq 0 ]
}

# route_backend <kind> [isolation] -> prints the in-session backend:
#   kind == "review"        -> subagent (always, reviews are read-only)
#   isolation == "mutation"    -> worktree (parallel file-mutating unit)
#   isolation == "coordination" -> team (parallel wave needing live SendMessage)
#   anything else/unclear      -> subagent (bounded/read-heavy fallback)
route_backend() {
  local kind="$1" isolation="${2:-}"
  if [ "$kind" = "review" ]; then
    echo "subagent"
    return 0
  fi
  case "$isolation" in
    mutation)     echo "worktree" ;;
    coordination) echo "team" ;;
    *)            echo "subagent" ;;
  esac
}

# route_unit <unit_json> -> prints {"backend", "dispatch"} where dispatch
# names the concrete mechanism a backend reuses. Single backend-agnostic
# choke point: agents/conductor.md calls only this, never route_backend
# directly, for unit-level decisions.
route_unit() {
  local unit_json="$1" kind isolation backend dispatch
  kind=$(jq -r '.kind // "task"' <<< "$unit_json" 2>/dev/null)
  isolation=$(jq -r '.isolation // ""' <<< "$unit_json" 2>/dev/null)
  backend=$(route_backend "$kind" "$isolation")
  case "$backend" in
    team)     dispatch="team-orchestrator" ;;
    worktree) dispatch="EnterWorktree" ;;
    *)        dispatch="Task tool" ;;
  esac
  jq -n --arg backend "$backend" --arg dispatch "$dispatch" '{backend: $backend, dispatch: $dispatch}'
}

# _router_has_overlap <units_json> -> 0 (found) iff any file_scope path is
# shared by two or more units; 1 (none) otherwise. Duplicates within a single
# unit's own file_scope are not overlap.
_router_has_overlap() {
  jq -e '
    [ .[] | (.file_scope // [] | unique)[] ] as $all
    | ($all | length) != ($all | unique | length)
  ' <<< "$1" > /dev/null 2>&1
}

# _router_sequential_result <ids_json_array> <reason> -> prints the
# {dispatch, reason, batches} result for a sequential wave (one unit per
# batch, original order preserved).
_router_sequential_result() {
  jq -n --argjson ids "$1" --arg reason "$2" \
    '{dispatch: "sequential", reason: $reason, batches: ($ids | map([.]))}'
}

# _router_parallel_result <ids_json_array> <max_parallel> -> prints the
# {dispatch, reason, batches} result for a parallel wave, chunked into
# ordered batches never exceeding max_parallel (cap floors at 1).
_router_parallel_result() {
  local ids_json="$1" cap="$2"
  [ "$cap" -ge 1 ] 2>/dev/null || cap=1
  jq -n --argjson ids "$ids_json" --argjson cap "$cap" '
    def chunk(n): def c: if length <= n then [.] else [.[0:n]] + (.[n:] | c) end; c;
    { dispatch: "parallel", reason: "zero-overlap Planner-marked parallel group", batches: ($ids | chunk($cap)) }
  '
}

# route_wave <units_json> <marked_parallel> [config_file] -> prints
# {dispatch, reason, batches} where units_json is
# [{"id": "TASK-001", "file_scope": [...]}, ...] in wave order, and
# marked_parallel is "true" only when the Planner explicitly marked this wave
# a parallel group (unmarked always runs sequential, even at zero overlap).
# max_parallel is read via conductor_max_parallel(config_file) — default 3
# when config_file is empty/missing, single source of truth in
# conductor-gates.sh.
route_wave() {
  local units_json="$1" marked_parallel="$2" config_file="${3:-}" max_parallel
  max_parallel=$(conductor_max_parallel "$config_file")

  local ids
  ids=$(jq -c '[.[].id]' <<< "$units_json")

  local n i fs
  n=$(jq 'length' <<< "$units_json" 2>/dev/null) || n=0
  i=0
  while [ "$i" -lt "$n" ]; do
    fs=$(jq -c --argjson i "$i" '.[$i].file_scope // []' <<< "$units_json")
    if ! router_validate_file_scope "$fs" > /dev/null; then
      _router_sequential_result "$ids" "invalid file_scope shape"
      return 0
    fi
    i=$((i + 1))
  done

  if [ "$marked_parallel" != "true" ]; then
    _router_sequential_result "$ids" "not Planner-marked parallel group"
    return 0
  fi

  if _router_has_overlap "$units_json"; then
    _router_sequential_result "$ids" "file overlap detected in wave"
    return 0
  fi

  _router_parallel_result "$ids" "$max_parallel"
}
