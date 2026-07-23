#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-task-utils"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

LIB="$REPO_ROOT/scripts/lib/task-utils.sh"

# --- Test 1: get_task_status reads list-item format (via legacy fixture helper) ---
setup_temp_dir
setup_nazgul_dir
create_task_file_legacy "TASK-001" "IN_PROGRESS"
source "$LIB"
result=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "get_task_status list-item format" "$result" "IN_PROGRESS"
teardown_temp_dir

# --- Test 1a: create_task_file (default fixture helper) emits canonical frontmatter (MF-052) ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-FM" "IN_PROGRESS"
assert_file_contains "create_task_file emits frontmatter fence" "$TEST_DIR/nazgul/tasks/TASK-FM.md" "^---$"
assert_file_contains "create_task_file emits status: line" "$TEST_DIR/nazgul/tasks/TASK-FM.md" "^status: IN_PROGRESS$"
assert_file_not_contains "create_task_file does not emit legacy list-item status" "$TEST_DIR/nazgul/tasks/TASK-FM.md" '^\- \*\*Status\*\*:'
source "$LIB"
result=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-FM.md")
assert_eq "get_task_status reads create_task_file's frontmatter" "$result" "IN_PROGRESS"
teardown_temp_dir

# --- Test 1b: create_task_file_legacy preserves the old list-item body verbatim ---
setup_temp_dir
setup_nazgul_dir
create_task_file_legacy "TASK-LEGACY" "READY"
assert_file_contains "create_task_file_legacy emits list-item status" "$TEST_DIR/nazgul/tasks/TASK-LEGACY.md" '^\- \*\*Status\*\*: READY$'
assert_file_not_contains "create_task_file_legacy does not emit frontmatter fence" "$TEST_DIR/nazgul/tasks/TASK-LEGACY.md" "^---$"
teardown_temp_dir

# --- Test 2: get_task_status reads ATX heading format ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
cat > "$TEST_DIR/nazgul/tasks/TASK-002.md" << 'EOF'
# TASK-002: Test
## Status: DONE
## Group: 1
EOF
source "$LIB"
result=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")
assert_eq "get_task_status ATX heading format" "$result" "DONE"
teardown_temp_dir

# --- Test 3: get_task_status returns default for missing file ---
setup_temp_dir
source "$LIB"
result=$(get_task_status "$TEST_DIR/nazgul/tasks/NONEXISTENT.md" "UNKNOWN")
assert_eq "get_task_status missing file default" "$result" "UNKNOWN"
teardown_temp_dir

# --- Test 4: set_task_status updates list-item format ---
setup_temp_dir
setup_nazgul_dir
create_task_file_legacy "TASK-003" "READY"
source "$LIB"
set_task_status "$TEST_DIR/nazgul/tasks/TASK-003.md" "READY" "IN_PROGRESS"
result=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-003.md")
assert_eq "set_task_status list-item" "$result" "IN_PROGRESS"
teardown_temp_dir

# --- Test 5: count_tasks_by_status ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "READY"
create_task_file "TASK-004" "BLOCKED"
source "$LIB"
assert_eq "count DONE" "$(count_tasks_by_status "$TEST_DIR/nazgul/tasks" "DONE")" "2"
assert_eq "count READY" "$(count_tasks_by_status "$TEST_DIR/nazgul/tasks" "READY")" "1"
assert_eq "count BLOCKED" "$(count_tasks_by_status "$TEST_DIR/nazgul/tasks" "BLOCKED")" "1"
assert_eq "count IN_PROGRESS" "$(count_tasks_by_status "$TEST_DIR/nazgul/tasks" "IN_PROGRESS")" "0"
teardown_temp_dir

# --- Test 6: get_active_task returns IN_PROGRESS task ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "IN_PROGRESS"
create_task_file "TASK-003" "READY"
source "$LIB"
result=$(get_active_task "$TEST_DIR/nazgul/tasks")
assert_eq "get_active_task finds IN_PROGRESS" "$result" "TASK-002"
teardown_temp_dir

# --- Test 7: get_active_task returns empty when none active ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
source "$LIB"
result=$(get_active_task "$TEST_DIR/nazgul/tasks")
assert_eq "get_active_task returns empty" "$result" ""
teardown_temp_dir

# --- Test 8: get_task_status reads ATX block format (## Status\nVALUE) ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
cat > "$TEST_DIR/nazgul/tasks/TASK-008.md" << 'EOF'
# TASK-008: Test

## Status
DONE

## Description
A task with block-style status (no colon, value on next line)
EOF
source "$LIB"
result=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-008.md")
assert_eq "get_task_status ATX block format" "$result" "DONE"
teardown_temp_dir

