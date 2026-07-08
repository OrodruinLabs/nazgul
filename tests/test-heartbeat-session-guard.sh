#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test return codes/log content explicitly

# Test: heartbeat.sh — default-off no-op and the concurrency (session) guard
TEST_NAME="test-heartbeat-session-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

latest_log() {
  ls -1t "$TEST_DIR/nazgul/logs"/heartbeat-*.jsonl 2>/dev/null | head -1
}

# --- Test 1: enabled: false -> disabled no-op (default-off) ---
setup_temp_dir
setup_nazgul_dir
create_config
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_file_exists "disabled: log file written" "$LOG"
assert_json_field "disabled: decision is disabled" "$LOG" '.decision' "disabled"
assert_json_field "disabled: enabled is false" "$LOG" '.enabled' "false"
teardown_temp_dir

# --- Test 2: active session -> skipped/active_session no-op ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
mkdir -p "$TEST_DIR/nazgul/sessions"
echo '{"pid":"1","session":"s1","started":"now"}' > "$TEST_DIR/nazgul/sessions/s1.lock"
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_file_exists "active-session: log file written" "$LOG"
assert_json_field "active-session: decision is skipped" "$LOG" '.decision' "skipped"
assert_json_field "active-session: reason is active_session" "$LOG" '.reason' "active_session"
assert_json_field "active-session: picked candidate" "$LOG" '.picked' "cand.json"
assert_json_field "active-session: session_active true" "$LOG" '.session_active' "true"
teardown_temp_dir

report_results
