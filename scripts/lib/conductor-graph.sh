#!/usr/bin/env bash
# Nazgul conductor-graph — pure, unit-testable state logic for the Conductor
# engine (FEAT-007). NO agent behavior lives here; agents/conductor.md (a
# later task) calls these functions to drive a build wave by wave.
#
# graph.json schema (nazgul/conductor/graph.json) — the ONLY mutable
# conductor state, graph-shaped, NEVER file bodies:
#   {
#     "schema": 1,
#     "objective": "FEAT-007",
#     "engine": "conductor",
#     "waves": [ { "wave": 1, "units": ["TASK-001"], "parallel": true, "status": "done" } ],
#     "tasks": {
#       "TASK-001": {
#         "deps": [], "wave": 1, "status": "DONE",
#         "file_scope": ["agents/conductor.md"],
#         "verdict": "APPROVE — all reviewers passed",   # one line only
#         "commit": "abc1234"                              # bare SHA only
#       }
#     },
#     "gates": { "approve_graph": false, "approve_each_wave": false, "approve_final_pr": false },
#     "max_parallel": 3,
#     "budgets": { "tokens_est": null }
#   }
#
# Graph-only invariant: `verdict` must be a single line and not diff-shaped;
# `commit` must be a bare SHA (7-40 hex chars) or empty. validate_graph_json
# rejects any task entry that violates this.
#
# Idempotent source guard: no top-level side effects beyond function/var
# definitions when sourced; safe to `source` from another lib or hook shell.
# NOT `set -euo pipefail` for the same reason as review-provenance.sh.

[ -n "${_NAZGUL_CONDUCTOR_GRAPH_SOURCED:-}" ] && return 0
_NAZGUL_CONDUCTOR_GRAPH_SOURCED=1

_CG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CG_DIR/task-utils.sh"

# _cg_task_map_from_dir <tasks_dir> -> prints {"<id>": {"deps": [...], "status": "..."}}
# built from each TASK-*.md's "Depends on" list-item field + canonical status.
_cg_task_map_from_dir() {
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

# _cg_task_map_from_graph <graph_file> -> prints {"<id>": {"deps": [...], "status": "..."}}
# extracted from a graph.json's .tasks (ignores file_scope/verdict/commit).
_cg_task_map_from_graph() {
  jq '.tasks // {} | to_entries | map({key, value: {deps: (.value.deps // []), status: .value.status}}) | from_entries' \
    "$1"
}

# _cg_layer_waves <task_map_json> -> prints wave partition JSON (Kahn-style
# topological layering); non-zero exit + stderr message on cycle/unknown dep.
_cg_layer_waves() {
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

# compute_waves <tasks_dir|graph_json_file> -> prints wave partition JSON:
# [{"wave": 1, "units": ["TASK-001", ...]}, ...]. DONE tasks are excluded
# entirely; a fully-DONE or empty graph yields "[]". Rejects (non-zero exit,
# stderr message) rather than looping when a cycle or unknown dependency id
# is found.
compute_waves() {
  local input="$1" task_map
  if [ -d "$input" ]; then
    task_map=$(_cg_task_map_from_dir "$input") || return 1
  elif [ -f "$input" ]; then
    task_map=$(_cg_task_map_from_graph "$input") || return 1
  else
    echo "compute_waves: input not found: $input" >&2
    return 1
  fi
  _cg_layer_waves "$task_map"
}

# _cg_verdict_valid <verdict> -> 0 iff single-line and not diff-shaped.
_cg_verdict_valid() {
  case "$1" in
    *$'\n'*) return 1 ;;
    "diff --git"*|"@@"*|"+++"*|"--- "*|"index "*) return 1 ;;
  esac
  return 0
}

# _cg_commit_valid <commit> -> 0 iff empty or a bare 7-40 char hex SHA.
_cg_commit_valid() {
  local c="$1" len
  [ -z "$c" ] && return 0
  case "$c" in
    *[!0-9a-f]*) return 1 ;;
  esac
  len=${#c}
  [ "$len" -ge 7 ] && [ "$len" -le 40 ]
}

# init_graph_json <graph_file> <objective> [engine] [max_parallel] -> creates
# the schema skeleton if graph_file does not already exist (idempotent).
init_graph_json() {
  local graph_file="$1" objective="$2" engine="${3:-conductor}" max_parallel="${4:-3}" tmp
  [ -f "$graph_file" ] && return 0
  case "$max_parallel" in
    ''|*[!0-9]*) max_parallel=3 ;;
    0) max_parallel=3 ;;
  esac
  mkdir -p "$(dirname "$graph_file")" || return 1
  tmp=$(mktemp) || return 1
  if ! jq -n \
    --arg objective "$objective" \
    --arg engine "$engine" \
    --argjson max_parallel "$max_parallel" \
    '{
      schema: 1,
      objective: $objective,
      engine: $engine,
      waves: [],
      tasks: {},
      gates: { approve_graph: false, approve_each_wave: false, approve_final_pr: false },
      max_parallel: $max_parallel,
      budgets: { tokens_est: null }
    }' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$graph_file"
}

