#!/usr/bin/env bash
# Nazgul parallel-batch — deterministic batch selection, gates, and hard stops
# for the parallel dispatch option (execution.parallel). Replaces the deleted
# conductor engine's conductor-graph.sh (compute_waves) and conductor-gates.sh
# (gates + hard stops). Task manifests are the ONLY state source — there is no
# stored graph.
#
# Idempotent source guard; NOT `set -euo pipefail` (sourced into hook shells).

[ -n "${_NAZGUL_PARALLEL_BATCH_SOURCED:-}" ] && return 0
_NAZGUL_PARALLEL_BATCH_SOURCED=1

_PB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_PB_DIR/task-utils.sh"

# _pb_task_map_from_dir <tasks_dir> -> prints {"<id>": {"deps": [...], "status": "..."}}
# built from each TASK-*.md's "Depends on" list-item field + canonical status.
_pb_task_map_from_dir() {
  local tasks_dir="$1"
  local file id status deps_raw d
  local -a objs=() dep_list
  for file in "$tasks_dir"/TASK-*.md; do
    [ -f "$file" ] || continue
    id=$(basename "$file" .md)
    status=$(get_task_status "$file" "PLANNED")
    deps_raw=$(get_task_field "$file" "Depends on" "none")
    deps_raw="${deps_raw//,/ }"
    dep_list=()
    for d in $deps_raw; do
      case "$d" in
        none|None|NONE|"") continue ;;
        *) dep_list+=("$d") ;;
      esac
    done
    local deps_json="[]"
    [ "${#dep_list[@]}" -gt 0 ] && deps_json=$(printf '%s\n' "${dep_list[@]}" | jq -R . | jq -s .)
    objs+=("$(jq -n --arg id "$id" --arg status "$status" --argjson deps "$deps_json" \
      '{key: $id, value: {deps: $deps, status: $status}}')")
  done
  if [ "${#objs[@]}" -eq 0 ]; then
    echo "{}"
  else
    printf '%s\n' "${objs[@]}" | jq -s 'from_entries'
  fi
}

