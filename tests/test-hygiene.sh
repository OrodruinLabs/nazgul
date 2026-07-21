#!/usr/bin/env bash
set -euo pipefail

# Test: hygiene bundle — prior-objective task archival
# (scrub-stale-review-artifacts.sh), and the CLAUDE.md colon-command-form /
# stale migration-name fixes.
#
# Note: this file previously also covered the orphaned conductor-marker
# self-heal in session-context.sh (.session/.resume-needed). That reader was
# dead code after the conductor engine's only writer (subagent-stop.sh's
# orphan detector) was deleted as part of the Parallel Execution Collapse, so
# both the reader and its tests were removed together.
TEST_NAME="test-hygiene"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

SCRUB="$REPO_ROOT/scripts/scrub-stale-review-artifacts.sh"

# --- Test 7: scrub archives prior tasks/ even when reviews+learning are empty ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
OUTPUT7=$("$SCRUB" --for-new-objective FEAT-010 "$TEST_DIR/nazgul")
assert_contains "tasks-only run reports archive" "$OUTPUT7" "archived stale artifacts"
assert_file_not_exists "TASK-001 removed from tasks/" "$TEST_DIR/nazgul/tasks/TASK-001.md"
assert_file_not_exists "TASK-002 removed from tasks/" "$TEST_DIR/nazgul/tasks/TASK-002.md"
ARCHIVE_DIR=$(find "$TEST_DIR/nazgul/archive" -maxdepth 1 -mindepth 1 -type d | head -1)
assert_file_exists "TASK-001 archived" "$ARCHIVE_DIR/tasks/TASK-001.md"
assert_file_exists "TASK-002 archived" "$ARCHIVE_DIR/tasks/TASK-002.md"
assert_dir_exists "tasks/ recreated empty" "$TEST_DIR/nazgul/tasks"
teardown_temp_dir

# --- Test 8: scrub still no-ops when tasks/ + reviews/ + learning/ all empty ---
setup_temp_dir
setup_nazgul_dir
OUTPUT8=$("$SCRUB" --for-new-objective FEAT-011 "$TEST_DIR/nazgul")
assert_contains "all-empty run still no-ops" "$OUTPUT8" "nothing stale to scrub"
assert_dir_not_exists "all-empty: no archive dir" "$TEST_DIR/nazgul/archive"
teardown_temp_dir

# --- Test 8b: guard refuses archival while a READY task is open ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "READY"
create_task_file "TASK-002" "DONE"
OUTPUT_GUARD=$("$SCRUB" --for-new-objective FEAT-012 "$TEST_DIR/nazgul" 2>&1)
assert_contains "guard refuses: output mentions refusing" "$OUTPUT_GUARD" "refusing"
assert_file_exists "guard refuses: READY task not archived" "$TEST_DIR/nazgul/tasks/TASK-001.md"
assert_dir_not_exists "guard refuses: no archive dir created" "$TEST_DIR/nazgul/archive"
teardown_temp_dir

# --- Test 8c: BLOCKED task also counts as open and prevents archival ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "BLOCKED" "none" "test blocker"
OUTPUT_BLOCKED=$("$SCRUB" --for-new-objective FEAT-013 "$TEST_DIR/nazgul" 2>&1)
assert_contains "BLOCKED guard: output mentions refusing" "$OUTPUT_BLOCKED" "refusing"
assert_file_exists "BLOCKED guard: task not archived" "$TEST_DIR/nazgul/tasks/TASK-001.md"
assert_dir_not_exists "BLOCKED guard: no archive dir created" "$TEST_DIR/nazgul/archive"
teardown_temp_dir

# --- Test 9: CLAUDE.md Commands list is colon form (no dash-form command refs) ---
if grep -qE '/nazgul-[a-z]+' "$REPO_ROOT/CLAUDE.md"; then
  _fail "CLAUDE.md has no dash-form /nazgul-* refs" "found: $(grep -oE '/nazgul-[a-z]+' "$REPO_ROOT/CLAUDE.md" | head -1)"
else
  _pass "CLAUDE.md has no dash-form /nazgul-* refs"
fi

# --- Test 10: nazgul/docs/*.md (if present) has no stale migrate_19_to_20 heartbeat reference ---
DOCS_DIR="${CLAUDE_PROJECT_DIR:-$REPO_ROOT}/nazgul/docs"
if [ -d "$DOCS_DIR" ] && grep -rl "migrate_19_to_20" "$DOCS_DIR"/*.md >/dev/null 2>&1; then
  BAD=$(grep -rl "heartbeat.*migrate_19_to_20\|migrate_19_to_20.*heartbeat" "$DOCS_DIR"/*.md 2>/dev/null || true)
  if [ -n "$BAD" ]; then
    _fail "nazgul/docs has no stale heartbeat migrate_19_to_20 reference" "found in: $BAD"
  else
    _pass "nazgul/docs has no stale heartbeat migrate_19_to_20 reference"
  fi
else
  _pass "nazgul/docs has no stale heartbeat migrate_19_to_20 reference"
fi

report_results
