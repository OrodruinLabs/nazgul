#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because script under test exits non-zero to block transitions

TEST_NAME="test-task-state-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/task-state-guard.sh"

# Helper: build JSON hook input for a Write tool call.
# FILE_PATH must be the absolute path the guard will read from disk.
make_write_input() {
  local file_path="$1" status="$2"
  # Use printf to avoid interpretation of backslash sequences in content
  local content
  content=$(printf '# TASK-001: Test\n\n- **Status**: %s\n- **Group**: 1' "$status")
  jq -n \
    --arg fp "$file_path" \
    --arg content "$content" \
    '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}'
}

# Helper: build JSON hook input for an Edit tool call.
# new_string must contain the new status line.
make_edit_input() {
  local file_path="$1" new_status="$2"
  jq -n \
    --arg fp "$file_path" \
    --arg ns "- **Status**: $new_status" \
    '{"tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"- **Status**: READY","new_string":$ns}}'
}

# Helper: pipe input to the guard, capture stderr and exit code.
# Sets GUARD_EC and GUARD_STDERR.
run_guard() {
  local input="$1"
  GUARD_STDERR=$(echo "$input" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
}

# ---------------------------------------------------------------------------
# Test 1: Non-task file — always allowed (exit 0)
# ---------------------------------------------------------------------------
setup_temp_dir
input='{"tool_name":"Write","tool_input":{"file_path":"src/main.sh","content":"hello"}}'
run_guard "$input"
assert_exit_code "non-task file allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 2: New task file with PLANNED initial status — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
# File does not exist yet — guard sees empty OLD_STATUS
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "PLANNED")
run_guard "$input"
assert_exit_code "new task PLANNED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 3: New task file with READY initial status — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "READY")
run_guard "$input"
assert_exit_code "new task READY allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 4: New task file with DONE initial status — blocked (exit 2)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "new task DONE blocked" "$GUARD_EC" 2
assert_contains "new task DONE message" "$GUARD_STDERR" "must start as PLANNED or READY"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 5: Valid transition PLANNED -> READY
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "PLANNED"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "READY")
run_guard "$input"
assert_exit_code "PLANNED->READY allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 6: Valid transition READY -> IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "READY"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "READY->IN_PROGRESS allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 7: Valid transition IN_PROGRESS -> IMPLEMENTED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IMPLEMENTED")
run_guard "$input"
assert_exit_code "IN_PROGRESS->IMPLEMENTED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 8: Valid transition IN_PROGRESS -> BLOCKED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "BLOCKED")
run_guard "$input"
assert_exit_code "IN_PROGRESS->BLOCKED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 9: Invalid transition PLANNED -> DONE — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "PLANNED"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "PLANNED->DONE blocked" "$GUARD_EC" 2
assert_contains "PLANNED->DONE message" "$GUARD_STDERR" "Invalid state transition"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 10: Invalid transition READY -> DONE — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "READY"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "READY->DONE blocked" "$GUARD_EC" 2
assert_contains "READY->DONE message" "$GUARD_STDERR" "Invalid state transition"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 11: Same status — no-op, always allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "same status allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 12: Review gate — IN_REVIEW->DONE without review directory — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "DONE without review dir blocked" "$GUARD_EC" 2
assert_contains "DONE without review dir message" "$GUARD_STDERR" "No review directory"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 13: Review gate — IN_REVIEW->DONE with approved review — allowed
# create_review_dir creates hydra/reviews/TASK-001/code-reviewer.md with APPROVED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "DONE with approved review allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 14: Review gate — missing reviewer file — blocked
# Config has two reviewers; review dir only has code-reviewer.md
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.agents.reviewers = ["code-reviewer", "security-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
# create_review_dir only created code-reviewer.md; security-reviewer.md is absent
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "missing reviewer blocks DONE" "$GUARD_EC" 2
assert_contains "missing reviewer message" "$GUARD_STDERR" "Missing reviews"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 15: Review gate — unapproved review (CHANGES_REQUESTED verdict) — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
mkdir -p "$TEST_DIR/hydra/reviews/TASK-001"
cat > "$TEST_DIR/hydra/reviews/TASK-001/code-reviewer.md" << 'REVIEW_EOF'
# Code Review: TASK-001

## Verdict: CHANGES_REQUESTED

Issues found — please fix before marking DONE.
REVIEW_EOF
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "unapproved review blocks DONE" "$GUARD_EC" 2
assert_contains "unapproved review message" "$GUARD_STDERR" "does not contain APPROVED"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 16: YOLO mode — review gate guards APPROVED instead of DONE
# In YOLO mode, writing APPROVED requires review checks; no reviews = blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.afk.yolo = true' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "APPROVED")
run_guard "$input"
assert_exit_code "YOLO APPROVED without reviews blocked" "$GUARD_EC" 2
assert_contains "YOLO APPROVED blocked message" "$GUARD_STDERR" "No review directory"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 17: Edit tool input — file_path and new_string parsed correctly
# READY -> IN_PROGRESS via Edit tool
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "READY"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_edit_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "Edit tool READY->IN_PROGRESS allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 18: Empty stdin — always allowed (exit 0)
# ---------------------------------------------------------------------------
GUARD_STDERR=$(echo "" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
assert_exit_code "empty stdin allowed" "$GUARD_EC" 0

report_results
