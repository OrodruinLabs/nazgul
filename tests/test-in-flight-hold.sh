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

# <path> <agent> <unit> <epoch> [background] [named]
_write_marker() {
  jq -cn --arg a "$2" --arg u "$3" --argjson e "$4" \
    --arg bg "${5:-missing}" --arg nm "${6:-false}" \
    '{agent:$a, unit:$u, dispatched_at:"2026-08-01T00:00:00Z", dispatched_at_epoch:$e, prompt_head:("NAZGUL_UNIT: "+$u), background:$bg, named:$nm}' > "$1"
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
assert_eq "writer: background field is 'missing' when payload lacks it" "$(jq -r '.background' "$MARKER_FILE")" "missing"
assert_eq "writer: named field is 'false' when payload lacks a name" "$(jq -r '.named' "$MARKER_FILE")" "false"
teardown_temp_dir

# --- dispatch-class capture: explicit background + named dispatch ---
setup_temp_dir
setup_nazgul_dir
create_config
PAYLOAD=$(jq -cn '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:"NAZGUL_UNIT: TASK-003 x",run_in_background:true,name:"helper"}}')
(cd "$TEST_DIR" && printf '%s' "$PAYLOAD" | bash "$WRITER" >/dev/null 2>&1) || true
MARKER_FILE=$(find "$TEST_DIR/nazgul/in-flight" -type f | head -1)
assert_eq "writer: background captured as 'true'" "$(jq -r '.background' "$MARKER_FILE")" "true"
assert_eq "writer: background is a JSON string, not a boolean" "$(jq -r '.background|type' "$MARKER_FILE")" "string"
assert_eq "writer: named captured as 'true'" "$(jq -r '.named' "$MARKER_FILE")" "true"
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
PAYLOAD=$(jq -cn '{tool_name:"Agent",tool_input:{subagent_type:"nazgul:implementer",prompt:"NAZGUL_UNIT: TASK-004 x",run_in_background:false}}')
(cd "$TEST_DIR" && printf '%s' "$PAYLOAD" | bash "$WRITER" >/dev/null 2>&1) || true
MARKER_FILE=$(find "$TEST_DIR/nazgul/in-flight" -type f | head -1)
assert_eq "writer: background captured as 'false'" "$(jq -r '.background' "$MARKER_FILE")" "false"
assert_eq "writer: 'false' is a JSON string — a boolean would be swallowed by the consumer's // default and misread as unobservable" "$(jq -r '.background|type' "$MARKER_FILE")" "string"
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
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "true"
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
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "true"
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
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "true"
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
_write_marker "$TEST_DIR/nazgul/in-flight/marker-1.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "true"
run_hook
CRASH_SAFE=$([ "$HOOK_EC" = "0" ] || [ "$HOOK_EC" = "2" ] && echo yes || echo no)
assert_eq "malformed stale_minutes (fractional): never a bash fatal (exit 0 or 2)" "$CRASH_SAFE" "yes"
assert_exit_code "malformed stale_minutes (fractional): falls back to 30-min default (fresh marker holds, exit 0)" "$HOOK_EC" 0
teardown_temp_dir

# --- classification: a fresh FOREGROUND marker is a leak, never a hold ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/fg.json" "nazgul:implementer" "TASK-001" "$NOW" "false"
run_hook
assert_file_not_exists "hold: fresh foreground marker is moved out of in-flight/" "$TEST_DIR/nazgul/in-flight/fg.json"
assert_file_exists "hold: quarantined under in-flight/quarantine/" "$TEST_DIR/nazgul/in-flight/quarantine/fg.json"
assert_contains "hold: stop_gate reason in_flight_orphan emitted" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" "in_flight_orphan"
if grep -q '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null; then
  _fail "hold: NO in_flight_hold event for a foreground marker"
else
  _pass "hold: NO in_flight_hold event for a foreground marker"
fi
assert_not_contains "hold: a PROVEN foreground marker is never recorded as unverifiable" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" "in_flight_unverifiable"
teardown_temp_dir

# --- classification: 'missing' is not observable at write time, not foreground (#218) ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$NOW" "missing"
run_hook
# INVERTED DELIBERATELY (PR #223 review #11). This asserted that an unobservable class
# is quarantined "like foreground" — the defect, not the contract. `mv` is irreversible,
# every marker on a fork-mode host reaches this branch on the first Stop, and the
# dispatch is usually still RUNNING. Preserving it also keeps #218's fix possible, which
# reconciles these markers against the Stop payload's background_tasks[].
assert_file_not_exists "hold: an unobservable-class marker is NOT quarantined — it may belong to a running dispatch" "$TEST_DIR/nazgul/in-flight/quarantine/legacy.json"
assert_file_exists "hold: the unobservable-class marker is left in place for reconciliation (#218)" "$TEST_DIR/nazgul/in-flight/legacy.json"
assert_contains "hold: 'missing' emits stop_gate reason in_flight_unverifiable" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" '"reason":"in_flight_unverifiable"'
assert_not_contains "hold: 'missing' is NOT recorded as a proven orphan" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" "in_flight_orphan"
assert_contains "hold: 'missing' event carries the observed background value" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" '"background":"missing"'
assert_contains "hold: 'missing' stderr names the unobservable class" "$HOOK_OUTPUT" "background=missing"
assert_contains "hold: 'missing' stderr refuses the proven-residue claim" "$HOOK_OUTPUT" "not proven residue"
assert_contains "hold: 'missing' stderr states the marker was NOT quarantined" "$HOOK_OUTPUT" "NOT quarantined"
teardown_temp_dir

# --- classification: a named dispatch is proven regardless of an unobservable class ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/nm-legacy.json" "nazgul:implementer" "TASK-002" "$NOW" "missing" "true"
run_hook
assert_contains "hold: named + 'missing' stays a proven orphan" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" '"reason":"in_flight_orphan"'
assert_not_contains "hold: named + 'missing' is not unverifiable" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" "in_flight_unverifiable"
teardown_temp_dir

# --- classification: background=true still holds (exit 0 + in_flight_hold) ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/bg.json" "nazgul:implementer" "TASK-003" "$NOW" "true"
run_hook
assert_exit_code "hold: background marker still takes the uncounted hold" "$HOOK_EC" 0
assert_contains "hold: in_flight_hold event names the unit" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" "in_flight_hold"
assert_file_exists "hold: background marker NOT quarantined" "$TEST_DIR/nazgul/in-flight/bg.json"
teardown_temp_dir

# --- classification: a NAMED background dispatch never holds (teammate-shaped) ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/nm.json" "nazgul:implementer" "TASK-004" "$NOW" "true" "true"
run_hook
assert_file_exists "hold: named dispatch marker quarantined (report contract owns it)" "$TEST_DIR/nazgul/in-flight/quarantine/nm.json"
assert_contains "hold: named dispatch is a proven orphan, not unverifiable" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" '"reason":"in_flight_orphan"'
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

# One completion clears ONE dispatch: with no derivable unit the NEWEST agent
# match is the pair (#104 three-way contract) and the other marker survives.
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/older.json" "nazgul:implementer" "TASK-001" "1000"
_write_marker "$TEST_DIR/nazgul/in-flight/newer.json" "nazgul:implementer" "TASK-002" "2000"
PAYLOAD=$(jq -cn '{subagent_type:"nazgul:implementer"}')
printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1
# INVERTED DELIBERATELY (PR #223 review #3). Newest-first deleted the marker of the
# dispatch most likely STILL RUNNING: with two concurrent implementers, A completing
# removed B's fresh marker and B silently lost its hold. Oldest-first pairs a completion
# with the longest-outstanding dispatch, which is the one it most likely is.
assert_file_not_exists "clear: OLDEST agent match removed when no unit is derivable" "$TEST_DIR/nazgul/in-flight/older.json"
assert_file_exists "clear: the FRESHER marker survives — it likely belongs to a running dispatch" "$TEST_DIR/nazgul/in-flight/newer.json"
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

# Unit derived from a real jsonl transcript but matching NO marker -> clears
# NOTHING (#104): the marker present belongs to a different, still-live unit.
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
assert_file_exists "unit-fallback clear: unmatched unit clears nothing" "$TEST_DIR/nazgul/in-flight/older.json"
assert_file_contains "unit-fallback clear: emits clear_skipped_no_match" "$TEST_DIR/nazgul/logs/events.jsonl" "clear_skipped_no_match"
teardown_temp_dir

# --- #104: derived-but-unmatched clears NOTHING (cross-unit theft fix) ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/m1.json" "nazgul:implementer" "TASK-002" 1000
TRANSCRIPT="$TEST_DIR/transcript.jsonl"
printf 'NAZGUL_UNIT: TASK-001\n' > "$TRANSCRIPT"
PAYLOAD=$(jq -cn --arg t "$TRANSCRIPT" '{subagent_type:"nazgul:implementer",agent_transcript_path:$t}')
(cd "$TEST_DIR" && printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1) || true
assert_file_exists "clearer: derived-but-unmatched unit clears NOTHING" "$TEST_DIR/nazgul/in-flight/m1.json"
assert_contains "clearer: derived-but-unmatched emits clear_skipped_no_match" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" "clear_skipped_no_match"
teardown_temp_dir

# --- #104: underivable unit clears the NEWEST agent match, named ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/old.json" "nazgul:implementer" "TASK-001" 1000
_write_marker "$TEST_DIR/nazgul/in-flight/new.json" "nazgul:implementer" "TASK-009" 2000
PAYLOAD=$(jq -cn '{subagent_type:"nazgul:implementer"}')
(cd "$TEST_DIR" && printf '%s' "$PAYLOAD" | bash "$CLEARER" >/dev/null 2>&1) || true
# INVERTED DELIBERATELY (PR #223 review #3) — see the rationale above.
assert_file_not_exists "clearer: underivable clears the OLDEST marker" "$TEST_DIR/nazgul/in-flight/old.json"
assert_file_exists "clearer: underivable KEEPS the newest — a running dispatch must not lose its hold" "$TEST_DIR/nazgul/in-flight/new.json"
assert_contains "clearer: underivable emits clear_fallback_underivable" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" "clear_fallback_underivable"
teardown_temp_dir

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$WRITER" 2>/dev/null \
    && _pass "shellcheck clean: in-flight-marker.sh" \
    || _fail "shellcheck clean: in-flight-marker.sh" "shellcheck warnings found"
else
  _skip "shellcheck skipped (not installed): in-flight-marker.sh"
fi

report_results
