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

report_results
