#!/usr/bin/env bash
set -euo pipefail

# Test: hygiene bundle — orphaned conductor-marker self-heal (session-context.sh),
# prior-objective task archival (scrub-stale-review-artifacts.sh), and the
# CLAUDE.md colon-command-form / stale migration-name fixes.
TEST_NAME="test-hygiene"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
# shellcheck source=lib/session-tracker.sh
source "$REPO_ROOT/scripts/lib/session-tracker.sh"

echo "=== $TEST_NAME ==="

SESSION_SCRIPT="$REPO_ROOT/scripts/session-context.sh"
SCRUB="$REPO_ROOT/scripts/scrub-stale-review-artifacts.sh"

write_conductor_markers() {
  mkdir -p "$TEST_DIR/nazgul/conductor"
  [ -n "${1:-}" ] && printf '%s' "$1" > "$TEST_DIR/nazgul/conductor/.session"
  printf '{"wave":1,"units":["TASK-001"],"reason":"test"}' > "$TEST_DIR/nazgul/conductor/.resume-needed"
}

register_live_session() {
  register_session "$1" "$TEST_DIR/nazgul/sessions"
}

# --- Test 1: dead session, open objective -> markers cleared ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "READY"
write_conductor_markers "dead-session-1"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
assert_file_not_exists "dead session: .session cleared" "$TEST_DIR/nazgul/conductor/.session"
assert_file_not_exists "dead session: .resume-needed cleared" "$TEST_DIR/nazgul/conductor/.resume-needed"
teardown_temp_dir

# --- Test 2: live session, open objective -> markers left alone ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "READY"
write_conductor_markers "live-session-1"
register_live_session "live-session-1"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
assert_file_exists "live session: .session untouched" "$TEST_DIR/nazgul/conductor/.session"
assert_file_exists "live session: .resume-needed untouched" "$TEST_DIR/nazgul/conductor/.resume-needed"
teardown_temp_dir

# --- Test 3: live session, but objective complete (all tasks DONE) -> markers cleared ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
write_conductor_markers "live-session-2"
register_live_session "live-session-2"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
assert_file_not_exists "completed objective: .session cleared" "$TEST_DIR/nazgul/conductor/.session"
assert_file_not_exists "completed objective: .resume-needed cleared" "$TEST_DIR/nazgul/conductor/.resume-needed"
teardown_temp_dir

# --- Test 4: live session, feat_id mismatch (graph belongs to a prior objective) -> cleared ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-NEW"'
create_task_file "TASK-001" "READY"
write_conductor_markers "live-session-3"
register_live_session "live-session-3"
printf '{"schema":1,"objective":"FEAT-OLD","tasks":{}}' > "$TEST_DIR/nazgul/conductor/graph.json"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
assert_file_not_exists "feat_id mismatch: .session cleared" "$TEST_DIR/nazgul/conductor/.session"
teardown_temp_dir

# --- Test 5: resume-needed only (no .session), dead objective -> cleared ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
mkdir -p "$TEST_DIR/nazgul/conductor"
printf '{"wave":1,"units":["TASK-001"],"reason":"test"}' > "$TEST_DIR/nazgul/conductor/.resume-needed"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
assert_file_not_exists "resume-needed only, dead: cleared" "$TEST_DIR/nazgul/conductor/.resume-needed"
teardown_temp_dir

# --- Test 6: no markers present -> no-op, no error ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "READY"
set +e
bash "$SESSION_SCRIPT" >/dev/null 2>&1
ec=$?
set -e
assert_exit_code "no markers: exit 0" "$ec" 0
teardown_temp_dir

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