# --- Test 9: set_task_status converts ATX block format to inline ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
cat > "$TEST_DIR/nazgul/tasks/TASK-009.md" << 'EOF'
# TASK-009: Test

## Status
READY

## Description
Block-style status that should be converted to inline by set_task_status
EOF
source "$LIB"
set_task_status "$TEST_DIR/nazgul/tasks/TASK-009.md" "READY" "IN_PROGRESS"
result=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-009.md")
assert_eq "set_task_status ATX block format" "$result" "IN_PROGRESS"
teardown_temp_dir

# --- Canonical frontmatter status (new) ---
FM=$(mktemp)
printf -- '---\nstatus: IN_REVIEW\n---\n# TASK-1\n- **Status**: PLANNED\n' > "$FM"
assert_eq "frontmatter wins over legacy line" "$(get_task_status "$FM")" "IN_REVIEW"

printf -- '---\nstatus: NONSENSE\n---\n- **Status**: READY\n' > "$FM"
assert_eq "invalid frontmatter status → INVALID" "$(get_task_status "$FM")" "INVALID"

printf -- '# TASK-1\n- **Status**: BLOCKED\n' > "$FM"
assert_eq "legacy list-item fallback" "$(get_task_status "$FM")" "BLOCKED"

printf -- '---\nstatus: READY\n---\n# TASK-1\n' > "$FM"
set_task_status "$FM" READY IN_PROGRESS
assert_eq "set updates frontmatter" "$(get_task_status "$FM")" "IN_PROGRESS"
rm -f "$FM"

CRLF=$(mktemp)
printf -- '---\r\nstatus: READY\r\n---\r\n# TASK\r\n' > "$CRLF"
set_task_status "$CRLF" READY IN_PROGRESS
assert_eq "set_task_status rewrites CRLF frontmatter" "$(get_task_status "$CRLF")" "IN_PROGRESS"
rm -f "$CRLF"

# Compare-and-swap: frontmatter rewrite honors old_status (matches list-item branch)
CAS=$(mktemp)
printf -- '---\nstatus: IN_REVIEW\n---\n# TASK\n' > "$CAS"
set_task_status "$CAS" READY DONE   # old_status mismatch → no-op
assert_eq "frontmatter set is no-op when old_status mismatches" "$(get_task_status "$CAS")" "IN_REVIEW"
set_task_status "$CAS" IN_REVIEW DONE   # old_status matches → transition
assert_eq "frontmatter set transitions when old_status matches" "$(get_task_status "$CAS")" "DONE"
rm -f "$CAS"

# --- Test 10: count_tasks_and_find_active buckets a mixed set, incl. canonical APPROVED (MF-001/002/009/011, TASK-003) ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
create_task_file "TASK-003" "IN_PROGRESS"
create_task_file "TASK-004" "IMPLEMENTED"
create_task_file "TASK-005" "IN_REVIEW"
create_task_file "TASK-006" "APPROVED"
create_task_file "TASK-007" "CHANGES_REQUESTED"
create_task_file "TASK-008" "BLOCKED"
create_task_file "TASK-009" "PLANNED"
source "$LIB"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks"
assert_eq "counting: DONE_COUNT" "$DONE_COUNT" "1"
assert_eq "counting: READY_COUNT" "$READY_COUNT" "1"
assert_eq "counting: IN_PROGRESS_COUNT" "$IN_PROGRESS_COUNT" "1"
assert_eq "counting: IN_REVIEW_COUNT (IMPLEMENTED+IN_REVIEW)" "$IN_REVIEW_COUNT" "2"
assert_eq "counting: APPROVED_COUNT (TASK-002 enum fix)" "$APPROVED_COUNT" "1"
assert_eq "counting: CHANGES_COUNT" "$CHANGES_COUNT" "1"
assert_eq "counting: BLOCKED_COUNT" "$BLOCKED_COUNT" "1"
assert_eq "counting: PLANNED_COUNT" "$PLANNED_COUNT" "1"
assert_eq "counting: INVALID_COUNT (none in this set)" "$INVALID_COUNT" "0"
assert_eq "counting: TOTAL_COUNT" "$TOTAL_COUNT" "9"
teardown_temp_dir

# --- Test 11: off-vocabulary status hits the INVALID bucket + loud stderr diagnostic (MF-002) ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "FROBNICATED"
source "$LIB"
STDERR_FILE=$(mktemp)
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks" 2>"$STDERR_FILE"
STDERR_OUT=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"
assert_eq "INVALID: DONE_COUNT unaffected" "$DONE_COUNT" "1"
assert_eq "INVALID: INVALID_COUNT counts the off-vocab task" "$INVALID_COUNT" "1"
assert_eq "INVALID: TOTAL_COUNT still includes it (faithful TOTAL_COUNT semantics)" "$TOTAL_COUNT" "2"
assert_eq "INVALID: no bucket silently absorbs it (sum of tracked buckets == TOTAL_COUNT - INVALID_COUNT)" \
  "$((DONE_COUNT + READY_COUNT + IN_PROGRESS_COUNT + IN_REVIEW_COUNT + APPROVED_COUNT + CHANGES_COUNT + BLOCKED_COUNT + PLANNED_COUNT))" "1"
