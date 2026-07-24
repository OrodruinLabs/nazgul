#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — notify.sh is always non-blocking (exits 0).

# Test: scripts/notify.sh — MF-031. Verifies `nazgul/...` paths are resolved
# against `CLAUDE_PROJECT_DIR` (like every sibling guard's
# `PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"` pattern) rather than as bare
# relative paths that only happen to work when cwd == the project root.
TEST_NAME="test-notify"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

NOTIFY="$REPO_ROOT/scripts/notify.sh"

# A cwd deliberately NOT the project root, to prove path resolution doesn't
# depend on cwd happening to already be there.
ELSEWHERE=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-elsewhere-XXXXXX")

# Runs notify.sh from $ELSEWHERE (not the project root), with
# CLAUDE_PROJECT_DIR pointed at $TEST_DIR, piping a minimal Stop-hook stdin
# envelope. Captures stdout+stderr.
run_notify_from_elsewhere() {
  (
    cd "$ELSEWHERE" || exit 1
    printf '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" NAZGUL_NOTIFY_DEBUG=1 bash "$NOTIFY" 2>&1
  )
}

# --- Test 1: MF-031 — all tasks DONE + a configured notification command,
# invoked from a cwd that is NOT the project root -> completion is still
# detected and the command still runs (proving nazgul/tasks and
# nazgul/config.json were resolved via CLAUDE_PROJECT_DIR, not bare cwd). ---
setup_temp_dir
setup_nazgul_dir
MARKER="$TEST_DIR/notified.flag"
create_config ".notifications.on_complete = \"touch $MARKER\""
# notify.sh's own DONE-detection regex matches the legacy `- **Status**: X`
# list-item shape (a separate, pre-existing gap from this task's MF-031
# scope — canonical frontmatter isn't recognized here either way) so use
# create_task_file_legacy to isolate this test to path resolution only.
create_task_file_legacy "TASK-001" "DONE"
create_task_file_legacy "TASK-002" "DONE"
OUT=$(run_notify_from_elsewhere)
assert_file_exists "MF-031: notification fires from a non-project-root cwd" "$MARKER"
assert_contains "MF-031: debug log detects all tasks DONE" "$OUT" "tasks DONE"
teardown_temp_dir
rm -f "$MARKER" 2>/dev/null || true

# --- Test 2: control — not all tasks DONE, same non-project-root cwd -> no
# notification (proves Test 1 isn't just "always fires"). ---
setup_temp_dir
setup_nazgul_dir
MARKER2="$TEST_DIR/should-not-fire.flag"
create_config ".notifications.on_complete = \"touch $MARKER2\""
create_task_file_legacy "TASK-001" "DONE"
create_task_file_legacy "TASK-002" "IN_PROGRESS"
run_notify_from_elsewhere >/dev/null
assert_file_not_exists "control: incomplete tasks -> no notification" "$MARKER2"
teardown_temp_dir

# --- Test 3: MF-031 — NAZGUL_COMPLETE-in-transcript path also resolves
# nazgul/config.json (for NAZGUL_OBJECTIVE) via CLAUDE_PROJECT_DIR from a
# non-project-root cwd, without erroring. ---
setup_temp_dir
setup_nazgul_dir
create_config ".objective = \"test objective\""
TRANSCRIPT="$TEST_DIR/transcript.jsonl"
printf 'assistant said NAZGUL_COMPLETE\n' > "$TRANSCRIPT"
OUT3=$(
  cd "$ELSEWHERE" || exit 1
  jq -n --arg tp "$TRANSCRIPT" '{transcript_path: $tp}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" NAZGUL_NOTIFY_DEBUG=1 bash "$NOTIFY" 2>&1
)
assert_contains "MF-031: NAZGUL_COMPLETE detected in transcript from elsewhere" "$OUT3" "NAZGUL_COMPLETE found in transcript"
teardown_temp_dir

rm -rf "$ELSEWHERE"

# --- Test 4: bash -n / shellcheck sanity (project convention) ---
bash -n "$NOTIFY" 2>/dev/null && _pass "bash -n clean: notify.sh" || _fail "bash -n clean: notify.sh" "syntax error in $NOTIFY"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$NOTIFY" 2>/dev/null && _pass "shellcheck clean: notify.sh" || _fail "shellcheck clean: notify.sh" "shellcheck found issues in $NOTIFY"
else
  _pass "shellcheck clean: notify.sh (shellcheck not installed, skipped)"
fi

report_results
