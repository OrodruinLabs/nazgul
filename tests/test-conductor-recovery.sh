#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: conductor-graph.sh — graph.json schema, graph-only invariant, checkpoint/recovery
TEST_NAME="test-conductor-recovery"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/conductor-graph.sh"

run_validate() {
  VAL_OUTPUT=$(validate_graph_json "$1") && VAL_EC=0 || VAL_EC=$?
}

# --- Test 1: init_graph_json schema skeleton ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007" "conductor" 3
assert_file_exists "graph.json created" "$GRAPH"
assert_json_field "schema field" "$GRAPH" ".schema" "1"
assert_json_field "objective field" "$GRAPH" ".objective" "FEAT-007"
assert_json_field "engine field" "$GRAPH" ".engine" "conductor"
assert_json_field "max_parallel field" "$GRAPH" ".max_parallel" "3"
assert_json_field "gates default approve_graph false" "$GRAPH" ".gates.approve_graph" "false"
assert_json_field "gates default approve_each_wave false" "$GRAPH" ".gates.approve_each_wave" "false"
assert_json_field "gates default approve_final_pr false" "$GRAPH" ".gates.approve_final_pr" "false"
assert_json_field "budgets.tokens_est null" "$GRAPH" ".budgets.tokens_est" "null"
run_validate "$GRAPH"
assert_exit_code "fresh graph.json validates" "$VAL_EC" 0
teardown_temp_dir

# --- Test 2: init_graph_json is idempotent (no-op if file exists) ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "APPROVE" "abc1234"
init_graph_json "$GRAPH" "FEAT-999"
assert_json_field "idempotent init: objective unchanged" "$GRAPH" ".objective" "FEAT-007"
assert_json_field "idempotent init: task preserved" "$GRAPH" ".tasks[\"TASK-001\"].status" "DONE"
teardown_temp_dir

# --- Test 3: graph_upsert_task + validate round-trip with a full task entry ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" '["TASK-000"]' 2 "IN_REVIEW" '["scripts/a.sh","scripts/b.sh"]' "CHANGES_REQUESTED — 1 blocking" ""
assert_json_field "task deps round-trip" "$GRAPH" '.tasks["TASK-001"].deps[0]' "TASK-000"
assert_json_field "task wave round-trip" "$GRAPH" '.tasks["TASK-001"].wave' "2"
assert_json_field "task status round-trip" "$GRAPH" '.tasks["TASK-001"].status' "IN_REVIEW"
assert_json_field "task file_scope round-trip" "$GRAPH" '.tasks["TASK-001"].file_scope[1]' "scripts/b.sh"
assert_json_field "task verdict round-trip" "$GRAPH" '.tasks["TASK-001"].verdict' "CHANGES_REQUESTED — 1 blocking"
run_validate "$GRAPH"
assert_exit_code "populated graph.json validates" "$VAL_EC" 0
teardown_temp_dir

# --- Test 4: graph-only invariant — multi-line verdict is rejected (no write) ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
MULTILINE=$'APPROVE\nsecond line'
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "$MULTILINE" "" 2>/dev/null
UPSERT_EC=$?
assert_exit_code "multi-line verdict rejected: exit 1" "$UPSERT_EC" 1
assert_json_field "multi-line verdict rejected: task not written" "$GRAPH" '.tasks | has("TASK-001")' "false"
teardown_temp_dir

# --- Test 5: graph-only invariant — diff-shaped verdict is rejected (no write) ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "diff --git a/x b/x" "" 2>/dev/null
UPSERT_EC=$?
assert_exit_code "diff-shaped verdict rejected: exit 1" "$UPSERT_EC" 1
assert_json_field "diff-shaped verdict rejected: task not written" "$GRAPH" '.tasks | has("TASK-001")' "false"
teardown_temp_dir

# --- Test 6: graph-only invariant — non-SHA commit is rejected (no write) ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "APPROVE" "not-a-sha!!" 2>/dev/null
UPSERT_EC=$?
assert_exit_code "non-SHA commit rejected: exit 1" "$UPSERT_EC" 1
assert_json_field "non-SHA commit rejected: task not written" "$GRAPH" '.tasks | has("TASK-001")' "false"
teardown_temp_dir

# --- Test 7: validate_graph_json itself flags a hand-crafted graph-only violation ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "APPROVE" "abc1234"
# Bypass the setter guard directly with jq to simulate a corrupted file.
jq '.tasks["TASK-001"].verdict = "line one\nline two"' "$GRAPH" > "$GRAPH.tmp" && mv "$GRAPH.tmp" "$GRAPH"
run_validate "$GRAPH"
assert_exit_code "hand-crafted multi-line verdict: exit 1" "$VAL_EC" 1
assert_contains "INVALID_VERDICT marker" "$VAL_OUTPUT" "INVALID_VERDICT TASK-001"
teardown_temp_dir