# graph_upsert_task <graph_file> <task_id> <deps_json> <wave> <status>
#   <file_scope_json> [verdict] [commit]
# Rejects (no write) if verdict/commit violate the graph-only invariant.
graph_upsert_task() {
  local graph_file="$1" task_id="$2" deps_json="$3" wave="$4" status="$5" file_scope_json="$6"
  local verdict="${7:-}" commit="${8:-}" tmp
  [ -f "$graph_file" ] || return 1
  _cg_verdict_valid "$verdict" || { echo "graph_upsert_task: verdict must be single-line, non-diff-shaped" >&2; return 1; }
  _cg_commit_valid "$commit" || { echo "graph_upsert_task: commit must be a bare SHA (7-40 hex chars) or empty" >&2; return 1; }
  tmp=$(mktemp) || return 1
  if ! jq \
    --arg id "$task_id" \
    --argjson deps "$deps_json" \
    --argjson wave "$wave" \
    --arg status "$status" \
    --argjson file_scope "$file_scope_json" \
    --arg verdict "$verdict" \
    --arg commit "$commit" \
    '.tasks[$id] = { deps: $deps, wave: $wave, status: $status, file_scope: $file_scope, verdict: $verdict, commit: $commit }' \
    "$graph_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$graph_file"
}

# graph_set_waves <graph_file> <waves_json> -> overwrites .waves.
graph_set_waves() {
  local graph_file="$1" waves_json="$2" tmp
  [ -f "$graph_file" ] || return 1
  tmp=$(mktemp) || return 1
  if ! jq --argjson waves "$waves_json" '.waves = $waves' "$graph_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$graph_file"
}

# graph_update_task_status <graph_file> <task_id> <new_status> -> 1 if the
# task is not present in .tasks.
graph_update_task_status() {
  local graph_file="$1" task_id="$2" new_status="$3" exists tmp
  [ -f "$graph_file" ] || return 1
  exists=$(jq --arg id "$task_id" '(.tasks // {}) | has($id)' "$graph_file")
  [ "$exists" = "true" ] || return 1
  tmp=$(mktemp) || return 1
  if ! jq --arg id "$task_id" --arg status "$new_status" '.tasks[$id].status = $status' "$graph_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$graph_file"
}

# graph_set_verdict <graph_file> <task_id> <verdict> [commit] -> rejects (no
# write) if verdict/commit violate the graph-only invariant, or the task is
# not present in .tasks.
graph_set_verdict() {
  local graph_file="$1" task_id="$2" verdict="$3" commit="${4:-}" exists tmp
  [ -f "$graph_file" ] || return 1
  _cg_verdict_valid "$verdict" || { echo "graph_set_verdict: verdict must be single-line, non-diff-shaped" >&2; return 1; }
  _cg_commit_valid "$commit" || { echo "graph_set_verdict: commit must be a bare SHA (7-40 hex chars) or empty" >&2; return 1; }
  exists=$(jq --arg id "$task_id" '(.tasks // {}) | has($id)' "$graph_file")
  [ "$exists" = "true" ] || return 1
  tmp=$(mktemp) || return 1
  if ! jq --arg id "$task_id" --arg v "$verdict" --arg c "$commit" \
    '.tasks[$id].verdict = $v | .tasks[$id].commit = $c' "$graph_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$graph_file"
}

# graph_mark_dispatched <graph_file> <task_id> -> sets .tasks[id].dispatched =
# true (never cleared — subagent-stop.sh's orphan detector also requires
# non-terminal status, so a unit reaching DONE/BLOCKED naturally stops
# matching). 1 if the task is not present in .tasks, mirroring
# graph_update_task_status's shape.
graph_mark_dispatched() {
  local graph_file="$1" task_id="$2" exists tmp
  [ -f "$graph_file" ] || return 1
  exists=$(jq --arg id "$task_id" '(.tasks // {}) | has($id)' "$graph_file")
  [ "$exists" = "true" ] || return 1
  tmp=$(mktemp) || return 1
  if ! jq --arg id "$task_id" '.tasks[$id].dispatched = true' "$graph_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$graph_file"
}

