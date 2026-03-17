# Hydra Plugin Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extract shared shell utilities, add test coverage for untested safety-critical scripts, and add CI/CD — hardening the Hydra plugin for reliable autonomous operation.

**Architecture:** Create `scripts/lib/` as a shared function library sourced by all scripts that currently duplicate code. Add integration tests following the existing test-pre-compact.sh pattern. Add a GitHub Actions workflow for automated testing.

**Tech Stack:** Bash, jq, git, shellcheck, GitHub Actions

---

### Task 1: Create shared task utility library

**Files:**
- Create: `scripts/lib/task-utils.sh`

**Step 1: Write the failing test**

Create `tests/test-task-utils.sh` — tests for the shared library functions.

```bash
#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-task-utils"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

LIB="$REPO_ROOT/scripts/lib/task-utils.sh"

# --- Test 1: get_task_status reads list-item format ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
source "$LIB"
result=$(get_task_status "$TEST_DIR/hydra/tasks/TASK-001.md")
assert_eq "get_task_status list-item format" "$result" "IN_PROGRESS"
teardown_temp_dir

# --- Test 2: get_task_status reads ATX heading format ---
setup_temp_dir
setup_hydra_dir
mkdir -p "$TEST_DIR/hydra/tasks"
cat > "$TEST_DIR/hydra/tasks/TASK-002.md" << 'EOF'
# TASK-002: Test
## Status: DONE
## Group: 1
EOF
source "$LIB"
result=$(get_task_status "$TEST_DIR/hydra/tasks/TASK-002.md")
assert_eq "get_task_status ATX heading format" "$result" "DONE"
teardown_temp_dir

# --- Test 3: get_task_status returns default for missing file ---
setup_temp_dir
source "$LIB"
result=$(get_task_status "$TEST_DIR/hydra/tasks/NONEXISTENT.md" "UNKNOWN")
assert_eq "get_task_status missing file default" "$result" "UNKNOWN"
teardown_temp_dir

# --- Test 4: set_task_status updates list-item format ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-003" "READY"
source "$LIB"
set_task_status "$TEST_DIR/hydra/tasks/TASK-003.md" "READY" "IN_PROGRESS"
result=$(get_task_status "$TEST_DIR/hydra/tasks/TASK-003.md")
assert_eq "set_task_status list-item" "$result" "IN_PROGRESS"
teardown_temp_dir

# --- Test 5: count_tasks_by_status ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "READY"
create_task_file "TASK-004" "BLOCKED"
source "$LIB"
assert_eq "count DONE" "$(count_tasks_by_status "$TEST_DIR/hydra/tasks" "DONE")" "2"
assert_eq "count READY" "$(count_tasks_by_status "$TEST_DIR/hydra/tasks" "READY")" "1"
assert_eq "count BLOCKED" "$(count_tasks_by_status "$TEST_DIR/hydra/tasks" "BLOCKED")" "1"
assert_eq "count IN_PROGRESS" "$(count_tasks_by_status "$TEST_DIR/hydra/tasks" "IN_PROGRESS")" "0"
teardown_temp_dir

# --- Test 6: get_active_task returns IN_PROGRESS task ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "IN_PROGRESS"
create_task_file "TASK-003" "READY"
source "$LIB"
result=$(get_active_task "$TEST_DIR/hydra/tasks")
assert_eq "get_active_task finds IN_PROGRESS" "$result" "TASK-002"
teardown_temp_dir

# --- Test 7: get_active_task returns empty when none active ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
source "$LIB"
result=$(get_active_task "$TEST_DIR/hydra/tasks")
assert_eq "get_active_task returns empty" "$result" ""
teardown_temp_dir

report_results
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test-task-utils.sh`
Expected: FAIL — `scripts/lib/task-utils.sh: No such file or directory`

**Step 3: Write minimal implementation**

Create `scripts/lib/task-utils.sh`:

