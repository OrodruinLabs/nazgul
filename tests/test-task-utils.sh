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

# --- PATCH-005 (PR #86 review): every set_task_status branch staged through a
# PREDICTABLE sibling that a pre-created symlink could aim at another file. ---
setup_temp_dir
SL_DIR="$TEST_DIR/symlink-cases"
mkdir -p "$SL_DIR"

# Probe that does NOT call the code under test, so a base-tree replay measures
# the defect rather than the absence of a helper this patch introduces.
file_mode_probe() {
  nz_file_mode "$1"
}

# Each format exercises a different branch, and each branch had its own
# predictable sibling: `.tmp` for the awk branches, `.bak` for the sed ones.
sl_case() {
  local name="$1" body="$2" old="$3" new="$4" bait="$5"
  local f="$SL_DIR/${name}.md" canary="$SL_DIR/${name}.canary"
  printf 'do-not-truncate\n' > "$canary"
  chmod 600 "$canary"
  printf -- "$body" > "$f"
  ln -s "$canary" "${f}${bait}"
  set_task_status "$f" "$old" "$new" 2>/dev/null || true
  assert_eq "symlink bait ${bait} (${name}): status still transitions" \
    "$(get_task_status "$f")" "$new"
  assert_eq "symlink bait ${bait} (${name}): the bait target is not truncated" \
    "$(cat "$canary")" "do-not-truncate"
  assert_eq "symlink bait ${bait} (${name}): the bait target keeps its mode" \
    "$(file_mode_probe "$canary")" "600"
  if [ -L "$f" ]; then
    _fail "symlink bait ${bait} (${name}): the manifest is not replaced by the bait"
  else
    _pass "symlink bait ${bait} (${name}): the manifest is not replaced by the bait"
  fi
}
sl_case frontmatter '---\nstatus: READY\n---\n# T\n' READY IN_PROGRESS .tmp
sl_case atxblock '# T\n\n## Status\nREADY\n' READY IN_PROGRESS .tmp
sl_case atxinline '# T\n\n## Status: READY\n' READY IN_PROGRESS .bak
sl_case listitem '# T\n\n- **Status**: READY\n' READY IN_PROGRESS .bak
sl_case legacyfm '# T\n---\nstatus: READY\n---\n' READY IN_PROGRESS .bak

# A symlinked MANIFEST is refused outright rather than followed to its target.
SL_TARGET="$SL_DIR/target.md"
printf -- '---\nstatus: READY\n---\n' > "$SL_TARGET"
ln -s "$SL_TARGET" "$SL_DIR/manifest-link.md"
SL_ERR=$(set_task_status "$SL_DIR/manifest-link.md" READY IN_PROGRESS 2>&1) && SL_EC=0 || SL_EC=$?
assert_exit_code "a symlinked manifest is refused, not followed" "$SL_EC" 1
assert_contains "the refusal says why" "$SL_ERR" "not a regular non-symlink file"
assert_eq "the symlink target keeps its status" "$(get_task_status "$SL_TARGET")" "READY"

# nz_rewrite_file preserves the destination mode, and leaves nothing behind.
MODE_F="$SL_DIR/mode.md"
printf -- '---\nstatus: READY\n---\n' > "$MODE_F"
chmod 640 "$MODE_F"
set_task_status "$MODE_F" READY IN_PROGRESS
assert_eq "nz_rewrite_file preserves the destination mode" "$(file_mode_probe "$MODE_F")" "640"
STRAY=$(find "$SL_DIR" -name '.nz-rewrite.*' | wc -l | tr -d ' ')
assert_eq "no colocated staging file is left behind" "$STRAY" "0"
# The baits must SURVIVE as untouched symlinks: consuming one would mean the
# writer went to the predictable path after all.
BAITS=$(find "$SL_DIR" -type l -name '*.md.tmp' -o -type l -name '*.md.bak' | wc -l | tr -d ' ')
assert_eq "every predictable-path bait is left in place, unconsumed" "$BAITS" "5"
teardown_temp_dir

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

