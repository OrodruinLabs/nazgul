#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test return codes/log content explicitly

# Test: heartbeat.sh — act half (claim+archive+auto-start), crash-safety, idempotency
TEST_NAME="test-heartbeat-idempotency"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

latest_log() {
  ls -1t "$TEST_DIR/nazgul/logs"/heartbeat-*.jsonl 2>/dev/null | head -1
}

last_line_field() {
  tail -n1 "$1" | jq -r "$2"
}

# Recorder start command: never launches a real loop, just appends its
# argument (the objective) to NAZGUL_TEST_START_LOG so tests can assert on
# invocation count/content.
write_recorder() {
  RECORDER="$TEST_DIR/recorder.sh"
  cat > "$RECORDER" << 'EOF'
#!/usr/bin/env bash
echo "$1" >> "$NAZGUL_TEST_START_LOG"
EOF
  chmod +x "$RECORDER"
}

invocation_count() {
  [ -f "$NAZGUL_TEST_START_LOG" ] || { echo 0; return; }
  wc -l < "$NAZGUL_TEST_START_LOG" | tr -d ' '
}

# --- Test 1: normal tick archives (not deletes) + starts exactly once ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:1}' > "$TEST_DIR/nazgul/inbox/cand.json"
write_recorder
export NAZGUL_HEARTBEAT_START_CMD="$RECORDER"
export NAZGUL_TEST_START_LOG="$TEST_DIR/starts.log"

bash "$REPO_ROOT/scripts/heartbeat.sh"

assert_file_not_exists "normal tick: candidate removed from active inbox" "$TEST_DIR/nazgul/inbox/cand.json"
assert_file_exists "normal tick: candidate archived (moved, not deleted)" "$TEST_DIR/nazgul/inbox/archive/cand.json"
LOG=$(latest_log)
assert_json_field "normal tick: decision is started" "$LOG" '.decision' "started"
assert_json_field "normal tick: started is true" "$LOG" '.started' "true"
assert_json_field "normal tick: archived_to" "$LOG" '.archived_to' "nazgul/inbox/archive/cand.json"
assert_eq "normal tick: start command invoked exactly once" "$(invocation_count)" "1"
assert_eq "normal tick: objective passed as data" "$(cat "$NAZGUL_TEST_START_LOG")" "FEAT-999 test objective"

# --- Test 1b: re-running the tick does not double-start (inbox now empty) ---
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG2=$(latest_log)
assert_eq "re-run: decision is nothing_actionable" "$(last_line_field "$LOG2" '.decision')" "nothing_actionable"
assert_eq "re-run: start command still invoked only once total" "$(invocation_count)" "1"
assert_file_exists "re-run: archived candidate still present (not lost)" "$TEST_DIR/nazgul/inbox/archive/cand.json"

unset NAZGUL_HEARTBEAT_START_CMD NAZGUL_TEST_START_LOG
teardown_temp_dir

# --- Test 2: simulated crash between claim (archive) and start ---
setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-998 crash objective", body:"do the other thing", priority:1}' > "$TEST_DIR/nazgul/inbox/crash-cand.json"
write_recorder
export NAZGUL_TEST_START_LOG="$TEST_DIR/starts.log"

# Simulate the crashed tick directly: perform only the claim (archive) half,
# as scripts/lib/inbox-provider.sh's inbox_archive does inside heartbeat.sh,
# without ever invoking the start command — mimicking a process killed
# between the archive mv and the auto-start call.
# shellcheck source=../scripts/lib/inbox-provider.sh
source "$REPO_ROOT/scripts/lib/inbox-provider.sh"
inbox_archive "$TEST_DIR/nazgul/inbox" "crash-cand.json"
CRASH_EC=$?
assert_exit_code "simulated crash: claim/archive itself succeeds" "$CRASH_EC" 0
assert_file_not_exists "simulated crash: candidate gone from active inbox" "$TEST_DIR/nazgul/inbox/crash-cand.json"
assert_file_exists "simulated crash: candidate archived (not lost)" "$TEST_DIR/nazgul/inbox/archive/crash-cand.json"
assert_eq "simulated crash: start never invoked" "$(invocation_count)" "0"

# Recovery: the next tick must not repick/re-start the already-archived item.
export NAZGUL_HEARTBEAT_START_CMD="$RECORDER"
bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG3=$(latest_log)
assert_json_field "recovery tick: decision is nothing_actionable" "$LOG3" '.decision' "nothing_actionable"
assert_eq "recovery tick: start still never invoked" "$(invocation_count)" "0"
assert_file_exists "recovery tick: archived candidate still present exactly once" "$TEST_DIR/nazgul/inbox/archive/crash-cand.json"

unset NAZGUL_HEARTBEAT_START_CMD NAZGUL_TEST_START_LOG
teardown_temp_dir

report_results
