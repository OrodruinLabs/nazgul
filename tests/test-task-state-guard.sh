#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because script under test exits non-zero to block transitions

TEST_NAME="test-task-state-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

# NOTE (MF-013/TASK-001): create_config copies templates/config.json, whose
# review_gate.granularity has defaulted to "group" since v17 — but this file's
# create_review_dir/create_task_file helpers write task-id-keyed evidence
# (reviews/TASK-001/...). Now that resolve_review_unit() makes the DONE/
# IN_REVIEW evidence gates actually honor granularity (previously they always
# behaved as "task" regardless of config), any test here that plants evidence
# at reviews/<task_id> and isn't itself testing group/feature semantics must
# pin '.review_gate.granularity = "task"' explicitly, or the resolver looks
# for reviews/GROUP-1 instead and the test fails for the wrong reason.

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
# Test 7: Valid transition IN_PROGRESS -> IMPLEMENTED (MF-026: SHA must be a
# real, reachable commit)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
REAL_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- %s' "$REAL_SHA")
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
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"'
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
create_config '.agents.reviewers = ["code-reviewer", "security-reviewer"]' '.review_gate.granularity = "task"'
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
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"'
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
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"'
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
# Test 20: IN_PROGRESS -> IMPLEMENTED with a real, verifiable commit SHA
# (Write) — allowed (MF-026)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
REAL_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- %s' "$REAL_SHA")
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
run_guard "$input"
assert_exit_code "IMPLEMENTED with commit SHA allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 20b: IN_PROGRESS -> IMPLEMENTED via Edit — real SHA already in file on
# disk (MF-026)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
REAL_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
create_task_file_with_commits "TASK-001" "IN_PROGRESS" "$REAL_SHA"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
# Edit only changes the status line — SHA is in the existing file, not in new_string
input=$(make_edit_input "$TASK_PATH" "IMPLEMENTED" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "IMPLEMENTED via Edit with SHA on disk allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 20c: IN_PROGRESS -> IMPLEMENTED with a hex-looking but NONEXISTENT SHA
# — now BLOCKS (regression: previously passed the bare grep pattern match,
# MF-026)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- deadbeef1234')
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
run_guard "$input"
assert_exit_code "IMPLEMENTED with nonexistent SHA blocked" "$GUARD_EC" 2
assert_contains "nonexistent SHA blocked message" "$GUARD_STDERR" "commit SHA"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 20d: IN_PROGRESS -> IMPLEMENTED with a real-looking SHA but NOT in a
# git repo at all — fails CLOSED, not a silent pass (MF-026 / ADR-003
# Decision 3)
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- deadbeef1234')
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
run_guard "$input"
assert_exit_code "IMPLEMENTED with no repo at all blocked (fail closed)" "$GUARD_EC" 2
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
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"'
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
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"'
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
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"'
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
# MF-024: fed by the real `Files modified` JSON-array field (via
# get_task_files_modified), NOT the nonexistent "File Scope" field — a real
# planner-shaped manifest fixture (create_task_file_with_files_modified).
# ---------------------------------------------------------------------------

# Helper: create a task file whose real `Files modified` JSON array is a
# single-path scope (or empty when scope is "").
create_task_with_file_scope() {
  local id="$1" status="$2" scope="$3"
  if [ -n "$scope" ]; then
    create_task_file_with_files_modified "$id" "$status" "[\"${scope}\"]"
  else
    create_task_file_with_files_modified "$id" "$status" '[]'
  fi
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
create_config '.afk.yolo = true' '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"'
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
# MF-001 regression: canonical frontmatter (not the legacy list-item fixture) now
# that structured-state.sh's VALID_STATUSES includes APPROVED — proves the fix.
create_task_file "TASK-001" "APPROVED"
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
setup_git_repo
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
REAL_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
content="---
status: IMPLEMENTED
---
# TASK-001: Test

## Metadata
- **ID**: TASK-001
- **Group**: 1

## Commits
- ${REAL_SHA}
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
setup_git_repo
setup_nazgul_dir
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
REAL_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
cat > "$TASK_PATH" << EOF
---
status: IN_PROGRESS
---
# TASK-001: Test

## Commits
- ${REAL_SHA}
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

# ---------------------------------------------------------------------------
# Test 77: Single-source parity — structured-state.sh's VALID_STATUSES and
# task-state-guard.sh's accepted-status vocabulary must agree (ADR-002
# Decision 1 / SC3). Guards against the two lists drifting apart again the
# way MF-001 originated: one hand-maintained list gained APPROVED, the other
# didn't. Rather than scraping the guard's source text (fragile against how
# derivation is implemented), this drives the guard's real frontmatter-status
# recognition path for every token in VALID_STATUSES plus one off-vocabulary
# token, and asserts recognition matches exactly — i.e. the guard's live
# accepted set really does track the library's, not a second hand-copy of it.
# ---------------------------------------------------------------------------
source "$REPO_ROOT/scripts/lib/structured-state.sh"

# recognize_status <token> -> prints "recognized" (guard treated it as a status
# transition — either allowed a fresh PLANNED/READY file, or blocked it with the
# "must start as PLANNED or READY" message) or "unrecognized" (guard fell through
# to "not a status change" and silently allowed with no message).
recognize_status() {
  local token="$1"
  setup_temp_dir
  setup_nazgul_dir
  TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-999.md"
  local content
  content=$(printf -- '---\nstatus: %s\n---\n# TASK-999: Test\n' "$token")
  local input
  input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
    '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
  run_guard "$input"
  teardown_temp_dir
  if [ "$token" = "PLANNED" ] || [ "$token" = "READY" ]; then
    [ "$GUARD_EC" -eq 0 ] && echo "recognized" || echo "unrecognized"
  else
    if [ "$GUARD_EC" -eq 2 ] && printf '%s' "$GUARD_STDERR" | grep -q "must start as PLANNED or READY, not ${token}"; then
      echo "recognized"
    else
      echo "unrecognized"
    fi
  fi
}

ALL_RECOGNIZED="yes"
for token in $VALID_STATUSES; do
  if [ "$(recognize_status "$token")" != "recognized" ]; then
    ALL_RECOGNIZED="no ($token)"
  fi
done
assert_eq "guard recognizes every VALID_STATUSES token as a status" "$ALL_RECOGNIZED" "yes"

assert_eq "guard does not recognize an off-vocabulary token" \
  "$(recognize_status "FROBNICATED")" "unrecognized"

# ---------------------------------------------------------------------------
# Tests 78-85: group/feature granularity — resolve_review_unit() end-to-end
# through task-state-guard.sh (MF-013, TASK-001). Both evidence gates this
# script owns (the IMPLEMENTED/BLOCKED -> IN_REVIEW dir-check, and the
# IN_REVIEW -> DONE review-evidence check) must resolve reviews/GROUP-<n> or
# reviews/FEATURE-<feat_id> instead of reviews/<task_id> once granularity is
# configured — proving the corrupted-state regression MF-013 names (a
# legitimately group/feature-reviewed task getting hard-blocked by a
# task-id-only directory check) no longer happens.
# ---------------------------------------------------------------------------

# Test 78: group mode — IMPLEMENTED -> IN_REVIEW blocked without reviews/GROUP-1
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_task_file "TASK-001" "IMPLEMENTED"   # create_task_file sets - **Group**: 1
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "group mode: IN_REVIEW without reviews/GROUP-1 blocked" "$GUARD_EC" 2
assert_contains "group mode: IN_REVIEW without reviews/GROUP-1 message" "$GUARD_STDERR" "review directory"
teardown_temp_dir

# Test 79: group mode — IMPLEMENTED -> IN_REVIEW allowed once reviews/GROUP-1 exists
# (reviews/TASK-001 deliberately absent — proves the resolver, not the old path, is used)
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_task_file "TASK-001" "IMPLEMENTED"
mkdir -p "$TEST_DIR/nazgul/reviews/GROUP-1"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "group mode: IN_REVIEW with reviews/GROUP-1 allowed" "$GUARD_EC" 0
teardown_temp_dir

# Test 80: group mode — IN_REVIEW -> DONE with an APPROVED review under
# reviews/GROUP-1 (not reviews/TASK-001) — allowed
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "GROUP-1"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "group mode: DONE with reviews/GROUP-1 evidence allowed" "$GUARD_EC" 0
teardown_temp_dir

# Test 81 (MF-013 core regression): group mode — IN_REVIEW -> DONE blocked when
# the ONLY evidence sits at the old reviews/TASK-001 path, proving the fix
# doesn't silently fall back to task-id-keyed evidence in group mode
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "group mode: task-id-keyed evidence not honored: blocked" "$GUARD_EC" 2
assert_contains "group mode: task-id-keyed evidence not honored: message" "$GUARD_STDERR" "No review directory"
teardown_temp_dir

# Test 82: group mode — a task in a DIFFERENT group's reviews dir does not
# satisfy this task's DONE gate (GROUP-2 evidence does not cover a Group:1 task)
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"   # Group: 1
create_review_dir "GROUP-2"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "group mode: wrong-group evidence not honored: blocked" "$GUARD_EC" 2
teardown_temp_dir

# Test 83: feature mode — IMPLEMENTED -> IN_REVIEW blocked without reviews/FEATURE-<feat_id>
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "feature"' '.feat_id = "FEAT-016"'
create_task_file "TASK-001" "IMPLEMENTED"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "feature mode: IN_REVIEW without reviews/FEATURE-FEAT-016 blocked" "$GUARD_EC" 2
teardown_temp_dir

# Test 84: feature mode — IMPLEMENTED -> IN_REVIEW allowed once reviews/FEATURE-FEAT-016 exists
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "feature"' '.feat_id = "FEAT-016"'
create_task_file "TASK-001" "IMPLEMENTED"
mkdir -p "$TEST_DIR/nazgul/reviews/FEATURE-FEAT-016"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "feature mode: IN_REVIEW with reviews/FEATURE-FEAT-016 allowed" "$GUARD_EC" 0
teardown_temp_dir

# Test 85: feature mode — IN_REVIEW -> DONE with an APPROVED review under
# reviews/FEATURE-<feat_id> — allowed (end-to-end IMPLEMENTED->IN_REVIEW->DONE
# for a feature-reviewed task, the exact path MF-013 names as non-functional)
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "feature"' '.feat_id = "FEAT-016"' \
  '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "FEATURE-FEAT-016"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "feature mode: DONE with reviews/FEATURE-FEAT-016 evidence allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# TASK-009 / LR-001 / ADR-005 Decision 4: receipt-hash content gate,
# end-to-end through the real guard (not just the library — see
# tests/test-review-evidence.sh for the library-level cases). Reproduces the
# FEAT-016/TASK-005 fabrication shape: a persisted reviewer verdict that
# does not match what the reviewer actually returned (or was never
# independently captured at all) must BLOCK the IN_REVIEW->DONE transition,
# not silently pass because the file merely LOOKS like an approved review.
# ---------------------------------------------------------------------------

# Helper: sha256 via the same `printf '%s' ... | sha256sum` pattern
# scripts/lib/review-provenance.sh's _rp_sha256 uses (see that file).
_test_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

# Helper: simulate one full dispatched-reviewer cycle exactly as production
# does it (agents/review-gate.md Step 2 item 4 + scripts/subagent-stop.sh's
# _record_reviewer_receipt) — a receipt for the reviewer's RAW returned
# text, and a persisted file carrying that same text plus one
# orchestrator-inserted review_token line.
# Usage: write_dispatched_review_with_receipt <unit> <reviewer> <verdict> \
#   <narrative> [--no-receipt] [--tamper]
write_dispatched_review_with_receipt() {
  local unit="$1" reviewer="$2" verdict="$3" narrative="$4"
  shift 4
  local no_receipt=false tamper=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-receipt) no_receipt=true ;;
      --tamper) tamper=true ;;
    esac
    shift
  done

  local raw hash persisted_narrative
  raw=$(printf -- '---\nverdict: %s\nconfidence: 90\n---\n%s\n' "$verdict" "$narrative")
  hash=$(_test_sha256 "$raw")

  persisted_narrative="$narrative"
  [ "$tamper" = true ] && persisted_narrative="${narrative} TAMPERED AFTER REVIEW."

  mkdir -p "$TEST_DIR/nazgul/reviews/$unit"
  printf -- '---\nverdict: %s\nconfidence: 90\nreview_token: deadbeefcafef00d\n---\n%s\n' \
    "$verdict" "$persisted_narrative" \
    > "$TEST_DIR/nazgul/reviews/$unit/${reviewer}.md"
  # Real review-gate runs always leave a .dispatch.json too (Step 1.6) —
  # included for fixture realism even though the receipt check itself never
  # reads it.
  jq -cn --arg u "$unit" --arg r "$reviewer" \
    '{unit:$u, token:"deadbeefcafef00d", selected:[$r], skipped:[]}' \
    > "$TEST_DIR/nazgul/reviews/$unit/.dispatch.json"

  if [ "$no_receipt" != true ]; then
    mkdir -p "$TEST_DIR/nazgul/logs"
    jq -cn --arg u "$unit" --arg r "$reviewer" --arg h "$hash" --arg ts "2026-07-23T00:00:00Z" \
      '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' \
      >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
  fi
}

