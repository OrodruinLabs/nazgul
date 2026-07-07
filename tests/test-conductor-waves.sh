#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: conductor-graph.sh — compute_waves (topological layering)
TEST_NAME="test-conductor-waves"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/conductor-graph.sh"

run_compute() {
  local errfile
  errfile=$(mktemp)
  COMPUTE_OUT=$(compute_waves "$1" 2>"$errfile") && COMPUTE_EC=0 || COMPUTE_EC=$?
  COMPUTE_ERR=$(cat "$errfile" 2>/dev/null)
  rm -f "$errfile"
}

# --- Test 1: linear chain -> 3 single-unit waves, in dependency order ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 READY none
create_task_file TASK-002 READY TASK-001
create_task_file TASK-003 READY TASK-002
run_compute "$TEST_DIR/nazgul/tasks"
assert_exit_code "linear chain: exit 0" "$COMPUTE_EC" 0
printf '%s' "$COMPUTE_OUT" > "$TEST_DIR/waves.json"
assert_json_field "linear chain: 3 waves" "$TEST_DIR/waves.json" ". | length" "3"
assert_json_field "linear chain: wave1 unit" "$TEST_DIR/waves.json" ".[0].units[0]" "TASK-001"
assert_json_field "linear chain: wave1 size 1" "$TEST_DIR/waves.json" ".[0].units | length" "1"
assert_json_field "linear chain: wave2 unit" "$TEST_DIR/waves.json" ".[1].units[0]" "TASK-002"
assert_json_field "linear chain: wave3 unit" "$TEST_DIR/waves.json" ".[2].units[0]" "TASK-003"
assert_not_contains "linear chain: unmet-dep task not in wave1" "$(jq -c '.[0]' "$TEST_DIR/waves.json")" "TASK-002"
teardown_temp_dir

# --- Test 2: fan-out -> one multi-unit wave after the root resolves ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 READY none
create_task_file TASK-002 READY TASK-001
create_task_file TASK-003 READY TASK-001
run_compute "$TEST_DIR/nazgul/tasks"
assert_exit_code "fan-out: exit 0" "$COMPUTE_EC" 0
printf '%s' "$COMPUTE_OUT" > "$TEST_DIR/waves.json"
assert_json_field "fan-out: 2 waves" "$TEST_DIR/waves.json" ". | length" "2"
assert_json_field "fan-out: wave1 unit" "$TEST_DIR/waves.json" ".[0].units[0]" "TASK-001"
assert_json_field "fan-out: wave2 size 2" "$TEST_DIR/waves.json" ".[1].units | length" "2"
assert_json_field "fan-out: wave2 unit0" "$TEST_DIR/waves.json" ".[1].units[0]" "TASK-002"
assert_json_field "fan-out: wave2 unit1" "$TEST_DIR/waves.json" ".[1].units[1]" "TASK-003"
teardown_temp_dir

# --- Test 3: empty graph -> no waves ---
setup_temp_dir
setup_nazgul_dir
run_compute "$TEST_DIR/nazgul/tasks"
assert_exit_code "empty graph: exit 0" "$COMPUTE_EC" 0
assert_eq "empty graph: no waves" "$COMPUTE_OUT" "[]"
teardown_temp_dir

# --- Test 4: single task -> one wave, one unit ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 READY none
run_compute "$TEST_DIR/nazgul/tasks"
assert_exit_code "single task: exit 0" "$COMPUTE_EC" 0
printf '%s' "$COMPUTE_OUT" > "$TEST_DIR/waves.json"
assert_json_field "single task: 1 wave" "$TEST_DIR/waves.json" ". | length" "1"
assert_json_field "single task: wave1 unit" "$TEST_DIR/waves.json" ".[0].units[0]" "TASK-001"
teardown_temp_dir

# --- Test 5: fully-DONE graph -> no waves ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 DONE none
create_task_file TASK-002 DONE TASK-001
run_compute "$TEST_DIR/nazgul/tasks"
assert_exit_code "fully-DONE: exit 0" "$COMPUTE_EC" 0
assert_eq "fully-DONE: no waves" "$COMPUTE_OUT" "[]"
teardown_temp_dir

# --- Test 6: cycle -> rejected, not looped ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 READY TASK-002
create_task_file TASK-002 READY TASK-001
run_compute "$TEST_DIR/nazgul/tasks"
assert_exit_code "cycle: non-zero exit" "$COMPUTE_EC" 1
assert_contains "cycle: stderr mentions cycle" "$COMPUTE_ERR" "cycle"
teardown_temp_dir

# --- Test 7: deterministic order — identical input yields identical output ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 READY none
create_task_file TASK-002 READY TASK-001
create_task_file TASK-003 READY TASK-001
run_compute "$TEST_DIR/nazgul/tasks"
FIRST_OUT="$COMPUTE_OUT"
run_compute "$TEST_DIR/nazgul/tasks"
assert_eq "deterministic: repeated compute matches" "$COMPUTE_OUT" "$FIRST_OUT"
teardown_temp_dir

# --- Test 8: compute_waves also accepts a graph.json file directly ---
setup_temp_dir
setup_nazgul_dir
GRAPH="$TEST_DIR/nazgul/conductor/graph.json"
init_graph_json "$GRAPH" "FEAT-TEST"
graph_upsert_task "$GRAPH" "TASK-001" "[]" 1 "READY" '["a.sh"]'
graph_upsert_task "$GRAPH" "TASK-002" '["TASK-001"]' 2 "READY" '["b.sh"]'
run_compute "$GRAPH"
assert_exit_code "graph.json input: exit 0" "$COMPUTE_EC" 0
printf '%s' "$COMPUTE_OUT" > "$TEST_DIR/waves.json"
assert_json_field "graph.json input: 2 waves" "$TEST_DIR/waves.json" ". | length" "2"
assert_json_field "graph.json input: wave1 unit" "$TEST_DIR/waves.json" ".[0].units[0]" "TASK-001"
assert_json_field "graph.json input: wave2 unit" "$TEST_DIR/waves.json" ".[1].units[0]" "TASK-002"
teardown_temp_dir

# --- Test 9: unknown dependency id -> rejected, not silently dropped or looped ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 READY TASK-999
run_compute "$TEST_DIR/nazgul/tasks"
assert_exit_code "unknown dep: non-zero exit" "$COMPUTE_EC" 1
assert_contains "unknown dep: stderr names unknown dependency" "$COMPUTE_ERR" "unknown dependency"
teardown_temp_dir

report_results