# validate_graph_json <graph_file> -> 0 silently if valid; else 1 with one
# machine-parseable line per problem:
#   NOT_JSON | MISSING_FIELD <name> | INVALID_TASK_STATUS <id> |
#   INVALID_VERDICT <id> (graph-only invariant) | INVALID_COMMIT <id>
validate_graph_json() {
  local graph_file="$1"
  if [ ! -f "$graph_file" ] || ! jq empty "$graph_file" 2>/dev/null; then
    echo "NOT_JSON"
    return 1
  fi

  local problems=0 field
  for field in schema objective engine waves tasks gates max_parallel budgets; do
    if [ "$(jq --arg f "$field" 'has($f)' "$graph_file")" != "true" ]; then
      echo "MISSING_FIELD $field"
      problems=$((problems + 1))
    fi
  done

  local ids id status verdict commit
  ids=$(jq -r '.tasks // {} | keys[]' "$graph_file" 2>/dev/null)
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    status=$(jq -r --arg id "$id" '.tasks[$id].status // ""' "$graph_file")
    case " $VALID_STATUSES " in
      *" $status "*) ;;
      *) echo "INVALID_TASK_STATUS $id"; problems=$((problems + 1)) ;;
    esac
    verdict=$(jq -r --arg id "$id" '.tasks[$id].verdict // ""' "$graph_file")
    if ! _cg_verdict_valid "$verdict"; then
      echo "INVALID_VERDICT $id"
      problems=$((problems + 1))
    fi
    commit=$(jq -r --arg id "$id" '.tasks[$id].commit // ""' "$graph_file")
    if ! _cg_commit_valid "$commit"; then
      echo "INVALID_COMMIT $id"
      problems=$((problems + 1))
    fi
  done <<< "$ids"

  [ "$problems" -eq 0 ]
}

# write_conductor_checkpoint <nazgul_dir> -> writes/overwrites the single
# canonical conductor checkpoint (snapshot of graph.json + a timestamp) and
# prints its path. 1 if graph.json does not exist.
write_conductor_checkpoint() {
  local nazgul_dir="$1" graph_file checkpoint_file tmp
  graph_file="$nazgul_dir/conductor/graph.json"
  [ -f "$graph_file" ] || return 1
  mkdir -p "$nazgul_dir/checkpoints" || return 1
  checkpoint_file="$nazgul_dir/checkpoints/conductor-checkpoint.json"
  tmp=$(mktemp) || return 1
  if ! jq --arg checkpointed_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '. + {checkpointed_at: $checkpointed_at}' \
    "$graph_file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$checkpoint_file" || return 1
  printf '%s\n' "$checkpoint_file"
}

# reload_conductor_state <nazgul_dir> -> prints {"source", "waves", "next_unit"}
# reconstructed from graph.json, falling back to the conductor checkpoint if
# graph.json is missing/invalid (files-are-memory recovery). next_unit is the
# first not-yet-done unit in the earliest incomplete wave, or null when done.
reload_conductor_state() {
  local nazgul_dir="$1" graph_file checkpoint_file source_file waves_json next_unit
  graph_file="$nazgul_dir/conductor/graph.json"
  checkpoint_file="$nazgul_dir/checkpoints/conductor-checkpoint.json"

  if [ -f "$graph_file" ] && validate_graph_json "$graph_file" > /dev/null 2>&1; then
    source_file="$graph_file"
  elif [ -f "$checkpoint_file" ] && validate_graph_json "$checkpoint_file" > /dev/null 2>&1; then
    source_file="$checkpoint_file"
  else
    echo "reload_conductor_state: no graph.json or checkpoint found under $nazgul_dir" >&2
    return 1
  fi

  waves_json=$(compute_waves "$source_file") || return 1
  next_unit=$(jq -r '(.[0].units[0]) // empty' <<< "$waves_json")

  jq -n --arg source "$source_file" --argjson waves "$waves_json" --arg next "$next_unit" \
    '{ source: $source, waves: $waves, next_unit: (if $next == "" then null else $next end) }'
}

# graph_wave_digest <graph_file> -> compact per-turn orientation digest.
# Graph-only: ids/status/sha/wave + the next actionable unit. Never file
# bodies. Cheaper than reload_conductor_state (no compute_waves call) — meant
# for a quick orientation check at turn start, not the authoritative wave
# recomputation. Prints "{}" if graph_file is missing or unparseable.
graph_wave_digest() {
  local graph_file="$1"
  [ -f "$graph_file" ] || { echo '{}'; return 0; }
  jq -c '{
    current_wave: (.current_wave // null),
    next_unit: ( [ .tasks | to_entries[] | select((.value.status // "") as $s | ($s != "DONE" and $s != "BLOCKED")) ] | sort_by(.value.wave // 9999) | (.[0].key // null) ),
    units: ( .tasks | map_values({status: (.status // "PLANNED"), sha: (.commit_sha // null), wave: (.wave // null)}) )
  }' "$graph_file" 2>/dev/null || echo '{}'
}