# _pb_layer_waves <task_map_json> -> prints wave partition JSON (Kahn-style
# topological layering); non-zero exit + stderr message on cycle/unknown dep.
_pb_layer_waves() {
  local task_map="$1" unknown err
  unknown=$(jq -r '. as $m | [ to_entries[] | .value.deps[]? as $d | select($m[$d] == null) | $d ] | unique | .[]' \
    <<< "$task_map" 2>/dev/null)
  if [ -n "$unknown" ]; then
    echo "compute_waves: unknown dependency id(s): $(tr '\n' ' ' <<< "$unknown" | sed 's/ *$//')" >&2
    return 1
  fi

  if ! err=$(jq -c '
    (to_entries | map(select(.value.status == "DONE")) | map(.key)) as $done0
    | (to_entries | map(select(.value.status != "DONE")) | map(.key) | sort) as $pending0
    | . as $tasks
    | [$done0, $pending0, 1, []]
    | until(
        (.[1] | length) == 0;
        . as $s
        | ($s[0]) as $done | ($s[1]) as $pending | ($s[2]) as $wn | ($s[3]) as $acc
        | ( $pending
            | map(select(. as $id | ($tasks[$id].deps // []) | all(. as $d | $done | index($d) != null)))
            | sort
          ) as $ready
        | if ($ready | length) == 0 then
            error("CYCLE:" + ($pending | join(",")))
          else
            [ ($done + $ready), ($pending - $ready), ($wn + 1), ($acc + [{wave: $wn, units: $ready}]) ]
          end
      )
    | .[3]
  ' <<< "$task_map" 2>&1); then
    case "$err" in
      *CYCLE:*) echo "compute_waves: cycle detected among tasks: ${err#*CYCLE:}" >&2 ;;
      *)        echo "compute_waves: $err" >&2 ;;
    esac
    return 1
  fi
  printf '%s\n' "$err"
}

# compute_waves <tasks_dir> -> prints wave partition JSON:
# [{"wave": 1, "units": ["TASK-001", ...]}, ...]. DONE tasks are excluded
# entirely; a fully-DONE or empty graph yields "[]". Rejects (non-zero exit,
# stderr message) rather than looping when a cycle or unknown dependency id
# is found.
compute_waves() {
  local input="$1" task_map
  if [ -d "$input" ]; then
    task_map=$(_pb_task_map_from_dir "$input") || return 1
  else
    echo "compute_waves: input not found: $input" >&2
    return 1
  fi
  _pb_layer_waves "$task_map"
}

# execution_parallel_enabled <config> -> "true"/"false" (default false)
execution_parallel_enabled() {
  local config="$1" val
  [ -f "$config" ] || { echo "false"; return 0; }
  val=$(jq -r '.execution.parallel // false' "$config" 2>/dev/null)
  [ "$val" = "true" ] && { echo "true"; return 0; }
  echo "false"
}

# execution_max_parallel <config> -> int (default 3)
execution_max_parallel() {
  local config="$1"
  [ -f "$config" ] || { echo "3"; return 0; }
  jq -r '.execution.max_parallel // 3' "$config" 2>/dev/null || echo "3"
}

# execution_gate_stored <config> <gate> -> stored .execution.gates.<gate>
execution_gate_stored() {
  local config="$1" gate="$2" val
  [ -f "$config" ] || { echo "false"; return 0; }
  val=$(jq -r --arg g "$gate" '.execution.gates[$g] // false' "$config" 2>/dev/null)
  [ "$val" = "true" ] && { echo "true"; return 0; }
  echo "false"
}

# execution_gate_effective <config> <gate> <mode> — approve_plan flips true in
# hitl (same rule the conductor gave approve_graph); others equal stored value.
execution_gate_effective() {
  local config="$1" gate="$2" mode="$3"
  if [ "$gate" = "approve_plan" ] && [ "$mode" = "hitl" ]; then
    echo "true"; return 0
  fi
  execution_gate_stored "$config" "$gate"
}

execution_should_pause() {
  [ "$(execution_gate_effective "$1" "$2" "$3")" = "true" ]
}

# _pb_blocked_tasks <tasks_dir> -> one "BLOCKED_TASK <id>" line per task
# whose status is BLOCKED, or "BLOCKED_TASKS_AMBIGUOUS <id>" for a task whose
# status is INVALID/unparseable (also fails closed); 1 if any found. Fails
# CLOSED (prints "BLOCKED_TASKS_UNREADABLE", returns 1) when tasks_dir does
# not exist or is not readable — ambiguity about BLOCKED state is never
# degraded to allow.
_pb_blocked_tasks() {
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

# _pb_security_rejections <nazgul_dir> -> one "SECURITY_REJECTION <id>"
# line per task whose reviews/<id>/security-reviewer.md is a non-APPROVE,
# assessed verdict (e.g. CHANGES_REQUESTED), or a distinct "SECURITY_UNVERIFIED
# <id>" when the verdict is UNVERIFIED — a security reviewer that could not
# assess also HALTS (never proceeds), the line just separates "couldn't assess"
# from "rejected". "SECURITY_REJECTION_AMBIGUOUS <id>" covers a file present but
# its verdict missing (rc=1) or unparseable (rc=2) — both fail closed; 1 if any
# found. Fails CLOSED (prints "SECURITY_REVIEWS_UNREADABLE", returns 1) when
# nazgul_dir or reviews_dir exists but is not readable. A missing
# nazgul_dir/reviews_dir, or a task with no security-reviewer.md yet, is a
# normal not-yet-reviewed state — not ambiguous, no halt.
_pb_security_rejections() {
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
      0)
        case "$verdict" in
          APPROVE) ;;
          UNVERIFIED) echo "SECURITY_UNVERIFIED $id"; found=1 ;;
          *) echo "SECURITY_REJECTION $id"; found=1 ;;
        esac
        ;;
      1|2) echo "SECURITY_REJECTION_AMBIGUOUS $id"; found=1 ;;
      *) echo "SECURITY_REJECTION_AMBIGUOUS $id"; found=1 ;;
    esac
  done
  [ "$found" -eq 0 ]
}

# execution_should_halt <nazgul_dir> — UNCONDITIONAL hard stops: any BLOCKED
# task, any non-APPROVE security verdict. Not routable-around by any gate or
# mode, including yolo. Ambiguity fails closed.
execution_should_halt() {
  local nazgul_dir="$1" problems=0
  _pb_blocked_tasks "$nazgul_dir/tasks" || problems=1
  _pb_security_rejections "$nazgul_dir" || problems=1
  [ "$problems" -eq 0 ]
}

