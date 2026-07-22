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
  local file_path="$1" new_status="$2" old_status="${3:-READY}"
  jq -n \
    --arg fp "$file_path" \
    --arg os "- **Status**: $old_status" \
    --arg ns "- **Status**: $new_status" \
    '{"tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":$os,"new_string":$ns}}'
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
setup_nazgul_dir
# File does not exist yet — guard sees empty OLD_STATUS
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "PLANNED")
run_guard "$input"
assert_exit_code "new task PLANNED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 3: New task file with READY initial status — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "READY")
run_guard "$input"
assert_exit_code "new task READY allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 4: New task file with DONE initial status — blocked (exit 2)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "new task DONE blocked" "$GUARD_EC" 2
assert_contains "new task DONE message" "$GUARD_STDERR" "must start as PLANNED or READY"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 5: Valid transition PLANNED -> READY
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "PLANNED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "READY")
run_guard "$input"
assert_exit_code "PLANNED->READY allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 6: Valid transition READY -> IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "READY"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "READY->IN_PROGRESS allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 7: Valid transition IN_PROGRESS -> IMPLEMENTED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- abc1234def')
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
run_guard "$input"
assert_exit_code "IN_PROGRESS->IMPLEMENTED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 8: Valid transition IN_PROGRESS -> BLOCKED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "BLOCKED")
run_guard "$input"
assert_exit_code "IN_PROGRESS->BLOCKED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 9: Invalid transition PLANNED -> DONE — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "PLANNED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "PLANNED->DONE blocked" "$GUARD_EC" 2
assert_contains "PLANNED->DONE message" "$GUARD_STDERR" "Invalid state transition"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 10: Invalid transition READY -> DONE — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "READY"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "READY->DONE blocked" "$GUARD_EC" 2
assert_contains "READY->DONE message" "$GUARD_STDERR" "Invalid state transition"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 11: Same status — no-op, always allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "same status allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 12: Review gate — IN_REVIEW->DONE without review directory — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "DONE without review dir blocked" "$GUARD_EC" 2
assert_contains "DONE without review dir message" "$GUARD_STDERR" "No review directory"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 13: Review gate — IN_REVIEW->DONE with approved review — allowed
# create_review_dir creates nazgul/reviews/TASK-001/code-reviewer.md with APPROVED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "DONE with approved review allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 14: Review gate — missing reviewer file — blocked
# Config has two reviewers; review dir only has code-reviewer.md
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer", "security-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
# create_review_dir only created code-reviewer.md; security-reviewer.md is absent
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "missing reviewer blocks DONE" "$GUARD_EC" 2
assert_contains "missing reviewer message" "$GUARD_STDERR" "Missing reviews"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 15: Review gate — unapproved review (CHANGES_REQUESTED verdict) — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" << 'REVIEW_EOF'
# Code Review: TASK-001

## Verdict: CHANGES_REQUESTED

Issues found — please fix before marking DONE.
REVIEW_EOF
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "unapproved review blocks DONE" "$GUARD_EC" 2
assert_contains "unapproved review message" "$GUARD_STDERR" "does not contain APPROVED"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 15b: Review gate — summary.md only (no per-reviewer file) — blocked
# APPROVED text inside summary.md must NOT satisfy the gate
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/summary.md" << 'REVIEW_EOF'
# Review Summary: TASK-001

