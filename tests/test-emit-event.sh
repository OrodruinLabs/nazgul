#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-emit-event"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

EMIT_LIB="$REPO_ROOT/scripts/lib/emit-event.sh"
EMIT_CLI="$REPO_ROOT/scripts/emit-event-cli.sh"

# Helper: source the emit lib with an isolated test fixture.
# Caller sets: TEST_DIR, NAZGUL_DIR, EVENTS_FILE, CURRENT_ITERATION as needed.
_source_emit_lib() {
  # Reset any previously-defined emit_event from prior test in the same process
  unset -f emit_event 2>/dev/null || true
  # Reset globals the lib sets at source time
  unset EMIT_SCHEMA_VERSION EVENTS_FILE 2>/dev/null || true
  unset _EMIT_BUS_ENABLED _EMIT_HAS_FLOCK _EMIT_DIR_READY 2>/dev/null || true
  # shellcheck source=../scripts/lib/emit-event.sh
  source "$EMIT_LIB"
}

# --- Test 1: valid one-line JSON with expected envelope fields ---
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
# Provide a minimal config.json so bus_enabled check passes
printf '{"telemetry":{"bus_enabled":true}}' > "$TEST_DIR/nazgul/config.json"
export CURRENT_ITERATION=3
_source_emit_lib
emit_event "test_event" task_id "TASK-001"
line=$(tail -1 "$EVENTS_FILE")
assert_contains "valid JSON parses with jq" "$(echo "$line" | jq . 2>/dev/null)" "test_event"
assert_contains "envelope has sv field" "$line" '"sv"'
assert_contains "envelope has ts field"  "$line" '"ts"'
assert_contains "envelope has event field" "$line" '"event"'
assert_contains "envelope has iteration field" "$line" '"iteration"'
teardown_temp_dir

# --- Test 2: :n suffix -> numeric value (--argjson), plain key -> string (--arg) ---
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
printf '{"telemetry":{"bus_enabled":true}}' > "$TEST_DIR/nazgul/config.json"
export CURRENT_ITERATION=1
_source_emit_lib
emit_event "reviewer_verdict" confidence:n "92" decision "APPROVE"
line=$(tail -1 "$EVENTS_FILE")
# confidence must be numeric JSON (no quotes)
numeric_val=$(echo "$line" | jq '.confidence' 2>/dev/null)
assert_eq "numeric :n value is integer" "$numeric_val" "92"
# decision must be a JSON string
str_val=$(echo "$line" | jq -r '.decision' 2>/dev/null)
assert_eq "plain key value is string" "$str_val" "APPROVE"
teardown_temp_dir

# --- Test 2b: MF-016 — malformed (non-numeric) :n value still records the
# event with `null` substituted, instead of the whole event being silently
# dropped by the caller's `|| true`. ---
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
printf '{"telemetry":{"bus_enabled":true}}' > "$TEST_DIR/nazgul/config.json"
export CURRENT_ITERATION=1
_source_emit_lib
emit_event "reviewer_verdict" confidence:n "not-a-number" decision "APPROVE"
assert_file_exists "MF-016: malformed numeric still writes events.jsonl" "$EVENTS_FILE"
line=$(tail -1 "$EVENTS_FILE")
assert_contains "MF-016: event line is valid JSON" "$(echo "$line" | jq . 2>/dev/null)" "reviewer_verdict"
confidence_val=$(echo "$line" | jq '.confidence' 2>/dev/null)
assert_eq "MF-016: malformed numeric substitutes JSON null" "$confidence_val" "null"
str_val2=$(echo "$line" | jq -r '.decision' 2>/dev/null)
assert_eq "MF-016: sibling non-numeric field unaffected" "$str_val2" "APPROVE"
teardown_temp_dir

# --- Test 3: ts is ISO-8601 UTC timestamp (library-stamped) ---
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
printf '{"telemetry":{"bus_enabled":true}}' > "$TEST_DIR/nazgul/config.json"
export CURRENT_ITERATION=2
_source_emit_lib
emit_event "compaction"
line=$(tail -1 "$EVENTS_FILE")
ts_val=$(echo "$line" | jq -r '.ts' 2>/dev/null)
# Must match YYYY-MM-DDTHH:MM:SSZ
if echo "$ts_val" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  _pass "ts is ISO-8601 UTC"
else
  _fail "ts is ISO-8601 UTC" "got: '$ts_val'"
fi
teardown_temp_dir

# --- Test 4: integer iteration when CURRENT_ITERATION is set ---
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
printf '{"telemetry":{"bus_enabled":true}}' > "$TEST_DIR/nazgul/config.json"
export CURRENT_ITERATION=7
_source_emit_lib
emit_event "iteration_boundary"
line=$(tail -1 "$EVENTS_FILE")
iter_val=$(echo "$line" | jq '.iteration' 2>/dev/null)
assert_eq "iteration is integer when CURRENT_ITERATION set" "$iter_val" "7"
teardown_temp_dir

# --- Test 5: null iteration when CURRENT_ITERATION is unset ---
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
printf '{"telemetry":{"bus_enabled":true}}' > "$TEST_DIR/nazgul/config.json"
unset CURRENT_ITERATION
_source_emit_lib
emit_event "subagent_stop"
line=$(tail -1 "$EVENTS_FILE")
iter_val=$(echo "$line" | jq '.iteration' 2>/dev/null)
assert_eq "iteration is null when CURRENT_ITERATION unset" "$iter_val" "null"
teardown_temp_dir

