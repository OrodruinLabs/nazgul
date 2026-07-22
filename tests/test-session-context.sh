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
ec=0
output=$(bash "$SESSION_SCRIPT" 2>&1) || ec=$?
assert_exit_code "no config: exit 0" "$ec" 0
teardown_temp_dir

# --- Test 2: Basic output with iteration and mode ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 7' '.max_iterations = 40' '.mode = "hitl"'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "shows iteration" "$output" "7/40"
assert_contains "shows mode" "$output" "hitl"
teardown_temp_dir

# --- Test 3: Task counts ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
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
setup_nazgul_dir
create_config
create_task_file "TASK-003" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "active task shown" "$output" "Active task: TASK-003"
teardown_temp_dir

# --- Test 5: Objective shown ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.objective = "Build X"'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "objective shown" "$output" "Objective: Build X"
teardown_temp_dir

# --- Test 6: Recovery pointer output ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "recovery pointer" "$output" "Recovery Pointer"
teardown_temp_dir

# --- Test 7: Reviewers listed ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["architect-reviewer", "code-reviewer"]'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "reviewer names" "$output" "architect-reviewer"
teardown_temp_dir

# --- Test 8: CHANGES_REQUESTED warning ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "CHANGES_REQUESTED"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "changes requested warning" "$output" "WARNING"
teardown_temp_dir

# --- Test 9: Compact event increments counter (no prior file) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
export CLAUDE_HOOK_EVENT="compact"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
assert_file_exists "compaction_count created" "$TEST_DIR/nazgul/.compaction_count"
val=$(jq -r '.count' "$TEST_DIR/nazgul/.compaction_count")
assert_eq "compact count is 1" "$val" "1"
unset CLAUDE_HOOK_EVENT
teardown_temp_dir

# --- Test 10: Compact preserves and increments count ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
printf '{"count": 3, "last_compaction_iteration": 5}\n' > "$TEST_DIR/nazgul/.compaction_count"
export CLAUDE_HOOK_EVENT="compact"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
val=$(jq -r '.count' "$TEST_DIR/nazgul/.compaction_count")
assert_eq "compact count incremented to 4" "$val" "4"
unset CLAUDE_HOOK_EVENT
teardown_temp_dir

# --- Test 11: Telemetry-dark — stale plan.md Status Summary fires (MF-060) ---
# plan.md claims all 3 tasks are still PLANNED (0 done, 0 in progress) while the
# actual task manifests show 2 DONE + 1 IN_PROGRESS — the live MF-060 symptom
# (an Agent-Team/SendMessage-driven objective bypassing stop-hook.sh's recompute).
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
cat > "$TEST_DIR/nazgul/plan.md" << 'PLAN_EOF'
# Nazgul Plan

## Objective
Test objective

## Status Summary
- Total tasks: 3
- DONE: 0 | READY: 0 | IN_PROGRESS: 0 | IN_REVIEW: 0 | IMPLEMENTED: 0 | CHANGES_REQUESTED: 0 | BLOCKED: 0 | PLANNED: 3

## Recovery Pointer
- **Current Task:** none
- **Last Action:** Plan created, no tasks started
- **Next Action:** Run discovery, then begin task execution
- **Last Checkpoint:** none
- **Last Commit:** none

## Tasks
PLAN_EOF
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "stale plan.md is flagged" "$output" "Status Summary is stale"
assert_contains "stale warning cites MF-060" "$output" "MF-060"
teardown_temp_dir

# --- Test 12: Telemetry-dark — matching plan.md Status Summary stays quiet ---
# Declared counts agree with the actual manifests, so no diagnostic should fire.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
cat > "$TEST_DIR/nazgul/plan.md" << 'PLAN_EOF'
# Nazgul Plan

## Objective
Test objective

## Status Summary
- Total tasks: 3
- DONE: 2 | READY: 0 | IN_PROGRESS: 1 | IN_REVIEW: 0 | IMPLEMENTED: 0 | CHANGES_REQUESTED: 0 | BLOCKED: 0 | PLANNED: 0

## Recovery Pointer
- **Current Task:** none
- **Last Action:** none
- **Next Action:** none
- **Last Checkpoint:** none
- **Last Commit:** none

## Tasks
PLAN_EOF
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_not_contains "matching plan.md stays quiet" "$output" "Status Summary is stale"
teardown_temp_dir

# --- Test 13: Telemetry-dark — plan.md with no Status Summary is flagged, non-fatal ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
cat > "$TEST_DIR/nazgul/plan.md" << 'PLAN_EOF'
# Nazgul Plan

## Objective
Test objective, no Status Summary section at all

## Recovery Pointer
- **Current Task:** none
- **Last Action:** none
- **Next Action:** none
- **Last Checkpoint:** none
- **Last Commit:** none

## Tasks
PLAN_EOF
create_task_file "TASK-001" "DONE"
ec=0
output=$(bash "$SESSION_SCRIPT" 2>&1) || ec=$?
assert_exit_code "unparseable Status Summary: exit 0 (non-blocking)" "$ec" 0
assert_contains "unparseable Status Summary is flagged" "$output" "no parseable"
teardown_temp_dir

report_results
