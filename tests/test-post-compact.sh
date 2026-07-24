#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because script under test may exit non-zero during setup edge cases

# Test: post-compact.sh re-injects loop state after compaction, granularity
# awareness (MF-008), idempotent compaction counter (MF-012), and mid-session
# schema migration (MF-050).
TEST_NAME="test-post-compact"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

POSTCOMPACT_SCRIPT="$REPO_ROOT/scripts/post-compact.sh"

# Helper: run post-compact.sh capturing output and exit code
run_postcompact() {
  PC_OUTPUT=$(bash "$POSTCOMPACT_SCRIPT" 2>&1) && PC_EC=0 || PC_EC=$?
}

# --- Test 1: No config — exit 0, no output ---
setup_temp_dir
run_postcompact
assert_exit_code "no config: exit 0" "$PC_EC" 0
teardown_temp_dir

# --- Test 2: Basic output with iteration and mode ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 7' '.max_iterations = 40' '.mode = "hitl"'
run_postcompact
assert_contains "shows iteration" "$PC_OUTPUT" "7/40"
assert_contains "shows mode" "$PC_OUTPUT" "hitl"
teardown_temp_dir

# --- Test 3: Task counts ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
run_postcompact
assert_contains "done count" "$PC_OUTPUT" "1 done"
assert_contains "ready count" "$PC_OUTPUT" "1 ready"
teardown_temp_dir

# --- Test 4: Active task shown ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-003" "IN_PROGRESS"
run_postcompact
assert_contains "active task shown" "$PC_OUTPUT" "Active task: TASK-003"
assert_contains "implementer dispatch suggested" "$PC_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-003"
teardown_temp_dir

# === MF-012: idempotent compaction counter ===

# --- Test 5: fresh compaction (no prior file, no lock) — counter increments to 1 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
run_postcompact
assert_file_exists "compaction_count created" "$TEST_DIR/nazgul/.compaction_count"
val=$(jq -r '.count' "$TEST_DIR/nazgul/.compaction_count")
assert_eq "compaction count is 1" "$val" "1"
assert_contains "stdout shows compaction count" "$PC_OUTPUT" "Compactions: 1"
teardown_temp_dir

# --- Test 6: post-compact.sh claims the lock (mkdir succeeds) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
run_postcompact
assert_dir_exists "MF-012: lock dir claimed by post-compact" "$TEST_DIR/nazgul/.compaction_count.lock"
teardown_temp_dir

# --- Test 7: lock already claimed (e.g. by a second concurrent run) — no
# double increment; NEW_COUNT reported is the existing count. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
printf '{"count": 2, "last_compaction_iteration": 0}\n' > "$TEST_DIR/nazgul/.compaction_count"
mkdir -p "$TEST_DIR/nazgul/.compaction_count.lock"
run_postcompact
val=$(jq -r '.count' "$TEST_DIR/nazgul/.compaction_count")
assert_eq "MF-012: count NOT incremented when lock already claimed" "$val" "2"
assert_contains "MF-012: stdout reflects unincremented count" "$PC_OUTPUT" "Compactions: 2"
teardown_temp_dir

# === MF-008: review-granularity awareness ===

# --- Test 8: group granularity defers the single-task review-gate dispatch
# suggestion for a parked IMPLEMENTED task ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_task_file "TASK-001" "IMPLEMENTED"
run_postcompact
assert_not_contains "MF-008: no single-task review-gate DELEGATE in group mode" \
  "$PC_OUTPUT" "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for TASK-001"
assert_contains "MF-008: defers to aggregate review path" "$PC_OUTPUT" "review granularity is group"
teardown_temp_dir

# --- Test 9: feature granularity, IN_REVIEW task — same deferral ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.review_gate.granularity = "feature"'
create_task_file "TASK-002" "IN_REVIEW"
run_postcompact
assert_not_contains "MF-008: no single-task review-gate DELEGATE in feature mode" \
  "$PC_OUTPUT" "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for TASK-002"
assert_contains "MF-008: feature mode defers to aggregate review path" "$PC_OUTPUT" "review granularity is feature"
teardown_temp_dir

# --- Test 10: task granularity (default) still dispatches per-task review-gate ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.review_gate.granularity = "task"'
create_task_file "TASK-001" "IMPLEMENTED"
run_postcompact
assert_contains "MF-008: task granularity still dispatches per-task review-gate" \
  "$PC_OUTPUT" "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for TASK-001"
assert_not_contains "MF-008: no deferral note in task mode" "$PC_OUTPUT" "review granularity is"
teardown_temp_dir

# === MF-050: mid-session schema migration ===

# --- Test 11: stale schema version triggers migration, config rewritten to target ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.schema_version = 1'
run_postcompact
new_version=$(jq -r '.schema_version' "$TEST_DIR/nazgul/config.json")
target_version=$(jq -r '.schema_version' "$REPO_ROOT/templates/config.json")
assert_eq "MF-050: schema migrated to target version" "$new_version" "$target_version"
assert_contains "MF-050: migration notice surfaced in output" "$PC_OUTPUT" "NOTICE:"
teardown_temp_dir

# --- Test 12: already-current schema — no notice, no-op ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
run_postcompact
assert_not_contains "MF-050: no migration notice when already current" "$PC_OUTPUT" "NOTICE:"
teardown_temp_dir

report_results