# Test 86 (FEAT-016/TASK-005 reproduction): a persisted APPROVE verdict whose
# body doesn't match its captured receipt — BLOCKED, not silently DONE.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = true'
create_task_file "TASK-001" "IN_REVIEW"
write_dispatched_review_with_receipt "TASK-001" "code-reviewer" "APPROVE" \
  "Looks good. No blocking issues found." --tamper
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "forged verdict content blocks DONE" "$GUARD_EC" 2
teardown_temp_dir

# Test 87 (CORRECTED — see team-lead design-input during review, and
# tests/test-review-evidence.sh's Test 49/56 for the library-level version
# of this same correction): a persisted APPROVE verdict with NO receipt
# anywhere for its unit is NOT blocked by itself — confirmed live in this
# repo's own main worktree: nazgul/logs/review-receipts.jsonl does not
# exist anywhere on disk despite 6 already-DONE tasks with full review
# boards, and stop-hook.sh's DONE-gate reconciliation pass re-validates
# EVERY already-DONE task on EVERY iteration. Blocking here unconditionally
# would retroactively reset all 6 of those (and every pre-TASK-002 board in
# every other Nazgul project) the moment this code lands.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = true'
create_task_file "TASK-001" "IN_REVIEW"
write_dispatched_review_with_receipt "TASK-001" "code-reviewer" "APPROVE" \
  "Looks good. No blocking issues found." --no-receipt
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "no receipts anywhere for unit: DONE allowed (capture never active)" "$GUARD_EC" 0
teardown_temp_dir

