#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: stop-hook.sh loop engine, state machine, checkpoints, promotions
TEST_NAME="test-stop-hook"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

# Helper: run hook capturing output and exit code
# Sets: HOOK_OUTPUT, HOOK_EC
run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# === EXIT CONDITIONS (exit 0) ===

# --- Test 1: No config — exit 0 ---
setup_temp_dir
run_hook
assert_exit_code "no config: exit 0" "$HOOK_EC" 0
teardown_temp_dir

# --- Test 2: Paused — exit 0, paused reset to false ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.paused = true'
create_plan
run_hook
assert_exit_code "paused: exit 0" "$HOOK_EC" 0
val=$(jq -r '.paused' "$TEST_DIR/hydra/config.json")
assert_eq "paused reset to false" "$val" "false"
teardown_temp_dir

# --- Test 3: All tasks DONE — exit 0 ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
create_review_dir "TASK-003"
run_hook
assert_exit_code "all tasks done: exit 0" "$HOOK_EC" 0
teardown_temp_dir

# --- Test 4: Max iterations — exit 0 ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.current_iteration = 39' '.max_iterations = 40'
create_plan
create_task_file "TASK-001" "READY"
run_hook
assert_exit_code "max iterations: exit 0" "$HOOK_EC" 0
assert_contains "max iterations stderr" "$HOOK_OUTPUT" "Max iterations"
teardown_temp_dir

# --- Test 5: Consecutive failures exceeded — exit 0 ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.safety.consecutive_failures = 4' '.safety.max_consecutive_failures = 5' '.safety._prev_done_count = 0'
create_plan
create_task_file "TASK-001" "READY"
run_hook
assert_exit_code "consecutive failures: exit 0" "$HOOK_EC" 0
assert_contains "consecutive failures stderr" "$HOOK_OUTPUT" "consecutive"
teardown_temp_dir

# --- Test 6: AFK timeout — exit 0 ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
past_ts=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$past_ts" ]; then
  create_config ".afk.enabled = true" ".afk.timeout_minutes = 90" ".objective_set_at = \"$past_ts\""
  create_plan
  create_task_file "TASK-001" "READY"
  run_hook
  assert_exit_code "AFK timeout: exit 0" "$HOOK_EC" 0
  assert_contains "AFK timeout stderr" "$HOOK_OUTPUT" "AFK timeout"
else
  _pass "AFK timeout: exit 0 (skipped — date format unavailable)"
  _pass "AFK timeout stderr (skipped)"
fi
teardown_temp_dir

# === CONTINUE LOOP (exit 2) ===

# --- Test 7: READY tasks remain — exit 2 ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
assert_exit_code "READY tasks: exit 2" "$HOOK_EC" 2
assert_contains "continue message" "$HOOK_OUTPUT" "Hydra loop"
teardown_temp_dir

# --- Test 8: IN_PROGRESS task — exit 2 ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
run_hook
assert_exit_code "IN_PROGRESS: exit 2" "$HOOK_EC" 2
assert_contains "active task in output" "$HOOK_OUTPUT" "TASK-001"
teardown_temp_dir

# --- Test 9: CHANGES_REQUESTED — exit 2 with warning ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "CHANGES_REQUESTED"
run_hook
assert_exit_code "CHANGES_REQUESTED: exit 2" "$HOOK_EC" 2
assert_contains "changes requested warning" "$HOOK_OUTPUT" "CHANGES_REQUESTED"
teardown_temp_dir

# === STATE MUTATIONS ===

# --- Test 10: Iteration incremented ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
run_hook
val=$(jq -r '.current_iteration' "$TEST_DIR/hydra/config.json")
assert_eq "iteration incremented to 6" "$val" "6"
teardown_temp_dir

# --- Test 11: Failures reset on progress ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.safety.consecutive_failures = 3' '.safety._prev_done_count = 1'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
create_task_file "TASK-003" "READY"
run_hook
val=$(jq -r '.safety.consecutive_failures' "$TEST_DIR/hydra/config.json")
assert_eq "failures reset to 0" "$val" "0"
teardown_temp_dir

# --- Test 12: Failures incremented on no progress ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.safety.consecutive_failures = 2' '.safety._prev_done_count = 1'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
val=$(jq -r '.safety.consecutive_failures' "$TEST_DIR/hydra/config.json")
assert_eq "failures incremented to 3" "$val" "3"
teardown_temp_dir

# --- Test 13: Checkpoint created ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.current_iteration = 0'
create_plan
create_task_file "TASK-001" "READY"
run_hook
assert_file_exists "checkpoint created" "$TEST_DIR/hydra/checkpoints/iteration-001.json"
teardown_temp_dir

# --- Test 14: Checkpoint has correct fields ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.current_iteration = 0'
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
run_hook
cp_file="$TEST_DIR/hydra/checkpoints/iteration-001.json"
assert_json_field "checkpoint iteration" "$cp_file" ".iteration" "1"
assert_json_field "checkpoint active task" "$cp_file" ".active_task.id" "TASK-001"
assert_json_field "checkpoint total tasks" "$cp_file" ".plan_snapshot.total_tasks" "1"
teardown_temp_dir