# --- Test 8: validate_graph_json flags a missing required field ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
jq 'del(.gates)' "$GRAPH" > "$GRAPH.tmp" && mv "$GRAPH.tmp" "$GRAPH"
run_validate "$GRAPH"
assert_exit_code "missing field: exit 1" "$VAL_EC" 1
assert_contains "MISSING_FIELD marker" "$VAL_OUTPUT" "MISSING_FIELD gates"
teardown_temp_dir

# --- Test 9: graph_update_task_status + graph_set_verdict ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "IN_PROGRESS" '["a.sh"]'
graph_update_task_status "$GRAPH" "TASK-001" "DONE"
assert_json_field "status updated" "$GRAPH" '.tasks["TASK-001"].status' "DONE"
graph_set_verdict "$GRAPH" "TASK-001" "APPROVE — all reviewers passed" "abc1234"
assert_json_field "verdict set" "$GRAPH" '.tasks["TASK-001"].verdict' "APPROVE — all reviewers passed"
assert_json_field "commit set" "$GRAPH" '.tasks["TASK-001"].commit' "abc1234"
graph_update_task_status "$GRAPH" "TASK-999" "DONE" 2>/dev/null
assert_exit_code "unknown task status update rejected" "$?" 1
teardown_temp_dir

# --- Test 10: write_conductor_checkpoint round-trips graph.json content ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "APPROVE" "abc1234"
graph_upsert_task "$GRAPH" "TASK-002" '["TASK-001"]' 2 "READY" '["b.sh"]'
CHECKPOINT=$(write_conductor_checkpoint "$TEST_DIR/nazgul")
assert_file_exists "checkpoint file written" "$CHECKPOINT"
assert_json_field "checkpoint mirrors task status" "$CHECKPOINT" '.tasks["TASK-002"].status' "READY"
assert_json_field "checkpoint carries checkpointed_at" "$CHECKPOINT" 'has("checkpointed_at")' "true"
teardown_temp_dir

# --- Test 11: reload_conductor_state — mid-build picks correct next unit ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "APPROVE" "abc1234"
graph_upsert_task "$GRAPH" "TASK-002" '["TASK-001"]' 2 "READY" '["b.sh"]'
graph_upsert_task "$GRAPH" "TASK-003" '["TASK-002"]' 2 "PLANNED" '["c.sh"]'
RELOAD_OUT=$(reload_conductor_state "$TEST_DIR/nazgul")
RELOAD_EC=$?
assert_exit_code "reload: exit 0" "$RELOAD_EC" 0
printf '%s' "$RELOAD_OUT" > "$TEST_DIR/reload.json"
assert_json_field "reload: source is graph.json" "$TEST_DIR/reload.json" ".source" "$GRAPH"
assert_json_field "reload: next unit skips DONE task" "$TEST_DIR/reload.json" ".next_unit" "TASK-002"
assert_json_field "reload: TASK-001 absent from waves (already done)" "$TEST_DIR/reload.json" \
  '[.waves[].units[]] | index("TASK-001")' "null"
teardown_temp_dir

# --- Test 12: checkpoint round-trip survives graph.json loss ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "APPROVE" "abc1234"
graph_upsert_task "$GRAPH" "TASK-002" '["TASK-001"]' 2 "READY" '["b.sh"]'
BEFORE=$(reload_conductor_state "$TEST_DIR/nazgul")
write_conductor_checkpoint "$TEST_DIR/nazgul" > /dev/null
rm -f "$GRAPH"
AFTER=$(reload_conductor_state "$TEST_DIR/nazgul")
AFTER_EC=$?
assert_exit_code "reload after graph.json loss: exit 0" "$AFTER_EC" 0
BEFORE_WAVES=$(jq -c '.waves' <<< "$BEFORE")
AFTER_WAVES=$(jq -c '.waves' <<< "$AFTER")
assert_eq "reload: waves identical after checkpoint-only recovery" "$AFTER_WAVES" "$BEFORE_WAVES"
BEFORE_NEXT=$(jq -r '.next_unit' <<< "$BEFORE")
AFTER_NEXT=$(jq -r '.next_unit' <<< "$AFTER")
assert_eq "reload: next_unit identical after checkpoint-only recovery" "$AFTER_NEXT" "$BEFORE_NEXT"
printf '%s' "$AFTER" > "$TEST_DIR/after.json"
assert_json_field "reload: source falls back to checkpoint" "$TEST_DIR/after.json" ".source" \
  "$TEST_DIR/nazgul/checkpoints/conductor-checkpoint.json"
