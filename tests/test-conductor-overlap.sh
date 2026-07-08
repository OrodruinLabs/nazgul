#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: conductor-router.sh — backend router + overlap-abort + max_parallel cap
TEST_NAME="test-conductor-overlap"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/conductor-router.sh"

OUT_FILE=$(mktemp)
trap 'rm -f "$OUT_FILE"' EXIT

run_route_unit() {
  route_unit "$1" > "$OUT_FILE"
}

run_route_wave() {
  route_wave "$1" "$2" "${3:-}" > "$OUT_FILE" 2>/dev/null && ROUTE_EC=0 || ROUTE_EC=$?
}

# --- Test 1: backend selection per isolation ---
run_route_unit '{"kind":"review","isolation":"mutation"}'
assert_json_field "backend: review always subagent" "$OUT_FILE" ".backend" "subagent"
run_route_unit '{"kind":"task","isolation":"mutation"}'
assert_json_field "backend: mutation -> worktree" "$OUT_FILE" ".backend" "worktree"
run_route_unit '{"kind":"task","isolation":"coordination"}'
assert_json_field "backend: coordination -> team" "$OUT_FILE" ".backend" "team"
run_route_unit '{"kind":"task","isolation":"bounded"}'
assert_json_field "backend: bounded -> subagent" "$OUT_FILE" ".backend" "subagent"
run_route_unit '{"kind":"task"}'
assert_json_field "backend: unclear isolation falls back to subagent" "$OUT_FILE" ".backend" "subagent"
assert_json_field "backend: fallback dispatch mechanism is Task tool" "$OUT_FILE" ".dispatch" "Task tool"
assert_eq "route_backend: direct call, review" "$(route_backend review mutation)" "subagent"
assert_eq "route_backend: direct call, mutation" "$(route_backend task mutation)" "worktree"
assert_eq "route_backend: direct call, coordination" "$(route_backend task coordination)" "team"
assert_eq "route_backend: direct call, unknown isolation" "$(route_backend task something-else)" "subagent"

# --- Test 2: file overlap in a marked-parallel wave aborts to sequential ---
UNITS_OVERLAP='[{"id":"TASK-001","file_scope":["a.sh","b.sh"]},{"id":"TASK-002","file_scope":["b.sh","c.sh"]}]'
run_route_wave "$UNITS_OVERLAP" "true" ""
assert_exit_code "overlap: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "overlap: dispatch sequential" "$OUT_FILE" ".dispatch" "sequential"
assert_json_field "overlap: reason mentions overlap" "$OUT_FILE" ".reason" "file overlap detected in wave"
assert_json_field "overlap: batches count matches unit count" "$OUT_FILE" ".batches | length" "2"
assert_json_field "overlap: each batch is a single unit" "$OUT_FILE" ".batches[0] | length" "1"

# --- Test 3: zero-overlap marked-parallel set stays parallel ---
UNITS_CLEAN='[{"id":"TASK-001","file_scope":["a.sh"]},{"id":"TASK-002","file_scope":["b.sh"]}]'
run_route_wave "$UNITS_CLEAN" "true" ""
assert_exit_code "clean: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "clean: dispatch parallel" "$OUT_FILE" ".dispatch" "parallel"
assert_json_field "clean: single batch (under cap)" "$OUT_FILE" ".batches | length" "1"
assert_json_field "clean: batch has both units" "$OUT_FILE" ".batches[0] | length" "2"

# --- Test 4: unmarked wave runs sequential even at zero overlap ---
run_route_wave "$UNITS_CLEAN" "false" ""
assert_exit_code "unmarked: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "unmarked: dispatch sequential" "$OUT_FILE" ".dispatch" "sequential"
assert_json_field "unmarked: reason mentions not-marked" "$OUT_FILE" ".reason" "not Planner-marked parallel group"
assert_json_field "unmarked: batches count matches unit count" "$OUT_FILE" ".batches | length" "2"

# --- Test 5: max_parallel caps an oversized marked-parallel wave, chunked ---
UNITS_BIG='[{"id":"T1","file_scope":["1.sh"]},{"id":"T2","file_scope":["2.sh"]},{"id":"T3","file_scope":["3.sh"]},{"id":"T4","file_scope":["4.sh"]}]'
run_route_wave "$UNITS_BIG" "true" ""
assert_exit_code "cap: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "cap: dispatch parallel" "$OUT_FILE" ".dispatch" "parallel"
assert_json_field "cap: chunked into 2 batches (default cap 3)" "$OUT_FILE" ".batches | length" "2"
assert_json_field "cap: batch1 size 3" "$OUT_FILE" ".batches[0] | length" "3"
assert_json_field "cap: batch2 size 1" "$OUT_FILE" ".batches[1] | length" "1"
assert_json_field "cap: no batch exceeds cap" "$OUT_FILE" "[.batches[] | length] | max" "3"