# --- Test 19 (board-3 NEW-4): a manifest matching NO inline status form must reach
# get_task_status's default; the no-match `grep` used to abort an errexit caller. ---
setup_temp_dir
setup_nazgul_dir
printf '# TASK-BLOCK\n\n## Status\nDONE\n' > "$TEST_DIR/nazgul/tasks/TASK-BLOCK.md"
printf '# TASK-NONE\n\nthis manifest carries no status in any format\n' > "$TEST_DIR/nazgul/tasks/TASK-NONE.md"

# Direct call, NOT a command substitution: bash leaves `inherit_errexit` off by
# default, which masks an in-function abort at every call site in the tree.
probe_errexit() {
  bash -euo pipefail -c 'source "$1"; get_task_status "$2" "PLANNED"; echo REACHED' _ "$LIB" "$1" 2>&1
}

TU_OUT=$(probe_errexit "$TEST_DIR/nazgul/tasks/TASK-BLOCK.md"); TU_EC=$?
assert_exit_code "errexit caller: ATX-block manifest does not abort get_task_status" "$TU_EC" 0
assert_contains "errexit caller: ATX-block manifest still parses to DONE" "$TU_OUT" "DONE"
assert_contains "errexit caller: the caller reaches the statement after the call" "$TU_OUT" "REACHED"

TU_OUT=$(probe_errexit "$TEST_DIR/nazgul/tasks/TASK-NONE.md"); TU_EC=$?
assert_exit_code "errexit caller: status-less manifest does not abort get_task_status" "$TU_EC" 0
assert_contains "errexit caller: status-less manifest returns the supplied default" "$TU_OUT" "PLANNED"
assert_contains "errexit caller: status-less manifest lets the caller continue" "$TU_OUT" "REACHED"

# The same fact through the shape every call site in the tree actually uses,
# with the masking shopt turned on so the substitution cannot hide the abort.
if bash -c 'shopt -s inherit_errexit' >/dev/null 2>&1; then
  TU_OUT=$(bash -euo pipefail -O inherit_errexit -c \
    'source "$1"; s=$(get_task_status "$2" "PLANNED"); echo "$s REACHED"' _ "$LIB" \
    "$TEST_DIR/nazgul/tasks/TASK-BLOCK.md" 2>&1); TU_EC=$?
  assert_exit_code "inherit_errexit caller: substitution shape does not abort" "$TU_EC" 0
  assert_contains "inherit_errexit caller: substitution shape still yields DONE" "$TU_OUT" "DONE REACHED"
else
  _skip "inherit_errexit caller: substitution shape does not abort (bash lacks inherit_errexit)"
fi
teardown_temp_dir

# --- Test 20 (#169 / AC-12): DEFECT PIN: get_task_field splits at the field's OWN colon. Captured,
# not invented: Blocked reason is stop-hook.sh:886's text, the rest a live TASK-008.md manifest's ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
cat > "$TEST_DIR/nazgul/tasks/TASK-042.md" << 'EOF'
---
status: BLOCKED
---
# TASK-042: Test task

- **Group**: 1
- **Depends on**: none
- **Retry count**: 2/3
- **Created at**: 2026-08-26T11:15:00Z
- **Files modified**: ["scripts/lib/task-utils.sh","tests/test-task-utils.sh"]
- **Blocked kind**: reconciliation
- **Blocked reason**: review evidence missing (code-reviewer) — run /nazgul:review --materialize TASK-042
- **Blocked observed**: DONE
EOF
source "$LIB"
TU_M="$TEST_DIR/nazgul/tasks/TASK-042.md"
assert_eq "DEFECT PIN: Blocked reason keeps the colon inside /nazgul:review" \
  "$(get_task_field "$TU_M" "Blocked reason" "Unknown reason")" \
  "review evidence missing (code-reviewer) — run /nazgul:review --materialize TASK-042"
assert_eq "DEFECT PIN: Created at keeps every colon in the ISO-8601 timestamp" \
  "$(get_task_field "$TU_M" "Created at" "DEFAULT")" "2026-08-26T11:15:00Z"
teardown_temp_dir