# compute_dispatch_batch <tasks_dir> <plan_md> <max_parallel>
# -> {"tasks": [...], "parallel": bool, "reason": "..."}
# Deterministic batch selection (spec §2). Every doubt falls back to a batch of
# one (proven sequential behavior). A multi-task batch requires: >=2 candidates
# (READY, all deps DONE) that are members of the same plan.md "### Wave N"
# section (one-bullet-per-task or comma-grouped, any mix), with pairwise-
# disjoint "Files modified" scopes, capped at max_parallel.
compute_dispatch_batch() {
  local tasks_dir="$1" plan_md="$2" max_parallel="$3"
  case "$max_parallel" in ''|*[!0-9]*|0) max_parallel=3 ;; esac

  local file id status deps_raw d ok
  local -a candidates=()
  for file in "$tasks_dir"/TASK-*.md; do
    [ -f "$file" ] || continue
    id=$(basename "$file" .md)
    status=$(get_task_status "$file" "PLANNED")
    [ "$status" = "READY" ] || continue
    deps_raw=$(get_task_field "$file" "Depends on" "none")
    deps_raw="${deps_raw//,/ }"
    ok=1
    for d in $deps_raw; do
      case "$d" in none|None|NONE|"") continue ;; esac
      [ -f "$tasks_dir/$d.md" ] || { ok=0; break; }
      [ "$(get_task_status "$tasks_dir/$d.md" "PLANNED")" = "DONE" ] || { ok=0; break; }
    done
    [ "$ok" -eq 1 ] && candidates+=("$id")
  done

  if [ "${#candidates[@]}" -eq 0 ]; then
    jq -n '{tasks: [], parallel: false, reason: "no dispatchable tasks"}'
    return 0
  fi

  _pb_single_result() {
    jq -n --arg t "${candidates[0]}" --arg r "$1" \
      '{tasks: [$t], parallel: false, reason: $r}'
  }

  if [ "${#candidates[@]}" -eq 1 ]; then
    _pb_single_result "single candidate"; return 0
  fi
  if [ ! -f "$plan_md" ] || ! grep -q '^## Wave Groups' "$plan_md"; then
    _pb_single_result "no Wave Groups section in plan.md"; return 0
  fi

  # Membership: each "### Wave N" heading owns every "- TASK-NNN" bullet that
  # follows it (until the next heading), one-per-line or comma-grouped or a
  # mix of both. First wave (document order) with >=2 candidate members wins.
  local cur_wave="" line lid
  local -A wave_members=()
  local -a wave_order=()
  while IFS= read -r line; do
    case "$line" in
      '### '*)
        cur_wave="$line"
        wave_order+=("$cur_wave")
        wave_members["$cur_wave"]=""
        continue
        ;;
    esac
    [ -n "$cur_wave" ] || continue
    case "$line" in '- '*) ;; *) continue ;; esac
    for lid in $(printf '%s' "$line" | grep -oE 'TASK-[0-9]+'); do
      wave_members["$cur_wave"]+="$lid "
    done
  done < <(sed -n '/^## Wave Groups/,/^## [^#]/p' "$plan_md")

  local cand_padded=" ${candidates[*]} "
  local -a batch=()
  for cur_wave in "${wave_order[@]}"; do
    batch=()
    for lid in ${wave_members[$cur_wave]}; do
      case "$cand_padded" in *" $lid "*) ;; *) continue ;; esac
      case " ${batch[*]:-} " in *" $lid "*) continue ;; esac
      batch+=("$lid")
    done
    [ "${#batch[@]}" -ge 2 ] && break
    batch=()
  done

  if [ "${#batch[@]}" -lt 2 ]; then
    _pb_single_result "no wave group with >=2 ready tasks"; return 0
  fi

  # Cap at max_parallel, keep membership order.
  if [ "${#batch[@]}" -gt "$max_parallel" ]; then
    batch=("${batch[@]:0:$max_parallel}")
  fi

  # Pairwise-disjoint "Files modified" scopes via the shared JSON-array
  # accessor; missing/empty/malformed scope -> fallback.
  local m files all=""
  for m in "${batch[@]}"; do
    files=$(get_task_files_modified "$tasks_dir/$m.md" 2>/dev/null)
    if [ -z "$files" ]; then
      _pb_single_result "missing file scope for $m"; return 0
    fi
    all+="$files"$'\n'
  done
  local dup
  dup=$(printf '%s\n' "$all" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' | sort | uniq -d | head -1)
  if [ -n "$dup" ]; then
    _pb_single_result "file scope overlap: $dup"; return 0
  fi

  printf '%s\n' "${batch[@]}" | jq -R . | jq -s \
    '{tasks: ., parallel: true, reason: "wave group, disjoint scopes"}'
}