case "$STDERR_OUT" in
  *TASK-002*FROBNICATED*) _pass "INVALID: stderr diagnostic names task + raw status" ;;
  *) _fail "INVALID: stderr diagnostic names task + raw status" "got: $STDERR_OUT" ;;
esac
assert_eq "INVALID: INVALID_TASKS lists the offender" "$INVALID_TASKS" "TASK-002:FROBNICATED"
teardown_temp_dir

# --- Test 12: active-task selection matches stop-hook.sh's tie-break — first eligible in lexical iteration order ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "IN_PROGRESS"
create_task_file "TASK-003" "IN_REVIEW"
source "$LIB"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks"
assert_eq "active-task: picks first eligible (TASK-002), not TASK-003" "$ACTIVE_TASK" "TASK-002"
assert_eq "active-task: ACTIVE_STATUS matches" "$ACTIVE_STATUS" "IN_PROGRESS"
teardown_temp_dir

# --- Test 13: no active-eligible task -> ACTIVE_TASK stays empty (faithful refactor, no fallback-to-READY behavior in this helper) ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
source "$LIB"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks"
assert_eq "active-task: empty when none IN_PROGRESS/CHANGES_REQUESTED/IN_REVIEW/IMPLEMENTED" "$ACTIVE_TASK" ""
teardown_temp_dir

# --- Test 14: ACTIVE_RETRY reads the Retry count field for the selected active task ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
cat > "$TEST_DIR/nazgul/tasks/TASK-001.md" << 'EOF'
---
status: IN_PROGRESS
---
# TASK-001: Test
- **Retry count**: 2/3
EOF
source "$LIB"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks"
assert_eq "active-task: ACTIVE_RETRY parses Retry count" "$ACTIVE_RETRY" "2"
teardown_temp_dir

# --- Test 15: get_task_files_modified parses a real bracket/quote-laden JSON-array value (MF-025) ---
setup_temp_dir
setup_nazgul_dir
create_task_file_with_files_modified "TASK-001" "IN_PROGRESS" '["scripts/foo.sh","tests/test-foo.sh"]'
source "$LIB"
result=$(get_task_files_modified "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "get_task_files_modified: parses JSON array to newline list" "$result" "$(printf 'scripts/foo.sh\ntests/test-foo.sh')"
teardown_temp_dir

# --- Test 16: get_task_files_modified on a single-entry array ---
setup_temp_dir
setup_nazgul_dir
create_task_file_with_files_modified "TASK-001" "IN_PROGRESS" '["scripts/lib/task-utils.sh"]'
source "$LIB"
result=$(get_task_files_modified "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "get_task_files_modified: single-entry array" "$result" "scripts/lib/task-utils.sh"
teardown_temp_dir

# --- Test 17: get_task_files_modified on a legacy non-JSON value degrades loudly, not silently (MF-025 / TRD Risks row 3) ---
setup_temp_dir
setup_nazgul_dir
create_task_file_with_files_modified "TASK-001" "IN_PROGRESS" "scripts/foo.sh, tests/test-foo.sh"
source "$LIB"
STDERR_FILE=$(mktemp)
result=$(get_task_files_modified "$TEST_DIR/nazgul/tasks/TASK-001.md" 2>"$STDERR_FILE")
STDERR_OUT=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"
assert_eq "get_task_files_modified: legacy non-JSON value returns empty" "$result" ""
case "$STDERR_OUT" in
  *TASK-001.md*) _pass "get_task_files_modified: legacy value emits loud stderr diagnostic" ;;
  *) _fail "get_task_files_modified: legacy value emits loud stderr diagnostic" "got: $STDERR_OUT" ;;
esac
teardown_temp_dir

# --- Test 18: get_task_files_modified on a missing field returns empty silently ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IN_PROGRESS"
source "$LIB"
STDERR_FILE=$(mktemp)
result=$(get_task_files_modified "$TEST_DIR/nazgul/tasks/TASK-001.md" 2>"$STDERR_FILE")
STDERR_OUT=$(cat "$STDERR_FILE")
rm -f "$STDERR_FILE"
assert_eq "get_task_files_modified: missing field returns empty" "$result" ""
assert_eq "get_task_files_modified: missing field emits no stderr diagnostic" "$STDERR_OUT" ""
teardown_temp_dir

report_results
