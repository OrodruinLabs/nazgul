#!/usr/bin/env bash
set -euo pipefail

# Test: session-context.sh reads state and outputs context
TEST_NAME="test-session-context"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

SESSION_SCRIPT="$REPO_ROOT/scripts/session-context.sh"

# --- Test 1: No config — exit 0, no output ---
setup_temp_dir
output=$(bash "$SESSION_SCRIPT" 2>&1) || true
ec=$?
assert_exit_code "no config: exit 0" "$ec" 0
teardown_temp_dir

# --- Test 2: Basic output with iteration and mode ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.current_iteration = 7' '.max_iterations = 40' '.mode = "hitl"'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "shows iteration" "$output" "7/40"
assert_contains "shows mode" "$output" "hitl"
teardown_temp_dir

# --- Test 3: Task counts ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "READY"
create_task_file "TASK-004" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "done count" "$output" "2 done"
assert_contains "ready count" "$output" "1 ready"
assert_contains "in progress count" "$output" "1 in progress"
teardown_temp_dir

# --- Test 4: Active task shown ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_task_file "TASK-003" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "active task shown" "$output" "Active task: TASK-003"
teardown_temp_dir

# --- Test 5: Objective shown ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.objective = "Build X"'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "objective shown" "$output" "Objective: Build X"
teardown_temp_dir

# --- Test 6: Recovery pointer output ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "recovery pointer" "$output" "Recovery Pointer"
teardown_temp_dir

# --- Test 7: Reviewers listed ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.agents.reviewers = ["architect-reviewer", "code-reviewer"]'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "reviewer names" "$output" "architect-reviewer"
teardown_temp_dir

# --- Test 8: CHANGES_REQUESTED warning ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_task_file "TASK-001" "CHANGES_REQUESTED"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "changes requested warning" "$output" "WARNING"
teardown_temp_dir

# --- Test 9: Compact event increments counter (no prior file) ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
export CLAUDE_HOOK_EVENT="compact"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
assert_file_exists "compaction_count created" "$TEST_DIR/hydra/.compaction_count"
val=$(jq -r '.count' "$TEST_DIR/hydra/.compaction_count")
assert_eq "compact count is 1" "$val" "1"
unset CLAUDE_HOOK_EVENT
teardown_temp_dir

# --- Test 10: Compact preserves and increments count ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
printf '{"count": 3, "last_compaction_iteration": 5}\n' > "$TEST_DIR/hydra/.compaction_count"
export CLAUDE_HOOK_EVENT="compact"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
val=$(jq -r '.count' "$TEST_DIR/hydra/.compaction_count")
assert_eq "compact count incremented to 4" "$val" "4"
unset CLAUDE_HOOK_EVENT
teardown_temp_dir

report_results