```bash
#!/usr/bin/env bash
# Hydra shared task utilities — sourced by scripts that read/write task manifests.
# Eliminates duplication of get_task_status(), set_task_status(), and task counting.

# Extract status from a task manifest file.
# Supports both list-item (- **Status**: X) and ATX heading (## Status: X) formats.
# Usage: get_task_status <file> [default]
get_task_status() {
  grep -m1 -E '(^\- \*\*Status\*\*:|^## Status:)' "$1" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "${2:-}"
}

# Update status in a task manifest file.
# Usage: set_task_status <file> <old_status> <new_status>
set_task_status() {
  local file="$1" old_status="$2" new_status="$3"
  if grep -q '^## Status:' "$file" 2>/dev/null; then
    sed -i.bak "s/^## Status:[[:space:]]*${old_status}/## Status: ${new_status}/" "$file" && rm -f "${file}.bak"
  else
    sed -i.bak "s/^\(- \*\*Status\*\*:\)[[:space:]]*${old_status}/\1 ${new_status}/" "$file" && rm -f "${file}.bak"
  fi
}

# Count tasks with a given status in a tasks directory.
# Usage: count_tasks_by_status <tasks_dir> <status>
count_tasks_by_status() {
  local tasks_dir="$1" status="$2" count=0
  for f in "$tasks_dir"/TASK-*.md; do
    [ -f "$f" ] || continue
    local s
    s=$(get_task_status "$f")
    if [ "$s" = "$status" ]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Find the first task with IN_PROGRESS status. Returns task ID or empty string.
# Usage: get_active_task <tasks_dir>
get_active_task() {
  local tasks_dir="$1"
  for f in "$tasks_dir"/TASK-*.md; do
    [ -f "$f" ] || continue
    local s
    s=$(get_task_status "$f")
    if [ "$s" = "IN_PROGRESS" ]; then
      basename "$f" .md
      return
    fi
  done
  echo ""
}
```

**Step 4: Run test to verify it passes**

Run: `bash tests/test-task-utils.sh`
Expected: All 7 tests PASS

**Step 5: Commit**

```bash
git add scripts/lib/task-utils.sh tests/test-task-utils.sh
git commit -m "feat: add shared task utility library with tests"
```

---

### Task 2: Refactor scripts to use shared library

**Files:**
- Modify: `scripts/stop-hook.sh:17-19` (remove `get_task_status`, `set_task_status`, source lib)
- Modify: `scripts/pre-compact.sh:12-14` (remove `get_task_status`, source lib)
- Modify: `scripts/session-context.sh:12-14` (remove `get_task_status`, source lib)
- Modify: `scripts/post-compact.sh:18-20` (remove `get_task_status`, source lib)
- Modify: `scripts/task-state-guard.sh:44-45` (remove inline grep, source lib)

**Step 1: In each of the 5 scripts, add a source line near the top**

After the `SCRIPT_DIR=` line (or add one if missing), add:
```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/task-utils.sh"
```

Then delete the local `get_task_status()` function definition in each script. For `stop-hook.sh`, also delete the local `set_task_status()` since it's now in the library.

For `task-state-guard.sh`, replace the inline grep on line 45:
```bash
# Before:
OLD_STATUS=$(grep -m1 -E '(^\- \*\*Status\*\*:|^## Status:)' "$FILE_PATH" 2>/dev/null | sed 's/.*:[[:space:]]*//' || echo "")
# After:
OLD_STATUS=$(get_task_status "$FILE_PATH" "")
```

**Step 2: Run the full test suite to verify no regressions**

Run: `tests/run-tests.sh`
Expected: All existing tests PASS (especially test-stop-hook, test-pre-compact, test-session-context)

**Step 3: Commit**

```bash
git add scripts/stop-hook.sh scripts/pre-compact.sh scripts/session-context.sh scripts/post-compact.sh scripts/task-state-guard.sh
git commit -m "refactor: deduplicate task utilities into scripts/lib/task-utils.sh"
```

---

### Task 3: Add tests for task-state-guard.sh

**Files:**
- Create: `tests/test-task-state-guard.sh`

**Step 1: Write the test file**