# Test 87b (the real FEAT-016/TASK-005 receipt-less reproduction, corrected
# shape): a SIBLING reviewer's receipt on record for the SAME unit proves
# capture WAS active for this board — THIS reviewer's own receipt still
# being absent is the targeted-suppression shape and IS blocked.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer", "qa-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = true'
create_task_file "TASK-001" "IN_REVIEW"
write_dispatched_review_with_receipt "TASK-001" "code-reviewer" "APPROVE" \
  "Looks good, ship it."
write_dispatched_review_with_receipt "TASK-001" "qa-reviewer" "APPROVE" \
  "Test coverage is solid." --no-receipt
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "sibling receipt exists, this one missing: DONE blocked" "$GUARD_EC" 2
teardown_temp_dir

# Test 88: matching receipt (legitimate, unforged review) — DONE allowed.
# Proves the gate isn't just failing every APPROVE verdict outright.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = true'
create_task_file "TASK-001" "IN_REVIEW"
write_dispatched_review_with_receipt "TASK-001" "code-reviewer" "APPROVE" \
  "Looks good. No blocking issues found."
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "matching receipt: DONE allowed" "$GUARD_EC" 0
teardown_temp_dir

# Test 89: review_gate.receipt_hash_enforcement: false — the kill switch
# reverts to pre-gate behavior; a tampered, receipt-less body no longer
# blocks DONE.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = false'
create_task_file "TASK-001" "IN_REVIEW"
write_dispatched_review_with_receipt "TASK-001" "code-reviewer" "APPROVE" \
  "Looks good. No blocking issues found." --tamper --no-receipt
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "enforcement off: DONE allowed despite tampered body" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Verdict-only resolution tolerance, end-to-end through the real guard
# (library-level cases: tests/test-review-evidence.sh Tests 57-59). review-
# gate legitimately overwrites ONLY the top-level `verdict:` field after
# Step 3/3.6/3.75 resolution — confirmed against the REAL 2026-07-23
# TASK-002 board's persisted files
# (nazgul/reviews/TASK-002/{architect,code,security}-reviewer.md in the main
# worktree). The decisive check per the team-lead's design input: would this
# design have caught a gate inverting CHANGES_REQUESTED->APPROVE with a
# REWRITTEN narrative? Test 91 answers that directly through the real guard.
# ---------------------------------------------------------------------------