Verdict: APPROVED (all reviewers)
REVIEW_EOF
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "summary-only evidence blocked" "$GUARD_EC" 2
assert_contains "summary-only evidence message" "$GUARD_STDERR" "Missing reviews"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 16: YOLO mode — review gate guards APPROVED instead of DONE
# In YOLO mode, writing APPROVED requires review checks; no reviews = blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.afk.yolo = true' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
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
setup_nazgul_dir
create_task_file "TASK-001" "READY"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_edit_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "Edit tool READY->IN_PROGRESS allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 18: Empty stdin — always allowed (exit 0)
# ---------------------------------------------------------------------------
GUARD_STDERR=$(echo "" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
assert_exit_code "empty stdin allowed" "$GUARD_EC" 0

# ---------------------------------------------------------------------------
# Test 19: IN_PROGRESS -> IMPLEMENTED without commit SHA — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IMPLEMENTED")
run_guard "$input"
assert_exit_code "IMPLEMENTED without commit SHA blocked" "$GUARD_EC" 2
assert_contains "IMPLEMENTED without SHA message" "$GUARD_STDERR" "commit SHA"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 20: IN_PROGRESS -> IMPLEMENTED with commit SHA (Write) — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
# Build input with commit SHA in content
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- abc1234def')
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
run_guard "$input"
assert_exit_code "IMPLEMENTED with commit SHA allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 20b: IN_PROGRESS -> IMPLEMENTED via Edit — SHA already in file on disk
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file_with_commits "TASK-001" "IN_PROGRESS" "abc1234def"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
# Edit only changes the status line — SHA is in the existing file, not in new_string
input=$(make_edit_input "$TASK_PATH" "IMPLEMENTED" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "IMPLEMENTED via Edit with SHA on disk allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 21: IMPLEMENTED -> IN_REVIEW without review directory — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IMPLEMENTED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "IN_REVIEW without review dir blocked" "$GUARD_EC" 2
assert_contains "IN_REVIEW without review dir message" "$GUARD_STDERR" "review directory"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 22: IMPLEMENTED -> IN_REVIEW with review directory — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IMPLEMENTED"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "IN_REVIEW with review dir allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 23: Source file edit with no IN_PROGRESS task — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "READY"
input=$(jq -n --arg fp "$TEST_DIR/src/main.ts" '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit without active task blocked" "$GUARD_EC" 2
assert_contains "source edit blocked message" "$GUARD_STDERR" "No task is IN_PROGRESS"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 24: Source file edit with an IN_PROGRESS task — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "IN_PROGRESS"
input=$(jq -n --arg fp "$TEST_DIR/src/main.ts" '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit with active task allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 25: Nazgul file edit with no IN_PROGRESS task — always allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "READY"
input=$(jq -n --arg fp "$TEST_DIR/nazgul/plan.md" '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"# Plan"}}')
run_guard "$input"
assert_exit_code "nazgul file edit always allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 26: Source file edit with no nazgul/tasks/ dir — allowed (not initialized)
# ---------------------------------------------------------------------------
setup_temp_dir
# No setup_nazgul_dir — no nazgul/ directory at all
input=$(jq -n --arg fp "$TEST_DIR/src/main.ts" '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit without nazgul dir allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 27: Source file edit with guards.requireActiveTask=false — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = false'
create_task_file "TASK-001" "READY"
input=$(jq -n --arg fp "$TEST_DIR/src/main.ts" '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit with guard disabled allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 28: Source file edit with empty nazgul/tasks/ dir — allowed (no active loop)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
# nazgul/tasks/ exists but has no TASK files
input=$(jq -n --arg fp "$TEST_DIR/src/main.ts" '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit with empty tasks dir allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 29: Nazgul file edit with relative path — always allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "READY"
input=$(jq -n '{"tool_name":"Write","tool_input":{"file_path":"nazgul/plan.md","content":"# Plan"}}')
run_guard "$input"
assert_exit_code "nazgul relative path edit always allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 30: IN_PROGRESS -> IMPLEMENTED via Edit without SHA anywhere — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
# Edit tool: neither new_string nor existing file has a SHA
input=$(make_edit_input "$TASK_PATH" "IMPLEMENTED" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "IMPLEMENTED via Edit without SHA blocked" "$GUARD_EC" 2
assert_contains "IMPLEMENTED via Edit without SHA message" "$GUARD_STDERR" "commit SHA"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 31: simplify-report.md excluded from reviewer file count
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
# Add a simplify-report.md — should NOT count as a reviewer file
cat > "$TEST_DIR/nazgul/reviews/TASK-001/simplify-report.md" << 'REPORT_EOF'
# Simplify Report: TASK-001
## Summary
- Findings: 0
REPORT_EOF
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "simplify-report.md excluded from reviewer count" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 32: MultiEdit with invalid state transition — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "PLANNED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(jq -n --arg fp "$TASK_PATH" \
  --arg os "- **Status**: PLANNED" \
  --arg ns "- **Status**: DONE" '{
  "tool_name": "MultiEdit",
  "tool_input": {
    "edits": [
      {"file_path": $fp, "old_string": $os, "new_string": $ns}
    ]
  }
}')
run_guard "$input"
assert_exit_code "MultiEdit invalid transition blocked" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 33: MultiEdit with valid state transition — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "PLANNED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(jq -n --arg fp "$TASK_PATH" \
  --arg os "- **Status**: PLANNED" \
  --arg ns "- **Status**: READY" '{
  "tool_name": "MultiEdit",
  "tool_input": {
    "edits": [
      {"file_path": $fp, "old_string": $os, "new_string": $ns}
    ]
  }
}')
run_guard "$input"
assert_exit_code "MultiEdit valid transition allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 34: MultiEdit source edit without active task — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "READY"
input=$(jq -n --arg fp "$TEST_DIR/src/main.ts" '{
  "tool_name": "MultiEdit",
  "tool_input": {
    "edits": [
      {"file_path": $fp, "old_string": "old", "new_string": "new"}
    ]
  }
}')
run_guard "$input"
assert_exit_code "MultiEdit source edit without active task blocked" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 35: Source file edit with IN_PROGRESS patch (no TASK in progress) — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "APPROVED"
mkdir -p "$TEST_DIR/nazgul/tasks/patches"
cat > "$TEST_DIR/nazgul/tasks/patches/PATCH-001.md" << 'PATCH_EOF'
# PATCH-001: Test patch

- **Status**: IN_PROGRESS
- **Created**: 2026-03-23T00:00:00Z
- **Source**: /nazgul:patch
PATCH_EOF
input=$(jq -n --arg fp "$TEST_DIR/src/main.ts" '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit with IN_PROGRESS patch allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 36: Source file edit with no IN_PROGRESS patch or task — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "APPROVED"
mkdir -p "$TEST_DIR/nazgul/tasks/patches"
cat > "$TEST_DIR/nazgul/tasks/patches/PATCH-001.md" << 'PATCH_EOF'
# PATCH-001: Test patch

- **Status**: DONE
- **Created**: 2026-03-23T00:00:00Z
- **Source**: /nazgul:patch
PATCH_EOF
input=$(jq -n --arg fp "$TEST_DIR/src/main.ts" '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit with DONE patch still blocked" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 37: BLOCKED -> READY allowed (/nazgul:task unblock path)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "BLOCKED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "READY")
run_guard "$input"
assert_exit_code "BLOCKED->READY allowed (unblock)" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 38: BLOCKED -> IN_REVIEW allowed when review dir exists AND the blocker
# is a review-evidence blocker (--materialize)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "BLOCKED" "none" "review evidence missing (code-reviewer) — run /nazgul:review --materialize TASK-001"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "BLOCKED->IN_REVIEW with review dir allowed (materialize)" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 38b: BLOCKED -> IN_REVIEW without review dir — blocked
# Proves the materialize path still requires the review directory.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "BLOCKED" "none" "review evidence missing (code-reviewer) — run /nazgul:review --materialize TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "BLOCKED->IN_REVIEW without review dir blocked" "$GUARD_EC" 2
assert_contains "BLOCKED->IN_REVIEW without dir message" "$GUARD_STDERR" "review directory"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 38c: BLOCKED for a non-evidence reason -> IN_REVIEW rejected even with
# a review dir — materialize must not bypass unrelated blockers (git
# conflicts, test failures). Those go through /nazgul:task unblock instead.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "BLOCKED" "none" "git conflict — unmerged files detected"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "BLOCKED (non-evidence) ->IN_REVIEW rejected" "$GUARD_EC" 2
assert_contains "non-evidence blocker message" "$GUARD_STDERR" "review-evidence repair"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 39: BLOCKED -> DONE still rejected — BLOCKED is not a free-for-all
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "BLOCKED"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "BLOCKED->DONE blocked" "$GUARD_EC" 2
assert_contains "BLOCKED->DONE message" "$GUARD_STDERR" "Invalid state transition"
teardown_temp_dir

# ---------------------------------------------------------------------------
# FILE SCOPE GUARD TESTS (TASK-003)
# Tests the file-scope extension inside the HAS_ACTIVE=true allow path.
# ---------------------------------------------------------------------------

# Helper: create a task file with an explicit File Scope field.
create_task_with_file_scope() {
  local id="$1" status="$2" scope="$3"
  cat > "$TEST_DIR/nazgul/tasks/${id}.md" << TASK_EOF
# ${id}: Test task

- **Status**: ${status}
- **Depends on**: none
- **Group**: 1
- **Retry count**: 0/3
- **Assigned to**: implementer
- **File Scope**: ${scope}
TASK_EOF
}

# ---------------------------------------------------------------------------
# Test 40: File scope guard — BLOCK: out-of-scope Write
# Active task scope = scripts/new-guard.sh; editing scripts/unrelated.sh -> exit 2
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_with_file_scope "TASK-001" "IN_PROGRESS" "scripts/new-guard.sh"
input=$(jq -n --arg fp "$TEST_DIR/scripts/unrelated.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"echo hello"}}')
run_guard "$input"
assert_exit_code "file-scope: out-of-scope Write blocked" "$GUARD_EC" 2
assert_contains "file-scope: out-of-scope message mentions scope" "$GUARD_STDERR" "file scope"
assert_contains "file-scope: block message names the blocked file path" "$GUARD_STDERR" "unrelated.sh"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 41: File scope guard — ALLOW: in-scope Write
# Active task scope = scripts/new-guard.sh; editing scripts/new-guard.sh -> exit 0
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_with_file_scope "TASK-001" "IN_PROGRESS" "scripts/new-guard.sh"
input=$(jq -n --arg fp "$TEST_DIR/scripts/new-guard.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"echo hello"}}')
run_guard "$input"
assert_exit_code "file-scope: in-scope Write allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 42: File scope guard — ALLOW: File Scope field absent -> no restriction
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "IN_PROGRESS"
# No File Scope field in this fixture — guard must allow any source file
input=$(jq -n --arg fp "$TEST_DIR/scripts/any-file.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"echo hi"}}')
run_guard "$input"
assert_exit_code "file-scope: absent File Scope allows all" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 43: File scope guard — ALLOW: File Scope field empty string -> no restriction
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_with_file_scope "TASK-001" "IN_PROGRESS" ""
input=$(jq -n --arg fp "$TEST_DIR/scripts/any-file.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"echo hi"}}')
run_guard "$input"
assert_exit_code "file-scope: empty File Scope allows all" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 44: File scope guard — ALLOW: nazgul/ path exempt regardless of scope
# Active task scope = scripts/new-guard.sh; editing nazgul/tasks/TASK-001.md -> exit 0
# (nazgul/ paths early-exit before the scope check is even reached)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_with_file_scope "TASK-001" "IN_PROGRESS" "scripts/new-guard.sh"
input=$(jq -n --arg fp "$TEST_DIR/nazgul/tasks/TASK-001.md" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"# Task"}}')
run_guard "$input"
assert_exit_code "file-scope: nazgul/ path exempt from scope check" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 45: File scope guard — ALLOW: docs/ path exempt regardless of scope
# Active task scope = scripts/new-guard.sh; editing docs/TRD.md -> exit 0
# (docs/ paths early-exit before the scope check is even reached)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.guards.requireActiveTask = true'
create_task_with_file_scope "TASK-001" "IN_PROGRESS" "scripts/new-guard.sh"
input=$(jq -n '{"tool_name":"Write","tool_input":{"file_path":"docs/TRD.md","content":"# TRD"}}')
run_guard "$input"
assert_exit_code "file-scope: docs/ path exempt from scope check" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# FORBIDDEN TRANSITION TESTS (TASK-001 — RULES.md §2 hardening)
# Each test verifies exit 2 AND that stderr names the from-state or an allowed next-state.
# ---------------------------------------------------------------------------

# Helper: make a Write input whose content uses YAML frontmatter for status.
make_frontmatter_write_input() {
  local file_path="$1" status="$2"
  local content
  content="---
status: ${status}
---
# TASK-001: Test

## Metadata
- **ID**: TASK-001
- **Group**: 1
"
  jq -n \
    --arg fp "$file_path" \
    --arg content "$content" \
    '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}'
}

# ---------------------------------------------------------------------------
# Test 46: FORBIDDEN — PLANNED -> IN_PROGRESS (must go through READY)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "PLANNED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "PLANNED->IN_PROGRESS blocked" "$GUARD_EC" 2
assert_contains "PLANNED->IN_PROGRESS message names from-state" "$GUARD_STDERR" "PLANNED"
assert_contains "PLANNED->IN_PROGRESS message names allowed next" "$GUARD_STDERR" "READY"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 47: FORBIDDEN — READY -> IMPLEMENTED (must go through IN_PROGRESS)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "READY"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- abc1234def')
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
run_guard "$input"
assert_exit_code "READY->IMPLEMENTED blocked" "$GUARD_EC" 2
assert_contains "READY->IMPLEMENTED message names from-state" "$GUARD_STDERR" "READY"
assert_contains "READY->IMPLEMENTED message names allowed next" "$GUARD_STDERR" "IN_PROGRESS"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 48: FORBIDDEN — IN_PROGRESS -> IN_REVIEW (must go through IMPLEMENTED)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "IN_PROGRESS->IN_REVIEW blocked" "$GUARD_EC" 2
assert_contains "IN_PROGRESS->IN_REVIEW message names from-state" "$GUARD_STDERR" "IN_PROGRESS"
assert_contains "IN_PROGRESS->IN_REVIEW message names allowed next" "$GUARD_STDERR" "IMPLEMENTED"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 49: FORBIDDEN — IN_PROGRESS -> DONE (must go through IMPLEMENTED/IN_REVIEW)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_PROGRESS"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "IN_PROGRESS->DONE blocked" "$GUARD_EC" 2
assert_contains "IN_PROGRESS->DONE message names from-state" "$GUARD_STDERR" "IN_PROGRESS"
assert_contains "IN_PROGRESS->DONE message names allowed next" "$GUARD_STDERR" "IMPLEMENTED"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 50: FORBIDDEN — PLANNED -> DONE (skips all intermediate states)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "PLANNED"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "PLANNED->DONE blocked" "$GUARD_EC" 2
assert_contains "PLANNED->DONE message names from-state" "$GUARD_STDERR" "PLANNED"
assert_contains "PLANNED->DONE message names allowed next" "$GUARD_STDERR" "READY"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 51: FORBIDDEN — IN_REVIEW -> IN_PROGRESS (must go through CHANGES_REQUESTED)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_REVIEW"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "IN_REVIEW->IN_PROGRESS blocked" "$GUARD_EC" 2
assert_contains "IN_REVIEW->IN_PROGRESS message names from-state" "$GUARD_STDERR" "IN_REVIEW"
assert_contains "IN_REVIEW->IN_PROGRESS message names allowed next" "$GUARD_STDERR" "CHANGES_REQUESTED"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 52: FORBIDDEN — DONE -> READY (DONE is terminal)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "READY")
run_guard "$input"
assert_exit_code "DONE->READY blocked" "$GUARD_EC" 2
assert_contains "DONE->READY message names terminal state" "$GUARD_STDERR" "terminal"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 53: FORBIDDEN — DONE -> IN_PROGRESS (DONE is terminal)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "DONE->IN_PROGRESS blocked" "$GUARD_EC" 2
assert_contains "DONE->IN_PROGRESS message names terminal state" "$GUARD_STDERR" "terminal"
teardown_temp_dir

# ---------------------------------------------------------------------------
# ALLOWED TRANSITION COMPLETENESS TESTS (TASK-001 — precision gate)
# Tests for transitions not yet explicitly covered in the existing suite.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test 54: ALLOWED — IN_REVIEW -> APPROVED (YOLO mode)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.afk.yolo = true' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "APPROVED")
run_guard "$input"
assert_exit_code "IN_REVIEW->APPROVED allowed (YOLO)" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 55: ALLOWED — IN_REVIEW -> CHANGES_REQUESTED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_REVIEW"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "CHANGES_REQUESTED")
run_guard "$input"
assert_exit_code "IN_REVIEW->CHANGES_REQUESTED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 56: ALLOWED — APPROVED -> DONE (YOLO + task-pr)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.afk.yolo = true' '.agents.reviewers = ["code-reviewer"]'
# FEAT-014: legacy fixture used deliberately — canonical status:APPROVED hits MF-001
# (INVALID) until TASK-002 adds APPROVED to VALID_STATUSES. TASK-004 reverts this to
# create_task_file as the APPROVED-completion regression proving the fix.
create_task_file_legacy "TASK-001" "APPROVED"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "APPROVED->DONE allowed (YOLO)" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 57: ALLOWED — CHANGES_REQUESTED -> IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "CHANGES_REQUESTED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "CHANGES_REQUESTED->IN_PROGRESS allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# FULL-MANIFEST WRITE REGRESSION (TASK-001 — YAML frontmatter extraction bug)
# Verifies that a full-file Write with status in YAML frontmatter is extracted
# and the forbidden transition is blocked (the FEAT-002 bypass path).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test 58: REGRESSION — full-manifest Write IN_PROGRESS->DONE via YAML frontmatter
# This is the exact path that slipped through during FEAT-002.
# The file on disk has status IN_PROGRESS; the Write replaces the whole manifest
# with YAML frontmatter containing "status: DONE". Must be blocked.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_PROGRESS"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_frontmatter_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "full-manifest Write IN_PROGRESS->DONE via frontmatter blocked" "$GUARD_EC" 2
assert_contains "frontmatter Write blocked message" "$GUARD_STDERR" "Invalid state transition"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 59: REGRESSION — full-manifest Write PLANNED->DONE via YAML frontmatter
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "PLANNED"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_frontmatter_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "full-manifest Write PLANNED->DONE via frontmatter blocked" "$GUARD_EC" 2
assert_contains "frontmatter PLANNED->DONE message names from-state" "$GUARD_STDERR" "PLANNED"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 60: REGRESSION — full-manifest Write IN_PROGRESS->READY via YAML frontmatter
# (not a real workflow but confirms frontmatter extraction works for any token)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_frontmatter_write_input "$TASK_PATH" "READY")
run_guard "$input"
assert_exit_code "full-manifest Write IN_PROGRESS->READY via frontmatter blocked" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 61: ALLOWED — full-manifest Write IN_PROGRESS->IMPLEMENTED via YAML frontmatter
# The 4th extractor must also allow valid transitions — no false positives.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
content="---
status: IMPLEMENTED
---
# TASK-001: Test

## Metadata
- **ID**: TASK-001
- **Group**: 1

## Commits
- abc1234def
"
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
run_guard "$input"
assert_exit_code "full-manifest Write IN_PROGRESS->IMPLEMENTED via frontmatter allowed" "$GUARD_EC" 0
teardown_temp_dir


# ---------------------------------------------------------------------------
# Test 62: ALLOWED — IN_REVIEW -> BLOCKED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_REVIEW"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "BLOCKED")
run_guard "$input"
assert_exit_code "IN_REVIEW->BLOCKED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 63: ALLOWED — CHANGES_REQUESTED -> BLOCKED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "CHANGES_REQUESTED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "BLOCKED")
run_guard "$input"
assert_exit_code "CHANGES_REQUESTED->BLOCKED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 64: ALLOWED — PLANNED -> BLOCKED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "PLANNED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "BLOCKED")
run_guard "$input"
assert_exit_code "PLANNED->BLOCKED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 65: ALLOWED — READY -> BLOCKED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "READY"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "BLOCKED")
run_guard "$input"
assert_exit_code "READY->BLOCKED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 66: ALLOWED — IMPLEMENTED -> BLOCKED
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IMPLEMENTED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "BLOCKED")
run_guard "$input"
assert_exit_code "IMPLEMENTED->BLOCKED allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 67: BLOCKED — .dispatch.json write while its OWN unit's task is IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
input=$(jq -n --arg fp "$TEST_DIR/nazgul/reviews/TASK-001/.dispatch.json" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"{}"}}')
run_guard "$input"
assert_exit_code "dispatch manifest write blocked during IN_PROGRESS" "$GUARD_EC" 2
assert_contains "dispatch manifest blocked message" "$GUARD_STDERR" "IN_PROGRESS"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 68: ALLOWED — .dispatch.json write with no task IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IMPLEMENTED"
input=$(jq -n --arg fp "$TEST_DIR/nazgul/reviews/TASK-001/.dispatch.json" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"{}"}}')
run_guard "$input"
assert_exit_code "dispatch manifest write allowed without active task" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 69: BLOCKED — diff.patch write while its OWN unit's task is IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
input=$(jq -n --arg fp "$TEST_DIR/nazgul/reviews/TASK-001/diff.patch" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"diff --git a b"}}')
run_guard "$input"
assert_exit_code "diff.patch write blocked during IN_PROGRESS" "$GUARD_EC" 2
assert_contains "diff.patch blocked message" "$GUARD_STDERR" "IN_PROGRESS"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 70: ALLOWED — diff.patch write with no task IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IMPLEMENTED"
input=$(jq -n --arg fp "$TEST_DIR/nazgul/reviews/TASK-001/diff.patch" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"diff --git a b"}}')
run_guard "$input"
assert_exit_code "diff.patch write allowed without active task" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 71: ALLOWED (unit-scoped) — dispatch write for TASK-001's own unit while
# a DIFFERENT task (TASK-002, a parallel Agent-Teams wave) is IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IMPLEMENTED"
create_task_file "TASK-002" "IN_PROGRESS"
input=$(jq -n --arg fp "$TEST_DIR/nazgul/reviews/TASK-001/.dispatch.json" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"{}"}}')
run_guard "$input"
assert_exit_code "dispatch write for unrelated finished unit not blocked by another IN_PROGRESS task" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 72: BLOCKED (group-scoped) — GROUP-1 dispatch write blocked when a
# Group-1 task is IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"   # create_task_file defaults to Group: 1
input=$(jq -n --arg fp "$TEST_DIR/nazgul/reviews/GROUP-1/.dispatch.json" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"{}"}}')
run_guard "$input"
assert_exit_code "GROUP-1 dispatch write blocked when a group-1 task is IN_PROGRESS" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 73: ALLOWED (group-scoped) — GROUP-2 dispatch write NOT blocked when
# only a Group-1 task is IN_PROGRESS
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"   # Group: 1
input=$(jq -n --arg fp "$TEST_DIR/nazgul/reviews/GROUP-2/.dispatch.json" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"{}"}}')
run_guard "$input"
assert_exit_code "GROUP-2 dispatch write allowed when only group-1 has an IN_PROGRESS task" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 74: BLOCKED (fallback) — FEATURE-* dispatch write blocked when ANY
# task is IN_PROGRESS (feature review spans the whole branch)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
input=$(jq -n --arg fp "$TEST_DIR/nazgul/reviews/FEATURE-FEAT-001/.dispatch.json" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":"{}"}}')
run_guard "$input"
assert_exit_code "FEATURE-* dispatch write blocked when any task is IN_PROGRESS" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 75: Multi-line old_string spanning the YAML frontmatter fence —
# IN_PROGRESS -> IMPLEMENTED with commit SHA on disk — allowed (regression
# test for BSD/macOS awk "newline in string" on -v with embedded newlines)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
cat > "$TASK_PATH" << 'EOF'
---
status: IN_PROGRESS
---
# TASK-001: Test

## Commits
- abc1234def
EOF
input=$(jq -n --arg fp "$TASK_PATH" \
  --arg os $'---\nstatus: IN_PROGRESS\n---' \
  --arg ns $'---\nstatus: IMPLEMENTED\n---' \
  '{"tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":$os,"new_string":$ns}}')
run_guard "$input"
assert_exit_code "multi-line frontmatter old_string, SHA on disk, allowed" "$GUARD_EC" 0
assert_not_contains "no raw awk crash on multi-line old_string" "$GUARD_STDERR" "newline in string"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 76: Multi-line old_string spanning the frontmatter fence — no commit
# SHA anywhere in file — guard evaluates and blocks with the proper message
# (not a silent no-op, not a raw awk crash)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
cat > "$TASK_PATH" << 'EOF'
---
status: IN_PROGRESS
---
# TASK-001: Test
EOF
input=$(jq -n --arg fp "$TASK_PATH" \
  --arg os $'---\nstatus: IN_PROGRESS\n---' \
  --arg ns $'---\nstatus: IMPLEMENTED\n---' \
  '{"tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":$os,"new_string":$ns}}')
run_guard "$input"
assert_exit_code "multi-line frontmatter old_string, no SHA, blocked" "$GUARD_EC" 2
assert_contains "blocked for the right reason (missing commit SHA)" "$GUARD_STDERR" "commit SHA"
assert_not_contains "no raw awk crash on multi-line old_string" "$GUARD_STDERR" "newline in string"
teardown_temp_dir

report_results