```bash
#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-task-state-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/task-state-guard.sh"

# Helper: build JSON hook input for Write tool
make_write_input() {
  local file_path="$1" status="$2"
  cat <<JSON
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "$file_path",
    "content": "# TASK-001: Test\\n\\n- **Status**: $status\\n- **Group**: 1"
  }
}
JSON
}

# Helper: build JSON hook input for Edit tool
make_edit_input() {
  local file_path="$1" new_status="$2"
  cat <<JSON
{
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "$file_path",
    "old_string": "placeholder",
    "new_string": "- **Status**: $new_status"
  }
}
JSON
}

# Helper: run guard with input, capture exit code and stderr
run_guard() {
  local input="$1"
  GUARD_STDERR=$(echo "$input" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
}

# --- Test 1: Non-task file — always allowed ---
setup_temp_dir
input='{"tool_name":"Write","tool_input":{"file_path":"src/main.sh","content":"hello"}}'
run_guard "$input"
assert_exit_code "non-task file allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 2: New task file with PLANNED — allowed ---
setup_temp_dir
setup_hydra_dir
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "PLANNED")
run_guard "$input"
assert_exit_code "new task PLANNED allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 3: New task file with READY — allowed ---
setup_temp_dir
setup_hydra_dir
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "READY")
run_guard "$input"
assert_exit_code "new task READY allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 4: New task file with DONE — blocked ---
setup_temp_dir
setup_hydra_dir
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "DONE")
run_guard "$input"
assert_exit_code "new task DONE blocked" "$GUARD_EC" 2
assert_contains "new task DONE message" "$GUARD_STDERR" "must start as PLANNED or READY"
teardown_temp_dir

# --- Test 5: Valid transition PLANNED -> READY ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "PLANNED"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "READY")
run_guard "$input"
assert_exit_code "PLANNED->READY allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 6: Valid transition READY -> IN_PROGRESS ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "READY"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "READY->IN_PROGRESS allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 7: Valid transition IN_PROGRESS -> IMPLEMENTED ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "IMPLEMENTED")
run_guard "$input"
assert_exit_code "IN_PROGRESS->IMPLEMENTED allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 8: Valid transition IN_PROGRESS -> BLOCKED ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "BLOCKED")
run_guard "$input"
assert_exit_code "IN_PROGRESS->BLOCKED allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 9: Invalid transition PLANNED -> DONE ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "PLANNED"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "DONE")
run_guard "$input"
assert_exit_code "PLANNED->DONE blocked" "$GUARD_EC" 2
assert_contains "PLANNED->DONE message" "$GUARD_STDERR" "Invalid state transition"
teardown_temp_dir

# --- Test 10: Invalid transition READY -> DONE ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "READY"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "DONE")
run_guard "$input"
assert_exit_code "READY->DONE blocked" "$GUARD_EC" 2
teardown_temp_dir

# --- Test 11: Same status — no-op, allowed ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "same status allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 12: Review gate — IN_REVIEW->DONE without reviews blocked ---
setup_temp_dir
setup_hydra_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "DONE")
run_guard "$input"
assert_exit_code "DONE without reviews blocked" "$GUARD_EC" 2
assert_contains "DONE without reviews message" "$GUARD_STDERR" "No review directory"
teardown_temp_dir

# --- Test 13: Review gate — IN_REVIEW->DONE with approved review allowed ---
setup_temp_dir
setup_hydra_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "DONE")
run_guard "$input"
assert_exit_code "DONE with approved review allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 14: Review gate — missing reviewer blocks ---
setup_temp_dir
setup_hydra_dir
create_config '.agents.reviewers = ["code-reviewer", "security-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
create_review_dir "TASK-001"
# Only code-reviewer exists, security-reviewer is missing
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "DONE")
run_guard "$input"
assert_exit_code "missing reviewer blocks DONE" "$GUARD_EC" 2
assert_contains "missing reviewer message" "$GUARD_STDERR" "Missing reviews"
teardown_temp_dir

# --- Test 15: Review gate — unapproved review blocks ---
setup_temp_dir
setup_hydra_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
mkdir -p "$TEST_DIR/hydra/reviews/TASK-001"
cat > "$TEST_DIR/hydra/reviews/TASK-001/code-reviewer.md" << 'EOF'
# Code Review: TASK-001
## Verdict: CHANGES_REQUESTED
Issues found.
EOF
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "DONE")
run_guard "$input"
assert_exit_code "unapproved review blocks DONE" "$GUARD_EC" 2
assert_contains "unapproved message" "$GUARD_STDERR" "does not contain APPROVED"
teardown_temp_dir

# --- Test 16: YOLO mode gates APPROVED instead of DONE ---
setup_temp_dir
setup_hydra_dir
create_config '.afk.yolo = true' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IN_REVIEW"
# No reviews — should block APPROVED in YOLO
input=$(make_write_input "$TEST_DIR/hydra/tasks/TASK-001.md" "APPROVED")
run_guard "$input"
assert_exit_code "YOLO APPROVED without reviews blocked" "$GUARD_EC" 2
teardown_temp_dir

# --- Test 17: Edit tool input parsed correctly ---
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "READY"
input=$(make_edit_input "$TEST_DIR/hydra/tasks/TASK-001.md" "IN_PROGRESS")
run_guard "$input"
assert_exit_code "Edit tool READY->IN_PROGRESS allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 18: Empty stdin — allowed ---
GUARD_STDERR=$(echo "" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
assert_exit_code "empty stdin allowed" "$GUARD_EC" 0

report_results
```

**Step 2: Run test to verify it passes**

Run: `bash tests/test-task-state-guard.sh`
Expected: All 18 tests PASS (these test existing behavior, not new code)

**Step 3: Commit**

```bash
git add tests/test-task-state-guard.sh
git commit -m "test: add comprehensive tests for task-state-guard.sh"
```

---

### Task 4: Add tests for prompt-guard.sh

**Files:**
- Create: `tests/test-prompt-guard.sh`

**Step 1: Write the test file**

