# Evidence-Gated Task State Transitions — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add structural enforcement to `task-state-guard.sh` so agents cannot batch-walk task states without real work and real reviews.

**Architecture:** Two layers added to the existing PreToolUse hook. Layer 1 requires evidence (commit SHA, review directory) for specific transitions. Layer 2 blocks source file edits when no task is IN_PROGRESS. All changes extend `scripts/task-state-guard.sh` with corresponding tests.

**Tech Stack:** Bash (POSIX-safe), jq, existing test framework (`tests/lib/assertions.sh`, `tests/lib/setup.sh`)

---

### Task 1: Add test helper for task files with commit SHAs

**Files:**
- Modify: `tests/lib/setup.sh:52-72`

**Step 1: Write the new helper function**

Add `create_task_file_with_commits` to `tests/lib/setup.sh` after the existing `create_task_file` function (after line 72):

```bash
create_task_file_with_commits() {
  # Usage: create_task_file_with_commits TASK-001 IN_PROGRESS "abc1234"
  local id="$1"
  local status="$2"
  local commits="${3:-}"

  cat > "$TEST_DIR/hydra/tasks/${id}.md" << TASK_EOF
# ${id}: Test task

- **Status**: ${status}
- **Depends on**: none
- **Group**: 1
- **Retry count**: 0/3
- **Assigned to**: implementer

## Commits
- ${commits}
TASK_EOF
}
```

**Step 2: Commit**

```bash
git add tests/lib/setup.sh
git commit -m "test: add helper for task files with commit SHAs"
```

---

### Task 2: Write failing tests for Layer 1 — commit SHA evidence gate

**Files:**
- Modify: `tests/test-task-state-guard.sh:276` (before `report_results`)

**Step 1: Write the failing tests**

Add these tests before the `report_results` line at the end of `tests/test-task-state-guard.sh`:

```bash
# ---------------------------------------------------------------------------
# Test 19: IN_PROGRESS -> IMPLEMENTED without commit SHA — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IMPLEMENTED")
run_guard "$input"
assert_exit_code "IMPLEMENTED without commit SHA blocked" "$GUARD_EC" 2
assert_contains "IMPLEMENTED without SHA message" "$GUARD_STDERR" "commit SHA"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 20: IN_PROGRESS -> IMPLEMENTED with commit SHA — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IN_PROGRESS"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
# Build input with commit SHA in content
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- abc1234def')
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
run_guard "$input"
assert_exit_code "IMPLEMENTED with commit SHA allowed" "$GUARD_EC" 0
teardown_temp_dir
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/test-task-state-guard.sh`
Expected: Test 19 fails (currently guard allows IN_PROGRESS->IMPLEMENTED without SHA — exits 0 not 2). Test 20 should pass (valid transition with SHA content).

**Step 3: Commit**

```bash
git add tests/test-task-state-guard.sh
git commit -m "test: add failing tests for commit SHA evidence gate"
```

---

### Task 3: Implement Layer 1a — commit SHA evidence check

**Files:**
- Modify: `scripts/task-state-guard.sh:88-98` (between `valid_transition` block and review gate section)

**Step 1: Add the evidence check**

Insert this block after the `valid_transition` check (after line 98, before line 100 `# --- ENFORCE REVIEW GATE`):

```bash
# --- ENFORCE EVIDENCE GATES ---
# IN_PROGRESS -> IMPLEMENTED requires a commit SHA in the manifest content
if [ "$OLD_STATUS" = "IN_PROGRESS" ] && [ "$NEW_STATUS" = "IMPLEMENTED" ]; then
  if ! echo "$NEW_CONTENT" | grep -qE '[0-9a-f]{7,40}'; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot mark IMPLEMENTED without a commit SHA" >&2
    echo "Add a ## Commits section with at least one commit hash to the task manifest." >&2
    echo "If you implemented the work, you should have committed it." >&2
    exit 2
  fi
fi
```

**Step 2: Run tests to verify they pass**

Run: `bash tests/test-task-state-guard.sh`
Expected: All 20 tests pass. Test 19 now correctly blocked. Test 20 passes with SHA present.