# --- Test 15: Recovery pointer updated in plan.md ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.current_iteration = 0'
create_plan
create_task_file "TASK-002" "IN_PROGRESS"
run_hook
assert_file_contains "plan has TASK-002 in pointer" "$TEST_DIR/hydra/plan.md" "TASK-002"
teardown_temp_dir

# --- Test 16: Promote PLANNED -> READY (no deps) ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "PLANNED" "none"
run_hook
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/hydra/tasks/TASK-001.md" | sed 's/.*: //')
assert_eq "PLANNED promoted to READY (no deps)" "$status" "READY"
teardown_temp_dir

# --- Test 17: Promote PLANNED -> READY (deps met) ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "PLANNED" "TASK-001"
run_hook
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/hydra/tasks/TASK-002.md" | sed 's/.*: //')
assert_eq "PLANNED promoted to READY (deps met)" "$status" "READY"
teardown_temp_dir

# --- Test 18: No promote when deps unmet ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
create_task_file "TASK-002" "PLANNED" "TASK-001"
run_hook
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/hydra/tasks/TASK-002.md" | sed 's/.*: //')
assert_eq "PLANNED stays PLANNED (deps unmet)" "$status" "PLANNED"
teardown_temp_dir

# --- Test 19: Checkpoint rotation (keep last 10) ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.current_iteration = 12'
create_plan
create_task_file "TASK-001" "READY"
# Pre-create 12 checkpoint files
for i in $(seq 1 12); do
  printf '{"iteration": %d}\n' "$i" > "$TEST_DIR/hydra/checkpoints/iteration-$(printf '%03d' "$i").json"
done
run_hook
# Now should have iteration-013.json + some survivors from rotation (keeps 10)
cp_count=$(ls -1 "$TEST_DIR/hydra/checkpoints/iteration-"*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$cp_count" -le 10 ]; then
  _pass "checkpoint rotation keeps <= 10"
else
  _fail "checkpoint rotation keeps <= 10" "found $cp_count checkpoints"
fi
teardown_temp_dir

# --- Test 20: Notification on task done ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.notifications.enabled = true' '.safety._prev_done_count = 0'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
assert_file_exists "notifications file created" "$TEST_DIR/hydra/notifications.jsonl"
assert_file_contains "task_complete event" "$TEST_DIR/hydra/notifications.jsonl" "task_complete"
teardown_temp_dir

# --- Test 21: Git conflict blocks task ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
# Create a merge conflict
git -C "$TEST_DIR" checkout -q -b conflict-branch
echo "conflict line A" > "$TEST_DIR/conflict.txt"
git -C "$TEST_DIR" add conflict.txt
git -C "$TEST_DIR" commit -q -m "branch A"
git -C "$TEST_DIR" checkout -q main 2>/dev/null || git -C "$TEST_DIR" checkout -q master
echo "conflict line B" > "$TEST_DIR/conflict.txt"
git -C "$TEST_DIR" add conflict.txt
git -C "$TEST_DIR" commit -q -m "branch B"
git -C "$TEST_DIR" merge conflict-branch --no-commit 2>/dev/null || true
# Now we should have unmerged files
porcelain=$(git -C "$TEST_DIR" status --porcelain 2>/dev/null || echo "")
if echo "$porcelain" | grep -qE '^(U.|.U|AA|DD) '; then
  run_hook
  status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/hydra/tasks/TASK-001.md" | sed 's/.*: //')
  assert_eq "git conflict blocks task" "$status" "BLOCKED"
  assert_file_contains "git conflict notification" "$TEST_DIR/hydra/notifications.jsonl" "git_conflict"
else
  _pass "git conflict blocks task (skipped — no conflict produced)"
  _pass "git conflict notification (skipped)"
fi
teardown_temp_dir

# --- Test 22: Checkpoint is valid JSON ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config '.current_iteration = 0'
create_plan
create_task_file "TASK-001" "READY"
run_hook
if jq empty "$TEST_DIR/hydra/checkpoints/iteration-001.json" 2>/dev/null; then
  _pass "checkpoint is valid JSON"
else
  _fail "checkpoint is valid JSON"
fi
teardown_temp_dir

# --- Test 23: Review gate enforcement — DONE without reviews reset to IMPLEMENTED ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
# Intentionally NO create_review_dir — simulate the violation
create_task_file "TASK-002" "READY"
run_hook
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/hydra/tasks/TASK-001.md" | sed 's/.*: //')
assert_eq "review gate violation resets DONE to IMPLEMENTED" "$status" "IMPLEMENTED"
assert_contains "review gate violation logged" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
teardown_temp_dir

# --- Test 24: Review gate — DONE with reviews stays DONE ---
setup_temp_dir
setup_git_repo
setup_hydra_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/hydra/tasks/TASK-001.md" | sed 's/.*: //')
assert_eq "DONE with reviews stays DONE" "$status" "DONE"
teardown_temp_dir

report_results