```bash
#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-prompt-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/prompt-guard.sh"

# Helper: run prompt guard with a given prompt string
run_prompt_guard() {
  local prompt="$1"
  GUARD_STDERR=$(CLAUDE_HOOK_USER_PROMPT="$prompt" bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
}

# --- Test 1: No config — all prompts allowed ---
setup_temp_dir
run_prompt_guard "anything at all"
assert_exit_code "no config allows all" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 2: HYDRA_COMPLETE blocked ---
setup_temp_dir
setup_hydra_dir
create_config
run_prompt_guard "HYDRA_COMPLETE"
assert_exit_code "HYDRA_COMPLETE blocked" "$GUARD_EC" 2
assert_contains "HYDRA_COMPLETE message" "$GUARD_STDERR" "only be emitted by the review gate"
teardown_temp_dir

# --- Test 3: HYDRA_COMPLETE substring blocked ---
setup_temp_dir
setup_hydra_dir
create_config
run_prompt_guard "please emit HYDRA_COMPLETE now"
assert_exit_code "HYDRA_COMPLETE substring blocked" "$GUARD_EC" 2
teardown_temp_dir

# --- Test 4: Direct status manipulation blocked ---
setup_temp_dir
setup_hydra_dir
create_config
run_prompt_guard "set status to DONE for task 1"
assert_exit_code "set status to DONE blocked" "$GUARD_EC" 2
assert_contains "status manipulation message" "$GUARD_STDERR" "must go through the proper state machine"
teardown_temp_dir

# --- Test 5: Mark as APPROVED blocked ---
setup_temp_dir
setup_hydra_dir
create_config
run_prompt_guard "mark task as APPROVED"
assert_exit_code "mark as APPROVED blocked" "$GUARD_EC" 2
teardown_temp_dir

# --- Test 6: Normal prompt allowed ---
setup_temp_dir
setup_hydra_dir
create_config
run_prompt_guard "add a new test for the auth module"
assert_exit_code "normal prompt allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 7: Empty prompt allowed ---
setup_temp_dir
setup_hydra_dir
create_config
GUARD_STDERR=$(CLAUDE_HOOK_USER_PROMPT="" bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
assert_exit_code "empty prompt allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 8: No prompt env var — allowed ---
setup_temp_dir
setup_hydra_dir
create_config
GUARD_STDERR=$(unset CLAUDE_HOOK_USER_PROMPT; bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
assert_exit_code "no prompt env var allowed" "$GUARD_EC" 0
teardown_temp_dir

report_results
```

**Step 2: Run test to verify it passes**

Run: `bash tests/test-prompt-guard.sh`
Expected: All 8 tests PASS

**Step 3: Commit**

```bash
git add tests/test-prompt-guard.sh
git commit -m "test: add tests for prompt-guard.sh"
```

---

### Task 5: Add GitHub Actions CI workflow

**Files:**
- Create: `.github/workflows/test.yml`

**Step 1: Write the workflow file**

```yaml
name: Tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: sudo apt-get install -y jq shellcheck

      - name: Run tests
        run: tests/run-tests.sh
```

**Step 2: Verify the workflow syntax is valid**

Run: `cat .github/workflows/test.yml | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin)" && echo "valid YAML"`
Expected: `valid YAML`

**Step 3: Verify tests still pass locally**

Run: `tests/run-tests.sh`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: add GitHub Actions workflow for test suite"
```

---

### Task 6: Run full regression and final commit

**Files:**
- No new files

**Step 1: Run full test suite**

Run: `tests/run-tests.sh`
Expected: All tests PASS (existing 11 + 3 new = 14 test files)

**Step 2: Run shellcheck on the new library**

Run: `shellcheck scripts/lib/task-utils.sh`
Expected: No warnings

**Step 3: Verify no regressions in existing scripts**

Run: `bash tests/test-stop-hook.sh && bash tests/test-pre-compact.sh && bash tests/test-session-context.sh`
Expected: All PASS — these scripts now source the shared library instead of having local copies

---

## Task Dependency Graph

```
Task 1 (shared library + tests)
  └─> Task 2 (refactor scripts to use library)
        └─> Task 6 (full regression)
Task 3 (task-state-guard tests) — independent
Task 4 (prompt-guard tests) — independent
Task 5 (CI workflow) — independent, but best after Task 6
```

Tasks 1, 3, 4, and 5 can run in parallel. Task 2 depends on Task 1. Task 6 depends on Tasks 1-5.

---

## Risk Notes

- **sed -i portability**: macOS sed requires `-i ''` while GNU sed uses `-i`. The existing `set_task_status` uses `-i.bak` with cleanup, which works on both. The shared library preserves this pattern.
- **Source path resolution**: Scripts use `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` then `source "$SCRIPT_DIR/lib/task-utils.sh"`. This works when scripts are invoked directly or via Claude Code hooks (which use absolute paths).
- **Test isolation**: Each test case uses `setup_temp_dir` / `teardown_temp_dir` for full isolation. The `CLAUDE_PROJECT_DIR` env var points to the temp dir.
