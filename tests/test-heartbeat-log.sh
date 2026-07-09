#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test return codes/log content explicitly

# Test: heartbeat.sh — decision record shape (one JSON object per tick,
# required fields present per decision value)
TEST_NAME="test-heartbeat-log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

latest_log() {
  ls -1t "$TEST_DIR/nazgul/logs"/heartbeat-*.jsonl 2>/dev/null | head -1
}

line_count() {
  wc -l < "$1" | tr -d ' '
}

line_field() {
  sed -n "${2}p" "$1" | jq -r "$3"
}

assert_valid_ndjson() {
  local label="$1" file="$2" expected_lines="$3"
  local count
  count=$(line_count "$file")
  assert_eq "$label: $expected_lines line(s) appended" "$count" "$expected_lines"
  local i=1
  while [ "$i" -le "$count" ]; do
    sed -n "${i}p" "$file" | jq -e . >/dev/null 2>&1
    assert_exit_code "$label: line $i is valid JSON" "$?" 0
    i=$((i + 1))
  done
}

# --- disabled: one line per tick, required fields present ---
setup_temp_dir
setup_nazgul_dir
create_config
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_valid_ndjson "disabled" "$LOG" 1
assert_eq "disabled: seen is 0" "$(line_field "$LOG" 1 '.seen')" "0"
assert_eq "disabled: triaged is empty array" "$(line_field "$LOG" 1 '.triaged')" "[]"
assert_eq "disabled: picked is null" "$(line_field "$LOG" 1 '.picked')" "null"
assert_eq "disabled: reason is null" "$(line_field "$LOG" 1 '.reason')" "null"
assert_eq "disabled: started is false" "$(line_field "$LOG" 1 '.started')" "false"
assert_eq "disabled: archived_to is null" "$(line_field "$LOG" 1 '.archived_to')" "null"
bash "$REPO_ROOT/scripts/heartbeat.sh"
assert_valid_ndjson "disabled: second tick" "$LOG" 2
teardown_temp_dir

# --- nothing_actionable: empty inbox ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_valid_ndjson "nothing_actionable" "$LOG" 1
assert_eq "nothing_actionable: decision" "$(line_field "$LOG" 1 '.decision')" "nothing_actionable"
assert_eq "nothing_actionable: seen is 0" "$(line_field "$LOG" 1 '.seen')" "0"
assert_eq "nothing_actionable: picked is null" "$(line_field "$LOG" 1 '.picked')" "null"
teardown_temp_dir

# --- skipped/active_session: candidate present, session lock present ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
mkdir -p "$TEST_DIR/nazgul/sessions"
echo '{"pid":"1","session":"s1","started":"now"}' > "$TEST_DIR/nazgul/sessions/s1.lock"
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_valid_ndjson "skipped" "$LOG" 1
assert_eq "skipped: decision" "$(line_field "$LOG" 1 '.decision')" "skipped"
assert_eq "skipped: reason" "$(line_field "$LOG" 1 '.reason')" "active_session"
assert_eq "skipped: picked" "$(line_field "$LOG" 1 '.picked')" "cand.json"
assert_eq "skipped: seen is 1" "$(line_field "$LOG" 1 '.seen')" "1"
assert_eq "skipped: session_active true" "$(line_field "$LOG" 1 '.session_active')" "true"
assert_eq "skipped: objective from title" "$(line_field "$LOG" 1 '.objective')" "FEAT-999 test objective"
teardown_temp_dir

# --- started: candidate present, no active session -> claim+archive+auto-start ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
NAZGUL_HEARTBEAT_START_CMD="true" bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_valid_ndjson "started" "$LOG" 1
assert_eq "started: decision" "$(line_field "$LOG" 1 '.decision')" "started"
assert_eq "started: picked" "$(line_field "$LOG" 1 '.picked')" "cand.json"
assert_eq "started: session_active false" "$(line_field "$LOG" 1 '.session_active')" "false"
assert_eq "started: started is true" "$(line_field "$LOG" 1 '.started')" "true"
assert_eq "started: archived_to" "$(line_field "$LOG" 1 '.archived_to')" "nazgul/inbox/archive/cand.json"
assert_file_not_exists "started: candidate removed from active inbox" "$TEST_DIR/nazgul/inbox/cand.json"
assert_file_exists "started: candidate moved into archive/" "$TEST_DIR/nazgul/inbox/archive/cand.json"
teardown_temp_dir

# --- started (start command fails): claim+archive still happened, but the
# decision record must say so honestly (started: false), not claim success
# just because `_hb_start ... || true` swallowed the failure ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
NAZGUL_HEARTBEAT_START_CMD="false" bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_valid_ndjson "start-failed" "$LOG" 1
assert_eq "start-failed: decision" "$(line_field "$LOG" 1 '.decision')" "started"
assert_eq "start-failed: reason" "$(line_field "$LOG" 1 '.reason')" "start_command_failed"
assert_eq "start-failed: started is false" "$(line_field "$LOG" 1 '.started')" "false"
assert_eq "start-failed: archived_to still recorded" "$(line_field "$LOG" 1 '.archived_to')" "nazgul/inbox/archive/cand.json"
assert_file_exists "start-failed: candidate still archived (claim happened)" "$TEST_DIR/nazgul/inbox/archive/cand.json"
teardown_temp_dir

# --- hard_stop: BLOCKED task, no inbox listing performed ---
setup_temp_dir
setup_nazgul_dir
create_task_file TASK-001 BLOCKED none
create_config '.automation.heartbeat.enabled = true'
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_valid_ndjson "hard_stop" "$LOG" 1
assert_eq "hard_stop: decision" "$(line_field "$LOG" 1 '.decision')" "hard_stop"
assert_eq "hard_stop: reason" "$(line_field "$LOG" 1 '.reason')" "blocked_task"
assert_eq "hard_stop: seen is 0" "$(line_field "$LOG" 1 '.seen')" "0"
teardown_temp_dir

report_results