# Helper: simulate a Step 3/3.6/3.75 VERDICT-ONLY resolution — reviewer
# originally returns <orig_verdict>/<orig_confidence> + <body>; review-gate
# persists <resolved_verdict> with a disclosed "review-gate resolution note"
# inserted, body preserved verbatim below it (mirrors
# tests/test-review-evidence.sh's write_resolved_review).
# Usage: write_resolved_review <unit> <reviewer> <orig_verdict> \
#   <orig_confidence> <resolved_verdict> <body> [--no-note] [--tamper-body]
write_resolved_review() {
  local unit="$1" reviewer="$2" orig_verdict="$3" orig_confidence="$4" resolved_verdict="$5" body="$6"
  shift 6
  local no_note=false tamper_body=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-note) no_note=true ;;
      --tamper-body) tamper_body=true ;;
    esac
    shift
  done

  local raw hash
  raw=$(printf -- '---\nverdict: %s\nconfidence: %s\n---\n\n%s\n' "$orig_verdict" "$orig_confidence" "$body")
  hash=$(_test_sha256 "$raw")

  mkdir -p "$TEST_DIR/nazgul/reviews/$unit"
  local persisted_body="$body"
  [ "$tamper_body" = true ] && persisted_body="${body} TAMPERED AFTER RESOLUTION."

  if [ "$no_note" = true ]; then
    printf -- '---\nverdict: %s\nconfidence: %s\nreview_token: deadbeefcafef00d\n---\n\n%s\n' \
      "$resolved_verdict" "$orig_confidence" "$persisted_body" \
      > "$TEST_DIR/nazgul/reviews/$unit/${reviewer}.md"
  else
    printf -- '---\nverdict: %s\nconfidence: %s\nreview_token: deadbeefcafef00d\n---\n\n> **review-gate resolution note:** the original verdict %s was resolved to %s per Step 3.6 — findings preserved verbatim below.\n\n%s\n' \
      "$resolved_verdict" "$orig_confidence" "$orig_verdict" "$resolved_verdict" "$persisted_body" \
      > "$TEST_DIR/nazgul/reviews/$unit/${reviewer}.md"
  fi

  mkdir -p "$TEST_DIR/nazgul/logs"
  jq -cn --arg u "$unit" --arg r "$reviewer" --arg h "$hash" --arg ts "2026-07-23T00:00:00Z" \
    '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' \
    >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
}