**Important:** Verify that existing Test 7 (IN_PROGRESS -> IMPLEMENTED) now fails, because `make_write_input` doesn't include a SHA. If it does fail, update it:

The existing `make_write_input` helper produces content without a SHA. Test 7 uses this for IN_PROGRESS->IMPLEMENTED and currently expects exit 0. After implementing the evidence gate, Test 7 will fail. **Fix Test 7** by updating it to use a content string that includes a commit SHA:

In Test 7 (around line 115-123), replace:
```bash
input=$(make_write_input "$TASK_PATH" "IMPLEMENTED")
```
with:
```bash
content=$(printf '# TASK-001: Test\n\n- **Status**: IMPLEMENTED\n- **Group**: 1\n\n## Commits\n- abc1234def')
input=$(jq -n --arg fp "$TASK_PATH" --arg content "$content" \
  '{"tool_name":"Write","tool_input":{"file_path":$fp,"content":$content}}')
```

**Step 3: Run all tests again**

Run: `bash tests/test-task-state-guard.sh`
Expected: All 20 tests pass.

**Step 4: Commit**

```bash
git add scripts/task-state-guard.sh tests/test-task-state-guard.sh
git commit -m "feat: evidence gate — require commit SHA for IMPLEMENTED transition"
```

---

### Task 4: Write failing tests for Layer 1b — review directory evidence gate

**Files:**
- Modify: `tests/test-task-state-guard.sh` (before `report_results`)

**Step 1: Write the failing tests**

```bash
# ---------------------------------------------------------------------------
# Test 21: IMPLEMENTED -> IN_REVIEW without review directory — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IMPLEMENTED"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "IN_REVIEW without review dir blocked" "$GUARD_EC" 2
assert_contains "IN_REVIEW without review dir message" "$GUARD_STDERR" "review directory"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 22: IMPLEMENTED -> IN_REVIEW with review directory — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_task_file "TASK-001" "IMPLEMENTED"
mkdir -p "$TEST_DIR/hydra/reviews/TASK-001"
TASK_PATH="$TEST_DIR/hydra/tasks/TASK-001.md"
input=$(make_write_input "$TASK_PATH" "IN_REVIEW")
run_guard "$input"
assert_exit_code "IN_REVIEW with review dir allowed" "$GUARD_EC" 0
teardown_temp_dir
```

**Step 2: Run tests to verify Test 21 fails**

Run: `bash tests/test-task-state-guard.sh`
Expected: Test 21 fails (guard currently allows IMPLEMENTED->IN_REVIEW without directory). Test 22 passes.

**Step 3: Commit**

```bash
git add tests/test-task-state-guard.sh
git commit -m "test: add failing tests for review directory evidence gate"
```

---

### Task 5: Implement Layer 1b — review directory evidence check

**Files:**
- Modify: `scripts/task-state-guard.sh` (add after the commit SHA check, before the review gate section)

**Step 1: Add the review directory check**

Add this block right after the commit SHA evidence gate:

```bash
# IMPLEMENTED -> IN_REVIEW requires review directory to exist
if [ "$OLD_STATUS" = "IMPLEMENTED" ] && [ "$NEW_STATUS" = "IN_REVIEW" ]; then
  TASK_ID_CHECK=$(basename "$FILE_PATH" .md)
  HYDRA_DIR_CHECK=$(dirname "$(dirname "$FILE_PATH")")
  REVIEW_DIR_CHECK="$HYDRA_DIR_CHECK/reviews/$TASK_ID_CHECK"
  if [ ! -d "$REVIEW_DIR_CHECK" ]; then
    echo "HYDRA STATE GUARD: BLOCKED — Cannot move to IN_REVIEW without a review directory" >&2
    echo "Expected: ${REVIEW_DIR_CHECK}/" >&2
    echo "The review-gate agent creates this directory when it starts reviewing." >&2
    exit 2
  fi
fi
```

**Step 2: Run tests to verify they pass**

