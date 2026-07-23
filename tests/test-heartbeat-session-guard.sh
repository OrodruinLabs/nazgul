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

# --- Test 3: genuinely-unknown provider fails closed ("github" is now supported) ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true | .automation.heartbeat.inbox.provider = "linear"'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_file_exists "unsupported-provider: log file written" "$LOG"
assert_json_field "unsupported-provider: decision is skipped" "$LOG" '.decision' "skipped"
assert_json_field "unsupported-provider: reason names the provider" "$LOG" '.reason' "unsupported_provider:linear"
assert_json_field "unsupported-provider: no candidate picked" "$LOG" '.picked' "null"
teardown_temp_dir

# --- Test 4: provider unset -> defaults to "file", normal triage still runs ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true | .automation.heartbeat.inbox.provider = "file"'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
mkdir -p "$TEST_DIR/nazgul/sessions"
echo '{"pid":"1","session":"s1","started":"now"}' > "$TEST_DIR/nazgul/sessions/s1.lock"
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_json_field "file-provider: triage still runs (picked candidate)" "$LOG" '.picked' "cand.json"
teardown_temp_dir

# --- Test 5: MF-039 — atomic mkdir claim; two overlapping ticks, exactly one
# proceeds to _hb_start. The recorder sleeps before recording, mirroring the
# real gap between _hb_start's claude -p launch and the new session's own
# SessionStart hook registering nazgul/sessions/*.lock — the exact TOCTOU
# window count_active_sessions alone could not close.
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"

RECORDER="$TEST_DIR/recorder.sh"
START_LOG="$TEST_DIR/start-invocations.log"
cat > "$RECORDER" << EOF
#!/usr/bin/env bash
sleep 0.3
echo "\$1" >> "$START_LOG"
EOF
chmod +x "$RECORDER"

NAZGUL_HEARTBEAT_START_CMD="$RECORDER" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/heartbeat.sh" &
PID1=$!
NAZGUL_HEARTBEAT_START_CMD="$RECORDER" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/heartbeat.sh" &
PID2=$!
wait "$PID1"
wait "$PID2"

INVOCATIONS=0
[ -f "$START_LOG" ] && INVOCATIONS=$(wc -l < "$START_LOG" | tr -d ' ')
assert_eq "MF-039: exactly one overlapping tick proceeds to _hb_start" "$INVOCATIONS" "1"
assert_file_not_exists "MF-039: lock dir released after both ticks exit" "$TEST_DIR/nazgul/.heartbeat.lock"
teardown_temp_dir

report_results