# --- Test 21 (#169): a value ENDING in a colon reads as PRESENT, not as the caller's default ---
# The greedy split trimmed it to empty, and every consumer reads "absent" as the permissive answer.
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
printf -- '- **Blocked reason**: waiting on upstream decision:\n' > "$TEST_DIR/nazgul/tasks/TASK-043.md"
source "$LIB"
assert_eq "trailing-colon value is returned verbatim, not swallowed into the default" \
  "$(get_task_field "$TEST_DIR/nazgul/tasks/TASK-043.md" "Blocked reason" "Unknown reason")" \
  "waiting on upstream decision:"
teardown_temp_dir

# --- Test 22 (#169 control): colon-free fields are byte-unchanged, and the derived pattern keeps
# the tolerant, case-insensitive anchor the `grep -iE` had ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
cat > "$TEST_DIR/nazgul/tasks/TASK-044.md" << 'EOF'
---
status: BLOCKED
---
# TASK-044: Test task

- **Group**: 1
- **Depends on**: TASK-001, TASK-002
- **Retry count**: 2/3
- **Files modified**: ["scripts/lib/task-utils.sh","tests/test-task-utils.sh"]
EOF
printf -- '-  **blocked reason**:   stack-utils: sync conflict   \n' >> "$TEST_DIR/nazgul/tasks/TASK-044.md"
source "$LIB"
TU_M="$TEST_DIR/nazgul/tasks/TASK-044.md"
assert_eq "control: colon-free Group byte-unchanged" "$(get_task_field "$TU_M" "Group" "X")" "1"
assert_eq "control: colon-free Depends on byte-unchanged" "$(get_task_field "$TU_M" "Depends on" "X")" "TASK-001, TASK-002"
assert_eq "control: colon-free Retry count byte-unchanged" "$(get_task_field "$TU_M" "Retry count" "X")" "2/3"
assert_eq "control: Files modified still parses to a newline list" \
  "$(get_task_files_modified "$TU_M")" "$(printf 'scripts/lib/task-utils.sh\ntests/test-task-utils.sh')"
assert_eq "control: an absent field still returns the caller's default" "$(get_task_field "$TU_M" "Nope" "X")" "X"
assert_eq "control: indented + lowercased label still matches, and padding is still trimmed" \
  "$(get_task_field "$TU_M" "Blocked reason" "Unknown reason")" "stack-utils: sync conflict"
teardown_temp_dir

# --- Test 23 (#169 / AC-12): DEFECT PIN: get_task_status's two inline arms split at the label, so
# the INVALID diagnostic names the whole off-vocabulary status and not its final segment ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
printf -- '# TASK-045: Test task\n\n- **Status**: MIGRATED:LEGACY\n' > "$TEST_DIR/nazgul/tasks/TASK-045.md"
printf -- '# ATX: Test task\n## Status: MIGRATED:LEGACY\n' > "$TEST_DIR/atx-status.md"
source "$LIB"
assert_eq "DEFECT PIN: list-item arm keeps the colon in an off-vocabulary status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-045.md" "PLANNED")" "MIGRATED:LEGACY"
assert_eq "DEFECT PIN: ATX-inline arm keeps the colon in an off-vocabulary status" \
  "$(get_task_status "$TEST_DIR/atx-status.md" "PLANNED")" "MIGRATED:LEGACY"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks" 2>/dev/null
assert_eq "INVALID_TASKS names the whole raw status, not its final segment" \
  "$INVALID_TASKS" "TASK-045:MIGRATED:LEGACY"
teardown_temp_dir

# --- Test 24 (#169): ACTIVE_RETRY goes through the shared reader — same contract, and no
# hand-rolled greedy split left in this file ---
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
printf -- '---\nstatus: IN_PROGRESS\n---\n# TASK-047: Test task\n' > "$TEST_DIR/nazgul/tasks/TASK-047.md"
source "$LIB"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks"
assert_eq "ACTIVE_RETRY: absent Retry count field stays empty (faithful refactor)" "$ACTIVE_RETRY" ""
printf -- '  -  **retry count**: 3/3\n' >> "$TEST_DIR/nazgul/tasks/TASK-047.md"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks"
assert_eq "ACTIVE_RETRY: leading digit run of a tolerant-anchor Retry count" "$ACTIVE_RETRY" "3"
teardown_temp_dir

report_results