Run: `bash tests/test-task-state-guard.sh`
Expected: All 22 tests pass.

**Step 3: Commit**

```bash
git add scripts/task-state-guard.sh tests/test-task-state-guard.sh
git commit -m "feat: evidence gate — require review directory for IN_REVIEW transition"
```

---

### Task 6: Write failing tests for Layer 2 — active task requirement

**Files:**
- Modify: `tests/test-task-state-guard.sh` (before `report_results`)

**Step 1: Write the failing tests**

```bash
# ---------------------------------------------------------------------------
# Test 23: Source file edit with no IN_PROGRESS task — blocked
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "READY"
input=$(jq -n '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/src/main.ts","content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit without active task blocked" "$GUARD_EC" 2
assert_contains "source edit blocked message" "$GUARD_STDERR" "No task is IN_PROGRESS"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 24: Source file edit with an IN_PROGRESS task — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "IN_PROGRESS"
input=$(jq -n '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/src/main.ts","content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit with active task allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 25: Hydra file edit with no IN_PROGRESS task — always allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.guards.requireActiveTask = true'
create_task_file "TASK-001" "READY"
input=$(jq -n '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/hydra/plan.md","content":"# Plan"}}')
run_guard "$input"
assert_exit_code "hydra file edit always allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 26: Source file edit with no hydra/tasks/ dir — allowed (not initialized)
# ---------------------------------------------------------------------------
setup_temp_dir
# No setup_hydra_dir — no hydra/ directory at all
input=$(jq -n '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/src/main.ts","content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit without hydra dir allowed" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Test 27: Source file edit with guards.requireActiveTask=false — allowed
# ---------------------------------------------------------------------------
setup_temp_dir
setup_hydra_dir
create_config '.guards.requireActiveTask = false'
create_task_file "TASK-001" "READY"
input=$(jq -n '{"tool_name":"Write","tool_input":{"file_path":"'"$TEST_DIR"'/src/main.ts","content":"console.log(1)"}}')
run_guard "$input"
assert_exit_code "source edit with guard disabled allowed" "$GUARD_EC" 0
teardown_temp_dir
```

**Step 2: Run tests to verify Tests 23 fails**

Run: `bash tests/test-task-state-guard.sh`
Expected: Test 23 fails (guard currently allows all non-task files through). Tests 24-27 pass (they expect exit 0).

**Step 3: Commit**

```bash
git add tests/test-task-state-guard.sh
git commit -m "test: add failing tests for active task requirement on source edits"
```

---

### Task 7: Implement Layer 2 — active task requirement for source file edits

**Files:**
- Modify: `scripts/task-state-guard.sh:20-24` (the early exit for non-task files)

**Step 1: Replace the early exit with the active task check**

The current code at lines 21-24 is:
```bash
# Only guard task manifest files (hydra/tasks/TASK-NNN.md)
if ! echo "$FILE_PATH" | grep -qE 'hydra/tasks/TASK-[0-9]+\.md$'; then
  exit 0
fi
```

