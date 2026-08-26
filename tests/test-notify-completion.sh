#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: notify.sh is always non-blocking, and its exit code is asserted.

# Test: scripts/notify.sh's completion branch (issue #203) — a private DONE regex
# matching only legacy body spellings, with an inlined `TOTAL == DONE` veto on top.
TEST_NAME="test-notify-completion"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

NOTIFY="$REPO_ROOT/scripts/notify.sh"
NC_ERR=$(mktemp "${TMPDIR:-/tmp}/nazgul-notify-err-XXXXXX")

# Returns the hook's stdout; its stderr lands in $NC_ERR so the two stay separable.
run_notify() { # <notify-script> <project-root>
  printf '{}' | CLAUDE_PROJECT_DIR="$2" NAZGUL_NOTIFY_DEBUG=1 bash "$1" 2>"$NC_ERR"
}

# --- Fixture 1: all tasks DONE, canonical frontmatter -> completion fires.
# The positive control: exactly the manifest shape the dead branch never matched.
setup_temp_dir
setup_nazgul_dir
MARKER1="$TEST_DIR/fired-1.flag"
create_config ".notifications.on_complete = \"touch $MARKER1\""
create_task_file TASK-001 DONE
create_task_file TASK-002 DONE
OUT1=$(run_notify "$NOTIFY" "$TEST_DIR"); RC1=$?
ERR1=$(cat "$NC_ERR")
assert_exit_code "#203 all-DONE frontmatter: the hook stays non-blocking" "$RC1" 0
assert_contains "#203 all-DONE frontmatter: stdout is the non-blocking envelope" "$OUT1" '{"continue": true}'
assert_file_exists "#203 all-DONE frontmatter: the notification command runs" "$MARKER1"
assert_contains "#203 all-DONE frontmatter: the debug log names the terminal count" \
  "$ERR1" "All 2 tasks DONE or CANCELLED (2 DONE, 0 CANCELLED)"
teardown_temp_dir

# --- Fixture 2: one CANCELLED, the rest DONE -> completion STILL fires.
# The seventh veto site: one cancelled task used to make notifying impossible.
setup_temp_dir
setup_nazgul_dir
MARKER2="$TEST_DIR/fired-2.flag"
create_config ".notifications.on_complete = \"touch $MARKER2\""
create_task_file TASK-001 DONE
create_task_file TASK-002 CANCELLED
create_task_file TASK-003 DONE
OUT2=$(run_notify "$NOTIFY" "$TEST_DIR"); RC2=$?
ERR2=$(cat "$NC_ERR")
assert_exit_code "#203 CANCELLED carve-out: the hook stays non-blocking" "$RC2" 0
assert_contains "#203 CANCELLED carve-out: stdout is the non-blocking envelope" "$OUT2" '{"continue": true}'
assert_file_exists "#203 CANCELLED carve-out: a cancelled task does not veto the notification" "$MARKER2"
assert_contains "#203 CANCELLED carve-out: the debug log counts CANCELLED as terminal" \
  "$ERR2" "All 3 tasks DONE or CANCELLED (2 DONE, 1 CANCELLED)"
teardown_temp_dir

# --- Fixture 3: control — one task still IN_PROGRESS -> no notification.
setup_temp_dir
setup_nazgul_dir
MARKER3="$TEST_DIR/should-not-fire.flag"
create_config ".notifications.on_complete = \"touch $MARKER3\""
create_task_file TASK-001 DONE
create_task_file TASK-002 CANCELLED
create_task_file TASK-003 IN_PROGRESS
OUT3=$(run_notify "$NOTIFY" "$TEST_DIR"); RC3=$?
ERR3=$(cat "$NC_ERR")
assert_exit_code "#203 control: the hook stays non-blocking" "$RC3" 0
assert_contains "#203 control: stdout is the non-blocking envelope" "$OUT3" '{"continue": true}'
assert_file_not_exists "#203 control: a non-terminal task suppresses the notification" "$MARKER3"
assert_contains "#203 control: the debug log says why" "$ERR3" "Loop not complete"
teardown_temp_dir

# --- Fixture 4: uninitialised project -> degrades, never aborts.
# A Stop hook on a project with no nazgul/ must still reach the envelope.
setup_temp_dir
MARKER4="$TEST_DIR/should-not-fire-4.flag"
OUT4=$(NAZGUL_NOTIFY_ON_STOP="touch $MARKER4" run_notify "$NOTIFY" "$TEST_DIR"); RC4=$?
ERR4=$(cat "$NC_ERR")
assert_exit_code "#203 uninitialised project: the hook stays non-blocking" "$RC4" 0
assert_contains "#203 uninitialised project: stdout is the non-blocking envelope" "$OUT4" '{"continue": true}'
assert_file_not_exists "#203 uninitialised project: nothing is notified" "$MARKER4"
assert_not_contains "#203 uninitialised project: no unbound-variable abort" "$ERR4" "unbound variable"
assert_not_contains "#203 uninitialised project: no missing-file abort" "$ERR4" "No such file or directory"
teardown_temp_dir

# --- Fixture 5: task-utils.sh unreadable -> the guarded source degrades.
# Driven against a real copy of scripts/ with the lib removed, not a stub.
setup_temp_dir
setup_nazgul_dir
MARKER5="$TEST_DIR/should-not-fire-5.flag"
create_config ".notifications.on_complete = \"touch $MARKER5\""
create_task_file TASK-001 DONE
create_task_file TASK-002 DONE
DEGRADED="$TEST_DIR/degraded-scripts"
cp -R "$REPO_ROOT/scripts" "$DEGRADED"
rm -f "$DEGRADED/lib/task-utils.sh"
OUT5=$(run_notify "$DEGRADED/notify.sh" "$TEST_DIR"); RC5=$?
ERR5=$(cat "$NC_ERR")
assert_file_not_exists "#203 missing lib: the fixture really removed it" "$DEGRADED/lib/task-utils.sh"
assert_exit_code "#203 missing lib: the hook stays non-blocking" "$RC5" 0
assert_contains "#203 missing lib: stdout is the non-blocking envelope" "$OUT5" '{"continue": true}'
assert_file_not_exists "#203 missing lib: an unreadable reader never fabricates completion" "$MARKER5"
assert_contains "#203 missing lib: the degrade is named, not silent" \
  "$ERR5" "task-utils.sh unavailable"
teardown_temp_dir

rm -f "$NC_ERR"

report_results