teardown_temp_dir

# --- Test 13: reload_conductor_state — all-DONE graph -> next_unit null ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "APPROVE" "abc1234"
RELOAD_OUT=$(reload_conductor_state "$TEST_DIR/nazgul")
printf '%s' "$RELOAD_OUT" > "$TEST_DIR/reload.json"
assert_json_field "reload: all-DONE next_unit is null" "$TEST_DIR/reload.json" ".next_unit" "null"
assert_json_field "reload: all-DONE waves empty" "$TEST_DIR/reload.json" ".waves | length" "0"
teardown_temp_dir

# --- Test 14: reload_conductor_state — no graph.json and no checkpoint -> exit 1 ---
setup_temp_dir
setup_nazgul_dir
reload_conductor_state "$TEST_DIR/nazgul" >/dev/null 2>/dev/null
assert_exit_code "reload with nothing on disk: exit 1" "$?" 1
teardown_temp_dir

# --- Test 15: reload_conductor_state — parseable but schema-invalid graph.json
# falls back to a valid checkpoint (validate, not just parse) ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "DONE" '["a.sh"]' "APPROVE" "abc1234"
write_conductor_checkpoint "$TEST_DIR/nazgul" > /dev/null
jq '.tasks["TASK-001"].status = "NOT_A_REAL_STATUS"' "$GRAPH" > "$GRAPH.tmp" && mv "$GRAPH.tmp" "$GRAPH"
RELOAD_OUT=$(reload_conductor_state "$TEST_DIR/nazgul")
RELOAD_EC=$?
assert_exit_code "reload: schema-invalid graph.json falls back, exit 0" "$RELOAD_EC" 0
printf '%s' "$RELOAD_OUT" > "$TEST_DIR/reload.json"
assert_json_field "reload: source falls back to checkpoint on schema-invalid graph.json" \
  "$TEST_DIR/reload.json" ".source" "$TEST_DIR/nazgul/checkpoints/conductor-checkpoint.json"
teardown_temp_dir

# --- Test 16: init_graph_json clamps a non-numeric max_parallel to 3 ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007" "conductor" "not-a-number"
assert_file_exists "clamp: graph.json still created" "$GRAPH"
assert_json_field "clamp: non-numeric max_parallel defaults to 3" "$GRAPH" ".max_parallel" "3"
teardown_temp_dir

# --- Test 17: graph_wave_digest — compact graph-only orientation snapshot ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
mkdir -p "$(dirname "$GRAPH")"
jq -n '{current_wave:2,tasks:{"TASK-001":{status:"DONE",commit_sha:"aaa111",wave:1},"TASK-003":{status:"READY",wave:2}}}' > "$GRAPH"
DIGEST=$(graph_wave_digest "$GRAPH")
printf '%s' "$DIGEST" > "$TEST_DIR/digest.json"
assert_json_field "digest current_wave" "$TEST_DIR/digest.json" ".current_wave" "2"
assert_json_field "digest carries sha" "$TEST_DIR/digest.json" '.units["TASK-001"].sha' "aaa111"
assert_json_field "digest carries wave" "$TEST_DIR/digest.json" '.units["TASK-001"].wave' "1"
assert_json_field "digest next_unit skips DONE" "$TEST_DIR/digest.json" ".next_unit" "TASK-003"
assert_json_field "digest holds no file bodies (graph-only)" "$TEST_DIR/digest.json" \
  '.units["TASK-001"] | has("body")' "false"
teardown_temp_dir

# --- Test 18: graph_mark_dispatched sets .tasks[id].dispatched = true ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-007"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "READY" '["a.sh"]'
assert_json_field "dispatched unset before marking" "$GRAPH" '.tasks["TASK-001"] | has("dispatched")' "false"
graph_mark_dispatched "$GRAPH" "TASK-001"
assert_json_field "dispatched set true after marking" "$GRAPH" '.tasks["TASK-001"].dispatched' "true"
assert_json_field "status untouched by mark_dispatched" "$GRAPH" '.tasks["TASK-001"].status' "READY"
graph_mark_dispatched "$GRAPH" "TASK-999" 2>/dev/null
assert_exit_code "unknown task mark_dispatched rejected" "$?" 1
teardown_temp_dir

report_results