# --- Test 5b: max_parallel honors an explicit config override ---
setup_temp_dir
setup_nazgul_dir
create_config '.conductor.max_parallel = 2'
CONFIG="$TEST_DIR/nazgul/config.json"
run_route_wave "$UNITS_BIG" "true" "$CONFIG"
assert_json_field "cap override: chunked into 2-max batches" "$OUT_FILE" ".batches[0] | length" "2"
assert_json_field "cap override: 2 batches of size 2" "$OUT_FILE" ".batches | length" "2"
teardown_temp_dir

# --- Test 6: file_scope shape guard — diff-shaped/multi-line entries rejected ---
if router_validate_file_scope '["a.sh", "diff --git a/x b/x"]' > /dev/null; then
  _fail "shape guard: diff-shaped entry rejected"
else
  _pass "shape guard: diff-shaped entry rejected"
fi
if router_validate_file_scope "$(jq -c -n '["a.sh", "multi\nline"]')" > /dev/null; then
  _fail "shape guard: multi-line entry rejected"
else
  _pass "shape guard: multi-line entry rejected"
fi
if router_validate_file_scope '["a.sh", "b.sh"]' > /dev/null; then
  _pass "shape guard: valid bare paths accepted"
else
  _fail "shape guard: valid bare paths accepted"
fi
assert_contains "shape guard: prints invalid index" \
  "$(router_validate_file_scope '["a.sh", "diff --git a/x b/x"]')" "INVALID_FILE_SCOPE_ENTRY 1"

# --- Test 7: an invalid file_scope entry inside a wave forces sequential fallback ---
UNITS_BAD='[{"id":"T1","file_scope":["a.sh","diff --git a/x b/x"]},{"id":"T2","file_scope":["b.sh"]}]'
run_route_wave "$UNITS_BAD" "true" ""
assert_exit_code "bad scope: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "bad scope: dispatch sequential" "$OUT_FILE" ".dispatch" "sequential"
assert_json_field "bad scope: reason mentions invalid shape" "$OUT_FILE" ".reason" "invalid file_scope shape"

# --- Test 8: exact-cap boundary — N == max_parallel stays a single batch ---
UNITS_EXACT='[{"id":"T1","file_scope":["1.sh"]},{"id":"T2","file_scope":["2.sh"]},{"id":"T3","file_scope":["3.sh"]}]'
run_route_wave "$UNITS_EXACT" "true" ""
assert_exit_code "exact cap: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "exact cap: dispatch parallel" "$OUT_FILE" ".dispatch" "parallel"
assert_json_field "exact cap: single batch (no off-by-one split)" "$OUT_FILE" ".batches | length" "1"
assert_json_field "exact cap: batch holds all 3 units" "$OUT_FILE" ".batches[0] | length" "3"

# --- Test 9: empty wave -> batches: [] (not [[]]) ---
run_route_wave "[]" "true" ""
assert_exit_code "empty wave: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "empty wave: batches is an empty array" "$OUT_FILE" ".batches | length" "0"

# --- Test 10: single-unit marked-parallel wave -> parallel, one batch of one ---
UNITS_SINGLE='[{"id":"T1","file_scope":["1.sh"]}]'
run_route_wave "$UNITS_SINGLE" "true" ""
assert_exit_code "single unit: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "single unit: dispatch parallel" "$OUT_FILE" ".dispatch" "parallel"
assert_json_field "single unit: one batch" "$OUT_FILE" ".batches | length" "1"
assert_json_field "single unit: batch has one unit" "$OUT_FILE" ".batches[0] | length" "1"

# --- Test 11: malformed units_json (not an array) forces sequential fail-safe ---
run_route_wave '{' "true" ""
assert_exit_code "malformed json: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "malformed json: dispatch sequential" "$OUT_FILE" ".dispatch" "sequential"
assert_json_field "malformed json: reason mentions malformed" "$OUT_FILE" ".reason" "malformed units_json"

run_route_wave "not json" "true" ""
assert_exit_code "not json: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "not json: dispatch sequential" "$OUT_FILE" ".dispatch" "sequential"
assert_json_field "not json: reason mentions malformed" "$OUT_FILE" ".reason" "malformed units_json"

# --- Test 12: non-string file_scope entries (number/object) rejected, not stringified ---
if router_validate_file_scope '[3, {"x":1}]' > /dev/null; then
  _fail "shape guard: non-string entries rejected"
else
  _pass "shape guard: non-string entries rejected"
fi
assert_contains "shape guard: rejects numeric entry by index" \
  "$(router_validate_file_scope '[3, "a.sh"]')" "INVALID_FILE_SCOPE_ENTRY 0"
