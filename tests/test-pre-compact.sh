#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because script under test may exit non-zero during setup edge cases

# Test: pre-compact.sh creates checkpoints and outputs recovery info
TEST_NAME="test-pre-compact"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

COMPACT_SCRIPT="$REPO_ROOT/scripts/pre-compact.sh"

# Helper: run compact script capturing output and exit code
run_compact() {
  COMPACT_OUTPUT=$(bash "$COMPACT_SCRIPT" 2>&1) && COMPACT_EC=0 || COMPACT_EC=$?
}

# --- Test 1: No config — exit 0, no output ---
setup_temp_dir
run_compact
assert_exit_code "no config: exit 0" "$COMPACT_EC" 0
teardown_temp_dir

# --- Test 2: Checkpoint file created ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 3'
create_task_file "TASK-001" "READY"
run_compact
assert_file_exists "checkpoint created" "$TEST_DIR/nazgul/checkpoints/iteration-003.json"
teardown_temp_dir

# --- Test 3: Checkpoint is valid JSON ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 2'
create_task_file "TASK-001" "READY"
run_compact
cp_file="$TEST_DIR/nazgul/checkpoints/iteration-002.json"
if jq empty "$cp_file" 2>/dev/null; then
  _pass "checkpoint is valid JSON"
else
  _fail "checkpoint is valid JSON"
fi
teardown_temp_dir

# --- Test 4: Active task captured in checkpoint ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_task_file "TASK-005" "IN_PROGRESS"
run_compact
assert_json_field "active task id" "$TEST_DIR/nazgul/checkpoints/iteration-005.json" ".active_task.id" "TASK-005"
teardown_temp_dir

# --- Test 5: Task counts correct in checkpoint ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 4'
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "READY"
create_task_file "TASK-004" "BLOCKED"
run_compact
cp_file="$TEST_DIR/nazgul/checkpoints/iteration-004.json"
assert_json_field "done count" "$cp_file" ".plan_snapshot.done" "2"
assert_json_field "ready count" "$cp_file" ".plan_snapshot.ready" "1"
assert_json_field "blocked count" "$cp_file" ".plan_snapshot.blocked" "1"
teardown_temp_dir

# --- Test 6: Stdout has recovery header ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 1'
create_task_file "TASK-001" "READY"
create_plan
run_compact
assert_contains "stdout has header" "$COMPACT_OUTPUT" "=== NAZGUL RECOVERY STATE ==="
teardown_temp_dir

# --- Test 7: Stdout has iteration info ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "DONE"
create_task_file "TASK-004" "READY"
create_task_file "TASK-005" "READY"
create_task_file "TASK-006" "IN_PROGRESS"
run_compact
assert_contains "stdout has iteration" "$COMPACT_OUTPUT" "Iteration: 5"
assert_contains "stdout has done count" "$COMPACT_OUTPUT" "3/6 done"
teardown_temp_dir

# --- Test 8: Stdout shows active task ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 2'
create_task_file "TASK-002" "IN_PROGRESS"
run_compact
assert_contains "stdout shows active task" "$COMPACT_OUTPUT" "Active task: TASK-002"
teardown_temp_dir

report_results
