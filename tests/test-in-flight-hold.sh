#!/usr/bin/env bash
set -uo pipefail
# Test: stop-hook in-flight awareness — writer, clearer, hold, stale
# fail-open, kill-switch (nazgul/inbox/stop-hook-blind-in-flight-iteration-burn.md, ADR-015)

TEST_NAME="test-in-flight-hold"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

WRITER="$REPO_ROOT/scripts/in-flight-marker.sh"
CLEARER="$REPO_ROOT/scripts/subagent-stop.sh"
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# <path> <agent> <unit> <epoch>
_write_marker() {
  jq -cn --arg a "$2" --arg u "$3" --argjson e "$4" \
    '{agent:$a, unit:$u, dispatched_at:"2026-08-01T00:00:00Z", dispatched_at_epoch:$e, prompt_head:("NAZGUL_UNIT: "+$u)}' > "$1"
}

# === Writer: scripts/in-flight-marker.sh (never blocks) ===

setup_temp_dir
setup_nazgul_dir
create_config
PAYLOAD=$(jq -cn '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:"NAZGUL_UNIT: TASK-001 do work"}}')
printf '%s' "$PAYLOAD" | bash "$WRITER" >/dev/null 2>&1; EC=$?
assert_exit_code "writer: valid Agent dispatch exits 0" "$EC" 0
MARKER_COUNT=$(find "$TEST_DIR/nazgul/in-flight" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "writer: exactly one marker written" "$MARKER_COUNT" "1"
MARKER_FILE=$(find "$TEST_DIR/nazgul/in-flight" -type f | head -1)
assert_eq "writer: marker agent field" "$(jq -r '.agent' "$MARKER_FILE")" "nazgul:implementer"
assert_eq "writer: marker unit field" "$(jq -r '.unit' "$MARKER_FILE")" "TASK-001"
assert_contains "writer: marker prompt_head carries the prompt prefix" "$(jq -r '.prompt_head' "$MARKER_FILE")" "NAZGUL_UNIT"
EPOCH_OK=$([ "$(jq -r '.dispatched_at_epoch' "$MARKER_FILE")" -gt 0 ] 2>/dev/null && echo yes || echo no)
assert_eq "writer: dispatched_at_epoch is a positive number" "$EPOCH_OK" "yes"
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
printf 'not json' | bash "$WRITER" >/dev/null 2>&1; EC=$?
assert_exit_code "writer: malformed payload exits 0 (never blocks)" "$EC" 0
assert_dir_not_exists "writer: malformed payload writes no marker" "$TEST_DIR/nazgul/in-flight"
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
printf '' | bash "$WRITER" >/dev/null 2>&1; EC=$?
assert_exit_code "writer: empty payload exits 0 (never blocks)" "$EC" 0
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
PAYLOAD=$(jq -cn '{tool_name:"Bash",tool_input:{command:"ls"}}')
printf '%s' "$PAYLOAD" | bash "$WRITER" >/dev/null 2>&1; EC=$?
assert_exit_code "writer: non-Agent tool exits 0" "$EC" 0
assert_dir_not_exists "writer: non-Agent tool writes no marker" "$TEST_DIR/nazgul/in-flight"
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
rm -f "$TEST_DIR/nazgul/config.json"
PAYLOAD=$(jq -cn '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:"NAZGUL_UNIT: TASK-001"}}')
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$WRITER" >/dev/null 2>&1; EC=$?
assert_exit_code "writer: missing config exits 0 (fail-open)" "$EC" 0
teardown_temp_dir

# === Hold: scripts/stop-hook.sh ===

# Fresh marker -> allowed stop, ONE stop_gate/in_flight_hold event naming the
# unit, current_iteration and safety.consecutive_failures byte-identical.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5' '.safety.consecutive_failures = 2'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)"
BEFORE_ITER=$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")
BEFORE_FAIL=$(jq -r '.safety.consecutive_failures' "$TEST_DIR/nazgul/config.json")
run_hook
assert_exit_code "hold taken: exit 0 (allowed stop)" "$HOOK_EC" 0
assert_contains "hold taken: stderr names the waited-on unit" "$HOOK_OUTPUT" "TASK-001"
EVENT_COUNT=$(grep -c '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null); EVENT_COUNT="${EVENT_COUNT:-0}"
assert_eq "hold taken: exactly one in_flight_hold event" "$EVENT_COUNT" "1"
GATE_LINE=$(grep '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" | tail -1)
assert_contains "hold taken: event names TASK-001" "$GATE_LINE" "TASK-001"
AFTER_ITER=$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")
AFTER_FAIL=$(jq -r '.safety.consecutive_failures' "$TEST_DIR/nazgul/config.json")
assert_eq "hold taken: current_iteration byte-identical" "$AFTER_ITER" "$BEFORE_ITER"
assert_eq "hold taken: safety.consecutive_failures byte-identical" "$AFTER_FAIL" "$BEFORE_FAIL"
teardown_temp_dir

# Kill-switch off -> fresh marker does not gate; normal block behavior.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.guards.in_flight_hold = false'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)"
run_hook
assert_exit_code "kill-switch off: exit 2 (normal block, hold not taken)" "$HOOK_EC" 2
EVENT_COUNT=$(grep -c '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null); EVENT_COUNT="${EVENT_COUNT:-0}"
assert_eq "kill-switch off: no in_flight_hold event" "$EVENT_COUNT" "0"
teardown_temp_dir

# Stale marker -> hold NOT taken: loud stderr, distinguishable telemetry,
# loop proceeds normally (exit 2, iteration increments).
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
STALE_EPOCH=$(( $(date +%s) - (31 * 60) ))
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$STALE_EPOCH"
run_hook
assert_exit_code "stale marker: exit 2 (hold not taken, normal iteration)" "$HOOK_EC" 2
assert_contains "stale marker: loud stderr line" "$HOOK_OUTPUT" "STALE in-flight marker"
STALE_EVENT_COUNT=$(grep -c '"reason":"in_flight_stale"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null); STALE_EVENT_COUNT="${STALE_EVENT_COUNT:-0}"
assert_eq "stale marker: distinguishable telemetry emitted" "$STALE_EVENT_COUNT" "1"
AFTER_ITER=$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")
assert_eq "stale marker: current_iteration DID increment" "$AFTER_ITER" "6"
assert_file_exists "stale marker: retained on disk, not silently deleted (diagnosable)" "$TEST_DIR/nazgul/in-flight/marker-1.json"
teardown_temp_dir

# Custom stale bound, floored to >= 1 minute.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.guards.in_flight_stale_minutes = 0'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(( $(date +%s) - 90 ))"
run_hook
assert_exit_code "stale bound floored to >=1 min: 90s-old marker is stale (exit 2)" "$HOOK_EC" 2
teardown_temp_dir

# Malformed (non-numeric string) guards.in_flight_stale_minutes must never
# crash the stop-hook; falls back to the 30-min default (fresh marker holds).
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.guards.in_flight_stale_minutes = "garbage"'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)"
run_hook
CRASH_SAFE=$([ "$HOOK_EC" = "0" ] || [ "$HOOK_EC" = "2" ] && echo yes || echo no)
assert_eq "malformed stale_minutes (string): never a bash fatal (exit 0 or 2)" "$CRASH_SAFE" "yes"
assert_exit_code "malformed stale_minutes (string): falls back to 30-min default (fresh marker holds, exit 0)" "$HOOK_EC" 0
teardown_temp_dir

# Fractional guards.in_flight_stale_minutes must never crash the stop-hook
# (bash integer arithmetic on a float would abort under set -e); falls back
# to the 30-min default.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.guards.in_flight_stale_minutes = 30.5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)"
run_hook
CRASH_SAFE=$([ "$HOOK_EC" = "0" ] || [ "$HOOK_EC" = "2" ] && echo yes || echo no)
assert_eq "malformed stale_minutes (fractional): never a bash fatal (exit 0 or 2)" "$CRASH_SAFE" "yes"
assert_exit_code "malformed stale_minutes (fractional): falls back to 30-min default (fresh marker holds, exit 0)" "$HOOK_EC" 0
teardown_temp_dir

# === Clear: scripts/subagent-stop.sh ===

setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)"
PAYLOAD=$(jq -cn '{subagent_type:"nazgul:implementer"}')
printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1
MARKER_COUNT=$(find "$TEST_DIR/nazgul/in-flight" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq "clear: matching marker removed" "$MARKER_COUNT" "0"
assert_file_contains "clear: existing subagent_stop telemetry unchanged" "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"subagent_stop"'
teardown_temp_dir

# Cleared marker -> next Stop resumes normal dispatch behavior (exit 2, block).
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)"
PAYLOAD=$(jq -cn '{subagent_type:"nazgul:implementer"}')
printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1
run_hook
assert_exit_code "clear-then-resume: next stop-hook blocks normally (exit 2)" "$HOOK_EC" 2
assert_contains "clear-then-resume: normal dispatch instruction present" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-001"
teardown_temp_dir

# One completion clears the OLDEST matching marker only (fan-out pairing).
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/older.json" "nazgul:implementer" "TASK-001" "1000"
_write_marker "$TEST_DIR/nazgul/in-flight/newer.json" "nazgul:implementer" "TASK-002" "2000"
PAYLOAD=$(jq -cn '{subagent_type:"nazgul:implementer"}')
printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1
assert_file_not_exists "clear: oldest matching marker removed" "$TEST_DIR/nazgul/in-flight/older.json"
assert_file_exists "clear: newer matching marker survives (one clear = one dispatch)" "$TEST_DIR/nazgul/in-flight/newer.json"
teardown_temp_dir

# Non-matching agent -> no-op, no error.
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/other.json" "nazgul:review-gate" "TASK-003" "1000"
PAYLOAD=$(jq -cn '{subagent_type:"nazgul:implementer"}')
printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1; EC=$?
assert_exit_code "clear: no matching marker still exits cleanly" "$EC" 0
assert_file_exists "clear: non-matching agent marker untouched" "$TEST_DIR/nazgul/in-flight/other.json"
teardown_temp_dir

# Unit-aware pairing (PR #78 review): when the completing subagent's transcript
# names its NAZGUL_UNIT, the clear targets THAT unit's marker even when a
# same-agent marker is older — out-of-order completions never clear the wrong
# unit's marker.
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/older.json" "nazgul:implementer" "TASK-001" "1000"
_write_marker "$TEST_DIR/nazgul/in-flight/newer.json" "nazgul:implementer" "TASK-002" "2000"
TRANSCRIPT="$TEST_DIR/transcript.jsonl"
{ jq -cn '{type:"user", message:{content:"NAZGUL_UNIT: TASK-002\\n\\nImplement TASK-002 of the objective."}}'; jq -cn '{type:"assistant", message:{content:[{type:"text", text:"TASK-002 implemented; report delivered."}]}}'; } > "$TRANSCRIPT"
PAYLOAD=$(jq -cn --arg t "$TRANSCRIPT" '{subagent_type:"nazgul:implementer", agent_transcript_path:$t}')
printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1; EC=$?
assert_exit_code "unit-aware clear: exits cleanly" "$EC" 0
assert_file_not_exists "unit-aware clear: the COMPLETED unit's marker removed (not the oldest)" "$TEST_DIR/nazgul/in-flight/newer.json"
assert_file_exists "unit-aware clear: the other unit's marker survives" "$TEST_DIR/nazgul/in-flight/older.json"
teardown_temp_dir

# Unit-aware pairing fallback: transcript names a unit with NO matching marker
# -> agent-only oldest-match (one completion still clears one dispatch).
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/older.json" "nazgul:implementer" "TASK-001" "1000"
TRANSCRIPT="$TEST_DIR/transcript.jsonl"
{ jq -cn '{type:"user", message:{content:"NAZGUL_UNIT: TASK-099\\n\\nImplement TASK-099."}}'; jq -cn '{type:"assistant", message:{content:[{type:"text", text:"TASK-099 implemented; report delivered."}]}}'; } > "$TRANSCRIPT"
PAYLOAD=$(jq -cn --arg t "$TRANSCRIPT" '{subagent_type:"nazgul:implementer", agent_transcript_path:$t}')
printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1; EC=$?
assert_exit_code "unit-fallback clear: exits cleanly" "$EC" 0
assert_file_not_exists "unit-fallback clear: agent-only oldest still cleared" "$TEST_DIR/nazgul/in-flight/older.json"
teardown_temp_dir

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$WRITER" 2>/dev/null \
    && _pass "shellcheck clean: in-flight-marker.sh" \
    || _fail "shellcheck clean: in-flight-marker.sh" "shellcheck warnings found"
else
  _pass "shellcheck skipped (not installed): in-flight-marker.sh"
fi

report_results