# Test 90 (real TASK-002-board reproduction): a disclosed, note-backed
# verdict flip (CHANGES_REQUESTED -> APPROVE, findings preserved verbatim
# below the note) is allowed to reach DONE.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["security-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = true'
create_task_file "TASK-001" "IN_REVIEW"
write_resolved_review "TASK-001" "security-reviewer" "CHANGES_REQUESTED" "75" "APPROVE" \
  "## Scope of review

Read the diff. Found one HIGH finding, downgraded per Step 3.6 adversarial cross-check."
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "disclosed verdict-only flip: DONE allowed" "$GUARD_EC" 0
teardown_temp_dir

# Test 91 (THE decisive check): a resolution note is present and well-formed
# (disclosed), but the body below it was ALSO altered from what the
# reviewer actually returned — still BLOCKED. A disclosed note excuses only
# the verdict field, never content tampering — this is the exact FEAT-016/
# TASK-005 shape (gate inverts CHANGES_REQUESTED->APPROVE with a rewritten
# narrative), now dressed up with a note to see if that alone gets it past
# the gate. It must not.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["security-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = true'
create_task_file "TASK-001" "IN_REVIEW"
write_resolved_review "TASK-001" "security-reviewer" "CHANGES_REQUESTED" "75" "APPROVE" \
  "## Scope of review

Read the diff. Found one HIGH finding, downgraded per Step 3.6 adversarial cross-check." \
  --tamper-body
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "note present but body tampered: DONE blocked" "$GUARD_EC" 2
teardown_temp_dir