# --- Test 6: mkdir -p creates logs dir on demand ---
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
# Remove the logs dir to test mkdir -p
rm -rf "$TEST_DIR/nazgul/logs"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
printf '{"telemetry":{"bus_enabled":true}}' > "$TEST_DIR/nazgul/config.json"
export CURRENT_ITERATION=1
_source_emit_lib
emit_event "test_mkdir"
[ -d "$TEST_DIR/nazgul/logs" ] && _pass "logs dir created on demand" || _fail "logs dir created on demand" "directory not found: $TEST_DIR/nazgul/logs"
assert_file_exists "events.jsonl created on demand" "$EVENTS_FILE"
teardown_temp_dir

# --- Test 7: unset NAZGUL_DIR -> silent no-op (nothing written) ---
setup_temp_dir
export EVENTS_FILE="$TEST_DIR/events.jsonl"
unset NAZGUL_DIR
unset CURRENT_ITERATION 2>/dev/null || true
_source_emit_lib
emit_event "should_noop"
assert_file_not_exists "unset NAZGUL_DIR -> no file written" "$EVENTS_FILE"
teardown_temp_dir

# --- Test 8: bus_enabled:false -> silent no-op ---
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
printf '{"telemetry":{"bus_enabled":false}}' > "$TEST_DIR/nazgul/config.json"
export CURRENT_ITERATION=1
_source_emit_lib
emit_event "should_be_noop"
assert_file_not_exists "bus_enabled:false -> no file written" "$EVENTS_FILE"
teardown_temp_dir

# --- Test 9: 3 concurrent emitters -> exactly 3 valid non-interleaved lines ---
# This test exercises the flock-absent fallback path (O_APPEND atomicity).
# We unset flock from the PATH to force the fallback branch even on Linux.
setup_temp_dir
setup_nazgul_dir
export NAZGUL_DIR="$TEST_DIR/nazgul"
export EVENTS_FILE="$TEST_DIR/nazgul/logs/events.jsonl"
printf '{"telemetry":{"bus_enabled":true}}' > "$TEST_DIR/nazgul/config.json"
mkdir -p "$(dirname "$EVENTS_FILE")"

# Write a helper script that sources the lib and fires one emit.
# On macOS, flock is absent natively -> the O_APPEND fallback path runs.
# On Linux (flock present), we shadow it with a fake dir to force the fallback.
NOFLOCK_BIN="$TEST_DIR/noflock_bin"
mkdir -p "$NOFLOCK_BIN"
# Place a fake `flock` that is NOT executable (so command -v still returns it
# but exec fails) — safest approach: just no file, prepend dir to shadow real flock.
HELPER_SCRIPT="$TEST_DIR/emit_helper.sh"
cat > "$HELPER_SCRIPT" << HELPER_EOF
#!/usr/bin/env bash
set -euo pipefail
export NAZGUL_DIR="$NAZGUL_DIR"
export EVENTS_FILE="$EVENTS_FILE"
export CURRENT_ITERATION="\$1"
# Prepend a dir that has no flock binary; this hides system flock on Linux.
# On macOS flock is already absent. Either way the O_APPEND fallback runs.
export PATH="$NOFLOCK_BIN:\$PATH"
# shellcheck source=/dev/null
source "$EMIT_LIB"
emit_event "concurrent_test" emitter_id "\$1"
HELPER_EOF
chmod +x "$HELPER_SCRIPT"

# Fire 3 emitters in background, then wait
bash "$HELPER_SCRIPT" "1" &
bash "$HELPER_SCRIPT" "2" &
bash "$HELPER_SCRIPT" "3" &
wait

line_count=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
assert_eq "3 concurrent emitters -> 3 lines" "$line_count" "3"

# Each line must parse as valid JSON
bad_lines=0
while IFS= read -r line; do
  if ! echo "$line" | jq . >/dev/null 2>&1; then
    bad_lines=$((bad_lines + 1))
  fi
done < "$EVENTS_FILE"
assert_eq "all 3 lines are valid JSON (no interleave)" "$bad_lines" "0"

teardown_temp_dir

# --- Test 10: bash -n syntax check on emit-event.sh ---
bash -n "$EMIT_LIB" 2>/dev/null && _pass "bash -n clean: emit-event.sh" || _fail "bash -n clean: emit-event.sh" "syntax error in $EMIT_LIB"

# --- Test 11: bash -n syntax check on emit-event-cli.sh ---
bash -n "$EMIT_CLI" 2>/dev/null && _pass "bash -n clean: emit-event-cli.sh" || _fail "bash -n clean: emit-event-cli.sh" "syntax error in $EMIT_CLI"

# --- Test 12: shellcheck on emit-event.sh (warning-level, matching project convention) ---
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$EMIT_LIB" 2>/dev/null && _pass "shellcheck clean: emit-event.sh" || _fail "shellcheck clean: emit-event.sh" "shellcheck found issues in $EMIT_LIB"
else
  _pass "shellcheck skipped (not installed): emit-event.sh"
fi

# --- Test 13: shellcheck on emit-event-cli.sh (warning-level, matching project convention) ---
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$EMIT_CLI" 2>/dev/null && _pass "shellcheck clean: emit-event-cli.sh" || _fail "shellcheck clean: emit-event-cli.sh" "shellcheck found issues in $EMIT_CLI"
else
  _pass "shellcheck skipped (not installed): emit-event-cli.sh"
fi

report_results
