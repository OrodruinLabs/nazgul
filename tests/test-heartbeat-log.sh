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
# A live pid we own: board R3 made counting liveness-filtered, and pid 1 is alive
# but unsignalable (EPERM), so the old fixture stopped reading as an active session.
jq -cn --arg p "$$" '{pid:$p, session:"s1", started:"now"}' > "$TEST_DIR/nazgul/sessions/s1.lock"
NAZGUL_HEARTBEAT_START_CMD="true" bash "$REPO_ROOT/scripts/heartbeat.sh"
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
# just because `_hb_start ... || true` swallowed the failure. MF-044: a
# failed start must not leave the item silently and permanently sitting in
# archive/ indistinguishable from a real claim — it's relocated to a
# visibly distinct nazgul/inbox/failed/, and the log's archived_to reflects
# that real final location. ---
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
assert_eq "start-failed: archived_to points at the failed/ relocation (MF-044)" \
  "$(line_field "$LOG" 1 '.archived_to')" "nazgul/inbox/failed/cand.json"
assert_file_not_exists "start-failed: candidate no longer sitting in archive/ (MF-044)" \
  "$TEST_DIR/nazgul/inbox/archive/cand.json"
assert_file_exists "start-failed: candidate relocated to failed/ (MF-044)" \
  "$TEST_DIR/nazgul/inbox/failed/cand.json"
teardown_temp_dir

# --- skipped/stack_cap_reached (TASK-008): open layers at cap, a non-rework
# candidate picked -> record extends the `skipped` decision with the new
# reason value; every other field shape matches the existing skip paths ---
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-fakebin-XXXXXX")
cat > "$FAKEBIN/gh" << 'EOF'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  extension)
    [ "${1:-}" = "list" ] && { printf 'gh stack\tgithub/gh-stack\tv0.1.0\n'; exit 0; }
    exit 1 ;;
  auth)
    [ "${1:-}" = "status" ] && exit 0
    exit 1 ;;
  pr)
    [ "${1:-}" = "view" ] && { printf '{"number":1,"state":"OPEN","mergedAt":null,"reviewDecision":null,"reviews":[]}\n'; exit 0; }
    exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"

setup_temp_dir
setup_nazgul_dir
create_config '.automation.heartbeat.enabled = true'
jq '.execution.stacking.enabled = true
  | .execution.stacking.max_unmerged = 1
  | .stack.layers = [{feat_id:"FEAT-800", branch:"feat/FEAT-800-x", pr:"https://github.com/o/r/pull/800", base:"main", state:"open", opened_at:"2026-08-02T00:00:00Z", merged_at:null}]
' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
  && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
mkdir -p "$TEST_DIR/nazgul/inbox"
jq -n '{title:"FEAT-999 test objective", body:"do the thing", priority:5, type:"feature"}' > "$TEST_DIR/nazgul/inbox/cand.json"
PATH="$FAKEBIN:$PATH" NAZGUL_HEARTBEAT_START_CMD="true" bash "$REPO_ROOT/scripts/heartbeat.sh"
LOG=$(latest_log)
assert_valid_ndjson "stack_cap_reached" "$LOG" 1
assert_eq "stack_cap_reached: decision" "$(line_field "$LOG" 1 '.decision')" "skipped"
assert_eq "stack_cap_reached: reason" "$(line_field "$LOG" 1 '.reason')" "stack_cap_reached"
assert_eq "stack_cap_reached: picked" "$(line_field "$LOG" 1 '.picked')" "cand.json"
assert_eq "stack_cap_reached: seen is 1" "$(line_field "$LOG" 1 '.seen')" "1"
assert_eq "stack_cap_reached: session_active false" "$(line_field "$LOG" 1 '.session_active')" "false"
assert_eq "stack_cap_reached: started is false" "$(line_field "$LOG" 1 '.started')" "false"
assert_eq "stack_cap_reached: archived_to is null" "$(line_field "$LOG" 1 '.archived_to')" "null"
teardown_temp_dir
rm -rf "$FAKEBIN"

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