# Test 92: an UNDISCLOSED verdict flip (verdict changed, body untouched, but
# NO resolution note) is blocked — candidate (ii)'s DETERMINISTIC reversal
# in _re_receipt_matches requires the exact canonical marker; without a note
# it is never attempted, so a bare undisclosed flip can never pass.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["security-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = true'
create_task_file "TASK-001" "IN_REVIEW"
write_resolved_review "TASK-001" "security-reviewer" "CHANGES_REQUESTED" "75" "APPROVE" \
  "## Scope of review

Read the diff. Found one HIGH finding, downgraded per Step 3.6 adversarial cross-check." \
  --no-note
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "undisclosed flip, no note: DONE blocked" "$GUARD_EC" 2
teardown_temp_dir

# Test 93 (round-4: the real, untruncated nazgul/reviews/TASK-002/
# security-reviewer.md, both top-of-file AND trailing orchestrator notes
# present — architect round-2's exact finding, driven end-to-end through the
# real guard). Confirms DONE is actually reachable for a real legitimately-
# resolved board, not just a library-level check.
setup_temp_dir
setup_nazgul_dir
create_config '.agents.reviewers = ["security-reviewer"]' '.review_gate.granularity = "task"' \
  '.review_gate.receipt_hash_enforcement = true'
create_task_file "TASK-001" "IN_REVIEW"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" << 'REALFIXTURE'
---
verdict: APPROVE
confidence: 75
review_token: a32840175b088c96
---

> **review-gate resolution note:** `_has_approved_verdict` (`scripts/lib/review-evidence.sh`) is
> VERDICT-ONLY by design — its own header comment states "confidence is handled by the review-gate
> agent," i.e. review-gate resolves confidence-threshold/Step 3.6 outcomes into the persisted
> `verdict:` field before the mechanical gate reads it. This reviewer's own self-authored header (as
> originally returned) was `verdict: CHANGES_REQUESTED, confidence: 75`. Its one blocking finding
> (unguarded jq under `set -e`, HIGH, confidence 82) was cross-checked per Step 3.6 and REFUTEd at
> confidence 90 (see the trailing orchestrator note below and
> `nazgul/reviews/TASK-002/adversarial/security-jq-guard.md`) — downgraded to a non-blocking CONCERN.
> With zero blocking findings remaining, this review resolves to APPROVED for gating purposes. The
> `verdict:` field above has been updated from the reviewer's original `CHANGES_REQUESTED` to
> `APPROVE` to reflect that resolution — **every finding and all narrative content below is preserved
> 100% verbatim, unedited, exactly as the reviewer returned it.** Full tally:
> `nazgul/reviews/TASK-002/consolidated-feedback.md`.

## Scope of review

Read `nazgul/reviews/TASK-002/diff.patch`, the task manifest, the full current `scripts/subagent-stop.sh`.

### Finding: Unguarded `jq` command substitutions
- **Severity**: HIGH
- **Confidence**: 82
- **Verdict**: REJECT (downgraded to CONCERN per the Step 3.6 note above)

## Final Verdict

CHANGES_REQUESTED. Resolved per Step 3.6 above.

---
**Orchestrator note (review-gate Step 3.6 — adversarial cross-check, resolved):** the sole HIGH-severity REJECT finding above was cross-checked and REFUTEd at confidence 90. Per Step 3.6 resolution rules, this finding is DOWNGRADED from blocking REJECT to a non-blocking CONCERN.
REALFIXTURE
# Self-consistent ground-truth receipt (methodology disclosed in
# scripts/lib/review-evidence.sh _re_receipt_matches header and the TASK-009
# Implementation Log: derived from this same reconstruction, no
# independently-captured ground truth exists in this repo).
source "$REPO_ROOT/scripts/lib/review-evidence.sh"
REAL_TOP=$(_re_reconstruct_pretoken_text "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" --revert-resolution)
REAL_BOTH=$(printf '%s\n' "$REAL_TOP" | _re_strip_trailing_orchestrator_note)
REAL_HASH=$(printf '%s' "$REAL_BOTH" | _rp_sha256)
mkdir -p "$TEST_DIR/nazgul/logs"
jq -cn --arg u "TASK-001" --arg r "security-reviewer" --arg h "$REAL_HASH" --arg ts "2026-07-23T00:00:00Z" \
  '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
TASK_PATH="$TEST_DIR/nazgul/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "DONE")
run_guard "$input"
assert_exit_code "real TASK-002-shape board (both notes): DONE allowed" "$GUARD_EC" 0
teardown_temp_dir

report_results