assert_contains "shape guard: rejects object entry by index" \
  "$(router_validate_file_scope '["a.sh", {"x":1}]')" "INVALID_FILE_SCOPE_ENTRY 1"

UNITS_NONSTRING='[{"id":"T1","file_scope":[3,{"x":1}]},{"id":"T2","file_scope":["b.sh"]}]'
run_route_wave "$UNITS_NONSTRING" "true" ""
assert_exit_code "non-string scope: route_wave exit 0" "$ROUTE_EC" 0
assert_json_field "non-string scope: dispatch sequential" "$OUT_FILE" ".dispatch" "sequential"
assert_json_field "non-string scope: reason mentions invalid shape" "$OUT_FILE" ".reason" "invalid file_scope shape"

# --- Test 13: Layer 4 — parallel mutation routes to team, single mutation to worktree ---
assert_eq "route_backend: parallel mutation -> team" "$(route_backend implement mutation parallel)" "team"
assert_eq "route_backend: single mutation -> worktree" "$(route_backend implement mutation single)" "worktree"
assert_eq "route_backend: review always subagent (parallel group ignored)" "$(route_backend review "" parallel)" "subagent"
assert_eq "route_backend: mutation with no group arg defaults to single -> worktree" "$(route_backend implement mutation)" "worktree"

run_route_unit_grouped() {
  route_unit "$1" "$2" > "$OUT_FILE"
}
run_route_unit_grouped '{"kind":"task","isolation":"mutation"}' "parallel"
assert_json_field "route_unit: mutation + parallel group -> team" "$OUT_FILE" ".backend" "team"
assert_json_field "route_unit: mutation + parallel group -> dispatch team-orchestrator" "$OUT_FILE" ".dispatch" "team-orchestrator"
run_route_unit_grouped '{"kind":"task","isolation":"mutation"}' "single"
assert_json_field "route_unit: mutation + single group -> worktree" "$OUT_FILE" ".backend" "worktree"
run_route_unit '{"kind":"task","isolation":"mutation"}'
assert_json_field "route_unit: mutation, no group arg (back-compat) -> worktree" "$OUT_FILE" ".backend" "worktree"

# --- Test 14: choke-point integration — a real parallel multi-unit mutating batch
# ends up routed to team, a single-unit mutating wave routes to worktree. This
# exercises route_wave()'s batches feeding route_unit(), the actual call shape
# agents/conductor.md's Step 4/5 use — not route_backend() in isolation.
route_batch_backends() {
  # $1 = ROUTE json ({dispatch, reason, batches}); prints one backend per unit,
  # in batch/unit order, exactly as agents/conductor.md's Step 4 would derive
  # group from batch size before calling route_unit.
  local route_json="$1" nbatches bi ulen ui group unit_id
  nbatches=$(jq '.batches | length' <<< "$route_json")
  bi=0
  while [ "$bi" -lt "$nbatches" ]; do
    ulen=$(jq --argjson bi "$bi" '.batches[$bi] | length' <<< "$route_json")
    if [ "$ulen" -gt 1 ]; then group="parallel"; else group="single"; fi
    ui=0
    while [ "$ui" -lt "$ulen" ]; do
      unit_id=$(jq -r --argjson bi "$bi" --argjson ui "$ui" '.batches[$bi][$ui]' <<< "$route_json")
      route_unit "$(jq -n --arg id "$unit_id" '{"kind":"task","isolation":"mutation","id":$id}')" "$group" \
        | jq -r '.backend'
      ui=$((ui + 1))
    done
    bi=$((bi + 1))
  done
}

UNITS_PARALLEL_MUTATION='[{"id":"TASK-001","file_scope":["a.sh"]},{"id":"TASK-002","file_scope":["b.sh"]}]'
run_route_wave "$UNITS_PARALLEL_MUTATION" "true" ""
ROUTE_JSON=$(cat "$OUT_FILE")
BACKENDS=$(route_batch_backends "$ROUTE_JSON")
assert_eq "choke point: parallel multi-unit mutating batch -> both units route to team" \
  "$(echo "$BACKENDS" | sort -u | tr '\n' ' ' | sed 's/ $//')" "team"

UNITS_SINGLE_MUTATION='[{"id":"TASK-001","file_scope":["a.sh"]}]'
run_route_wave "$UNITS_SINGLE_MUTATION" "false" ""
assert_json_field "choke point: single-unit wave dispatch is sequential" "$OUT_FILE" ".dispatch" "sequential"
ROUTE_JSON=$(cat "$OUT_FILE")
BACKENDS=$(route_batch_backends "$ROUTE_JSON")
assert_eq "choke point: single-unit mutating wave -> unit routes to worktree" "$BACKENDS" "worktree"

report_results