Replace with:
```bash
# If this is NOT a task manifest, check if it needs the active-task guard
if ! echo "$FILE_PATH" | grep -qE 'hydra/tasks/TASK-[0-9]+\.md$'; then
  # Files inside hydra/ are always allowed (config, plan, reviews, etc.)
  if echo "$FILE_PATH" | grep -qE '/hydra/'; then
    exit 0
  fi

  # Check if active task guard is enabled
  # Find hydra dir by walking up from FILE_PATH or checking known locations
  HYDRA_TASKS_DIR=""
  # Try relative to CLAUDE_PROJECT_DIR (set by Claude Code)
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR/hydra/tasks" ]; then
    HYDRA_TASKS_DIR="$CLAUDE_PROJECT_DIR/hydra/tasks"
    HYDRA_CONFIG="$CLAUDE_PROJECT_DIR/hydra/config.json"
  fi

  # No hydra/tasks dir = not a Hydra project, allow everything
  if [ -z "$HYDRA_TASKS_DIR" ]; then
    exit 0
  fi

  # Check config flag — default to true if not set
  REQUIRE_ACTIVE="true"
  if [ -f "${HYDRA_CONFIG:-}" ]; then
    REQUIRE_ACTIVE=$(jq -r '.guards.requireActiveTask // true' "$HYDRA_CONFIG" 2>/dev/null || echo "true")
  fi
  if [ "$REQUIRE_ACTIVE" != "true" ]; then
    exit 0
  fi

  # Check if any task is IN_PROGRESS
  HAS_ACTIVE=false
  for task_file in "$HYDRA_TASKS_DIR"/TASK-*.md; do
    [ -f "$task_file" ] || continue
    STATUS=$(get_task_status "$task_file" "")
    if [ "$STATUS" = "IN_PROGRESS" ]; then
      HAS_ACTIVE=true
      break
    fi
  done

  if [ "$HAS_ACTIVE" = false ]; then
    echo "HYDRA STATE GUARD: BLOCKED — No task is IN_PROGRESS" >&2
    echo "Cannot edit source files without an active task." >&2
    echo "Transition a task to IN_PROGRESS before editing: $FILE_PATH" >&2
    exit 2
  fi

  # Has active task — allow the source file edit
  exit 0
fi
```

**Step 2: Run tests to verify they pass**

Run: `bash tests/test-task-state-guard.sh`
Expected: All 27 tests pass.

**Important:** Verify Test 1 (non-task file, no hydra dir) still passes — it should because the guard falls through to "no hydra/tasks dir" → exit 0.

**Step 3: Commit**

```bash
git add scripts/task-state-guard.sh tests/test-task-state-guard.sh
git commit -m "feat: block source edits when no task is IN_PROGRESS"
```

---

### Task 8: Update agent instructions

**Files:**
- Modify: `agents/implementer.md:56-59`
- Modify: `templates/CLAUDE.md.template:43-49`

**Step 1: Update implementer.md**

In `agents/implementer.md`, update the Implementation Protocol step 10 (line 59). Change:
```
10. Set status to IMPLEMENTED when all acceptance criteria met, tests pass, lint clean
```
to:
```
10. Set status to IMPLEMENTED when all acceptance criteria met, tests pass, lint clean. **The task manifest MUST contain a `## Commits` section with at least one commit SHA — the state guard will block the transition without it.**
```

**Step 2: Update CLAUDE.md.template**

In `templates/CLAUDE.md.template`, in the "10 Rules" section, after rule 5 about the review gate, add a new line under rule 4 about tests. Actually, update rule 8 (line 48) to mention evidence gates. Change:
```
8. **Update Recovery Pointer on every state change.** This is how you survive compaction.
```
to:
```
8. **Update Recovery Pointer on every state change.** This is how you survive compaction. Evidence gates enforce real work: IMPLEMENTED requires a commit SHA in the manifest, IN_REVIEW requires a review directory, source edits require an IN_PROGRESS task.
```

**Step 3: Commit**

```bash
git add agents/implementer.md templates/CLAUDE.md.template
git commit -m "docs: update agent instructions for evidence-gated transitions"
```

---

### Task 9: Run full test suite and verify

**Files:**
- None (verification only)

**Step 1: Run all tests**

Run: `bash tests/run-tests.sh`
Expected: All test files pass, including the updated `test-task-state-guard.sh` with 27 tests.

**Step 2: Run shellcheck on modified script**

Run: `shellcheck scripts/task-state-guard.sh`
Expected: No errors. Warnings about `SC2086` may appear for unquoted variables — fix any that shellcheck flags.

**Step 3: Verify bash syntax**

Run: `bash -n scripts/task-state-guard.sh`
Expected: Exit 0, no syntax errors.

**Step 4: Update design doc status**

In `docs/plans/2026-03-21-evidence-gated-transitions-design.md`, change:
```
**Status:** Draft
```
to:
```
**Status:** Implemented
```

**Step 5: Commit**

```bash
git add docs/plans/2026-03-21-evidence-gated-transitions-design.md
git commit -m "docs: mark evidence-gated transitions design as implemented"
```
