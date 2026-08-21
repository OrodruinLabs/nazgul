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

FIXTURES="$SCRIPT_DIR/fixtures"
WRITER="$REPO_ROOT/scripts/in-flight-marker.sh"
CLEARER="$REPO_ROOT/scripts/subagent-stop.sh"
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

# [stop-payload-json] — omitted or empty means NO payload on stdin, which is every pre-#218
# call site's behavior and the `unknown` classification arm.
run_hook() {
  if [ -n "${1:-}" ]; then
    HOOK_OUTPUT=$(printf '%s' "$1" | bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
  else
    HOOK_OUTPUT=$(bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
  fi
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

# === Observed classification: the Stop payload decides, not the write-time class (#218) ===

# P3 (C3/AC5) — a non-subagent entry is neither live nor present. It comes first because every
# disposition below is taken on counts this filter produces.
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "missing"
run_hook '{"hook_event_name":"Stop","background_tasks":[{"id":"s1","type":"shell","status":"running"},{"id":"t1","type":"teammate","status":"running"}]}'
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
P3_OBS=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_eq "P3: a running shell and a running teammate are counted as entries" \
  "$(printf '%s' "$P3_OBS" | jq -r '.entries' 2>/dev/null)" "2"
assert_eq "P3: neither is a subagent, so SUBAGENT_PRESENT is 0" \
  "$(printf '%s' "$P3_OBS" | jq -r '.subagents' 2>/dev/null)" "0"
assert_eq "P3: and neither is live whatever its own status says, so LIVE is 0" \
  "$(printf '%s' "$P3_OBS" | jq -r '.live' 2>/dev/null)" "0"
# SUBSTRING TRAP: in_flight_hold is a strict prefix of in_flight_hold_budget_exhausted, so only the
# field's closing quote makes this a negative about the hold rather than about its successor.
assert_not_contains "P3: a captured session's 10 polling shells must never hold the loop on itself" \
  "$EVENTS" '"reason":"in_flight_hold"'
assert_contains "P3: zero subagents present takes the detect-only empty-array disposition" \
  "$EVENTS" '"reason":"in_flight_orphan_candidate"'
assert_file_exists "P3: the candidate marker stays at its original path" "$TEST_DIR/nazgul/in-flight/legacy.json"
assert_file_not_exists "P3: a non-subagent payload quarantines nothing" "$TEST_DIR/nazgul/in-flight/quarantine/legacy.json"
# R4 canary: a renamed type label surfaces here as changed vocabulary, not as a silently dead filter.
assert_eq "P3: the observation names the DISTINCT types actually seen" \
  "$(printf '%s' "$P3_OBS" | jq -r '.types' 2>/dev/null)" "shell,teammate"
teardown_temp_dir

# P3 companion — the real shape P3 is named for: 16 in-flight entries, only 6 of them subagents.
# A count taken over entries rather than over the filtered set would report 16 here.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "missing"
run_hook "$(cat "$FIXTURES/stop-payload-synthetic/mixed-subagent-and-shell.json")"
# A dispatchable READY task is planted on purpose: without the hold this run blocks with exit 2, so
# exit 0 discriminates here instead of being the no-plan default.
assert_exit_code "P3 companion: 6 live subagents among 16 entries hold (exit 0)" "$HOOK_EC" 0
P3M_HOLD=$(grep '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_contains "P3 companion: the hold counts the 6 subagents, not the 16 entries" "$P3M_HOLD" '"live_subagents":6'
P3M_OBS=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_eq "P3 companion: entries / subagents / live stay three separate counts" \
  "$(printf '%s' "$P3M_OBS" | jq -r '[.entries,.subagents,.live]|join("/")' 2>/dev/null)" "16/6/6"
teardown_temp_dir

# P1 (keystone) — the REAL capture (2 running subagents + 1 shell) holds the very marker the
# payload-absent case above records as unverifiable. Same fixture, opposite disposition.
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$NOW" "missing"
run_hook "$(cat "$FIXTURES/stop-payload/stop-two-subagents-one-shell.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
assert_exit_code "P1: an observed live subagent holds an unobservable-class marker (exit 0)" "$HOOK_EC" 0
assert_contains "P1: stop_gate reason in_flight_hold is emitted" "$EVENTS" '"reason":"in_flight_hold"'
assert_file_exists "P1: the held marker is STILL in nazgul/in-flight/" "$TEST_DIR/nazgul/in-flight/legacy.json"
assert_file_not_exists "P1: the held marker is NOT quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/legacy.json"
assert_not_contains "P1: an observed liveness never degrades to in_flight_unverifiable" "$EVENTS" "in_flight_unverifiable"
HOLD_LINE=$(grep '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_contains "P1: the hold event counts the capture's 2 live subagents, not its 3 entries" "$HOLD_LINE" '"live_subagents":2'
assert_eq "P1: live_subagents is a JSON number, not a string" \
  "$(printf '%s' "$HOLD_LINE" | jq -r '.live_subagents | type' 2>/dev/null)" "number"
teardown_temp_dir

# P2 (ruling Q3) — an observed-EMPTY background_tasks[] is RECORDED, never acted on.
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$NOW" "missing"
QUAR_BEFORE=$(find "$TEST_DIR/nazgul/in-flight/quarantine" -type f 2>/dev/null | wc -l | tr -d ' ')
run_hook "$(cat "$FIXTURES/stop-payload-synthetic/background-tasks-empty.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
QUAR_AFTER=$(find "$TEST_DIR/nazgul/in-flight/quarantine" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_contains "P2: stop_gate reason in_flight_orphan_candidate is emitted" "$EVENTS" '"reason":"in_flight_orphan_candidate"'
assert_contains "P2: the candidate event names the evidence it rests on" "$EVENTS" '"evidence":"background_tasks_empty"'
assert_file_exists "P2: the candidate marker is still at its original path" "$TEST_DIR/nazgul/in-flight/legacy.json"
assert_file_not_exists "P2: the candidate marker is NOT quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/legacy.json"
assert_eq "P2: the quarantine/ file count is unchanged across the run" "$QUAR_AFTER" "$QUAR_BEFORE"
# SUBSTRING TRAP: in_flight_orphan is a strict PREFIX of in_flight_orphan_candidate, so this
# negative assertion must carry the compact-JSON field's closing quote or it matches the candidate.
assert_not_contains "P2: the PROVEN reason in_flight_orphan is NOT emitted (naming pin)" "$EVENTS" '"reason":"in_flight_orphan"'
assert_not_contains "P2: no hold is taken when no subagent is present" "$EVENTS" '"reason":"in_flight_hold"'
CAND_LINE=$(grep '"reason":"in_flight_orphan_candidate"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_eq "P2: the candidate event carries entries" "$(printf '%s' "$CAND_LINE" | jq -r '.entries' 2>/dev/null)" "0"
assert_eq "P2: the candidate event carries subagents_present" "$(printf '%s' "$CAND_LINE" | jq -r '.subagents_present' 2>/dev/null)" "0"
assert_eq "P2: the candidate event carries the observed types vocabulary" \
  "$(printf '%s' "$CAND_LINE" | jq -r '.types | type' 2>/dev/null)" "string"
assert_contains "P2: the candidate event names the unit it belongs to" "$CAND_LINE" "TASK-002"
teardown_temp_dir

# P2 negative pin — the new reason must not swallow the PROVEN class.
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/nm-legacy.json" "nazgul:implementer" "TASK-002" "$NOW" "missing" "true"
run_hook "$(cat "$FIXTURES/stop-payload-synthetic/background-tasks-empty.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
assert_contains "P2 negative: a NAMED marker keeps its proven in_flight_orphan disposition" "$EVENTS" '"reason":"in_flight_orphan"'
assert_file_exists "P2 negative: the proven-class marker is still quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/nm-legacy.json"
assert_not_contains "P2 negative: the proven class is never downgraded to a candidate" "$EVENTS" '"reason":"in_flight_orphan_candidate"'
teardown_temp_dir

# P5 (C3/AC7) — `jq -e 'has("background_tasks")'` gates every classification, so a truncation, a
# rename or a payload that never arrived degrades to the payload-absent arm. Asserted, not assumed.
P5_SCANNED=0
P5_SKIPPED=0
P5_CHECKED=0
P5_FINDINGS=0
P5_CASES=(
  'a literal non-JSON string|not_json|not json'
  'valid JSON without the key|field_absent|{"hook_event_name":"Stop"}'
  'a document truncated mid-read|not_json|{"hook_event_name":"Stop","background_tasks":[{"id":"a1","type":"subagent","status":"run'
  'an empty payload|no_stdin|'
)
for p5_case in "${P5_CASES[@]}"; do
  IFS='|' read -r p5_label p5_want_why p5_payload <<<"$p5_case"
  P5_SCANNED=$((P5_SCANNED + 1))
  setup_temp_dir
  setup_nazgul_dir
  create_config
  mkdir -p "$TEST_DIR/nazgul/in-flight"
  _write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "missing"
  HOOK_OUTPUT=$(printf '%s' "$p5_payload" | bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
  P5_CHECKED=$((P5_CHECKED + 1))
  EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
  P5_OBS=$(printf '%s\n' "$EVENTS" | grep '"event":"stop_payload_observed"' | tail -1)
  # A bash fatal is neither of the hook's two documented outcomes, so it is named as itself.
  case "$HOOK_EC" in 0|2) p5_exit="safe" ;; *) p5_exit="fatal($HOOK_EC)" ;; esac
  p5_marker="absent"; [ -f "$TEST_DIR/nazgul/in-flight/legacy.json" ] && p5_marker="present"
  p5_quar="present"; [ -f "$TEST_DIR/nazgul/in-flight/quarantine/legacy.json" ] || p5_quar="absent"
  p5_unver="no"; case "$EVENTS" in *'"reason":"in_flight_unverifiable"'*) p5_unver="yes" ;; esac
  # Both negatives carry the closing quote: in_flight_hold and in_flight_orphan are each a strict
  # prefix of a longer reason token this suite also emits.
  p5_hold="no"; case "$EVENTS" in *'"reason":"in_flight_hold"'*) p5_hold="yes" ;; esac
  p5_cand="no"; case "$EVENTS" in *'"reason":"in_flight_orphan_candidate"'*) p5_cand="yes" ;; esac
  p5_why=$(printf '%s' "$P5_OBS" | jq -r '.why // "ABSENT"' 2>/dev/null)
  p5_seen=$(printf '%s' "$P5_OBS" | jq -r '.bg_seen // "ABSENT"' 2>/dev/null)
  P5_GOT="exit=$p5_exit why=${p5_why:-NONE} bg_seen=${p5_seen:-NONE} marker=$p5_marker quarantine=$p5_quar unverifiable=$p5_unver hold=$p5_hold candidate=$p5_cand"
  P5_WANT="exit=safe why=$p5_want_why bg_seen=unknown marker=present quarantine=absent unverifiable=yes hold=no candidate=no"
  assert_eq "P5 ($p5_label): the payload-absent disposition, and the arm records WHY it got there" "$P5_GOT" "$P5_WANT"
  [ "$P5_GOT" = "$P5_WANT" ] || P5_FINDINGS=$((P5_FINDINGS + 1))
  teardown_temp_dir
done
assert_eq "P5 accounting: scanned == skipped + checked" "$P5_SCANNED" "$((P5_SKIPPED + P5_CHECKED))"
assert_eq "P5 floor: the enumerated payload set is not empty" \
  "$([ "$P5_CHECKED" -gt 0 ] && echo yes || echo no)" "yes"
assert_eq "P5: $P5_SCANNED scanned, $P5_SKIPPED skipped, $P5_CHECKED checked — every malformed payload degraded to today's behavior" \
  "$P5_FINDINGS" "0"

# P8 (§8, #211 in effect) — observed liveness is consulted BEFORE the freshness cutoff, so a stale
# bound can never decline a hold for a session that HAS a live subagent.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/stale.json" "nazgul:implementer" "TASK-001" "$(( $(date +%s) - (31 * 60) ))" "missing"
run_hook "$(cat "$FIXTURES/stop-payload/stop-two-subagents-one-shell.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
assert_exit_code "P8: an over-age marker still holds when a live subagent is observed (exit 0)" "$HOOK_EC" 0
assert_contains "P8: the hold is taken on the real capture" "$EVENTS" '"reason":"in_flight_hold"'
assert_not_contains "P8: the disposition does NOT collapse to in_flight_stale" "$EVENTS" '"reason":"in_flight_stale"'
assert_file_exists "P8: the over-age marker is left in place" "$TEST_DIR/nazgul/in-flight/stale.json"
assert_file_not_exists "P8: the over-age marker is not quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/stale.json"
assert_eq "P8: a held iteration is not burned" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "5"
teardown_temp_dir

# P8 (AC10) — the 30-minute default is #211's call, not this objective's: READ, never written.
assert_eq "P8: templates/config.json still carries guards.in_flight_stale_minutes 30" \
  "$(jq -r '.guards.in_flight_stale_minutes' "$REPO_ROOT/templates/config.json")" "30"

# P11 (ruling Q2) — the THIRD state: a subagent is PRESENT but its status is not one the allowlist
# recognises, so the tick can prove neither liveness nor absence and must act on neither.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "missing"
run_hook "$(cat "$FIXTURES/stop-payload-synthetic/unknown-status-queued.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
P11_OBS=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_not_contains "P11 (1): an unrecognised status is not proven live, so NO hold is taken" \
  "$EVENTS" '"reason":"in_flight_hold"'
assert_not_contains "P11 (2): a subagent IS present, so NO orphan candidate is filed either" \
  "$EVENTS" '"reason":"in_flight_orphan_candidate"'
assert_file_exists "P11 (3): the marker is preserved in nazgul/in-flight/" "$TEST_DIR/nazgul/in-flight/legacy.json"
assert_file_not_exists "P11 (3): the marker is not quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/legacy.json"
assert_exit_code "P11 (4): the run degrades to an ordinary blocked iteration (exit 2)" "$HOOK_EC" 2
assert_eq "P11 (4): ... and burns it — current_iteration increments" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "6"
assert_eq "P11 (5): the observation records the unrecognised status verbatim" \
  "$(printf '%s' "$P11_OBS" | jq -r '.statuses' 2>/dev/null)" "queued,running"
assert_eq "P11: present-but-unrecognised counts as PRESENT and as NOT live — the two-count shape" \
  "$(printf '%s' "$P11_OBS" | jq -r '[.entries,.subagents,.live]|join("/")' 2>/dev/null)" "2/1/0"
# Collapsing the third state into the unknown arm would re-emit the unobservable-class reason here,
# even though this payload was read and understood.
assert_not_contains "P11: an OBSERVED payload never degrades to the unverifiable arm" \
  "$EVENTS" '"reason":"in_flight_unverifiable"'
teardown_temp_dir

# P11 companion — the allowlist is pinned in BOTH directions, so a future narrowing to `running`
# alone is caught by a failing hold and not only by a failing negative.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "missing"
run_hook '{"hook_event_name":"Stop","background_tasks":[{"id":"p1","type":"subagent","status":"pending"}]}'
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
P11P_OBS=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_exit_code "P11 companion: a pending subagent counts as live (exit 0)" "$HOOK_EC" 0
assert_contains "P11 companion: and takes the hold" "$EVENTS" '"reason":"in_flight_hold"'
assert_eq "P11 companion: pending is counted in live, not merely present" \
  "$(printf '%s' "$P11P_OBS" | jq -r '[.subagents,.live]|join("/")' 2>/dev/null)" "1/1"
teardown_temp_dir

# === P10 (ruling Q1): the hold budget valve, bounded per marker set ===

# Every pin below is an equality on an extracted value, so the coverage line at the end
# counts checks that actually ran rather than checks that merely appeared.
P10_SCANNED=0
P10_SKIPPED=0
P10_CHECKED=0
P10_FINDINGS=0

_p10_check() {
  P10_SCANNED=$((P10_SCANNED + 1))
  P10_CHECKED=$((P10_CHECKED + 1))
  assert_eq "$1" "$2" "$3"
  [ "$2" = "$3" ] || P10_FINDINGS=$((P10_FINDINGS + 1))
}

# The reason field's closing quote is load-bearing here: in_flight_hold is a strict PREFIX of
# in_flight_hold_budget_exhausted, so a bare substring count would score the two as one.
_p10_hold_count() {
  local n
  n=$(grep -c '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
  printf '%s' "${n:-0}"
}

_p10_exhausted_count() {
  local n
  n=$(grep -c '"reason":"in_flight_hold_budget_exhausted"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
  printf '%s' "${n:-0}"
}

_p10_ledger_count() {
  find "$TEST_DIR/nazgul/logs/.in-flight-holds" -type f 2>/dev/null | wc -l | tr -d ' '
}

_p10_exhausted_line() {
  grep '"reason":"in_flight_hold_budget_exhausted"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1
}

# P10a/P10b/P10c share ONE fixture on purpose: exhaustion is only reachable by a second
# invocation against an unchanged set, and a fresh temp dir would reset the very ledger under test.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5' '.safety.consecutive_failures = 2'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/valve-a.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "missing"
P10_PAYLOAD='{"hook_event_name":"Stop","background_tasks":[{"id":"s1","type":"subagent","status":"running"}]}'
P10_CFG_BEFORE=$(cksum < "$TEST_DIR/nazgul/config.json")
run_hook "$P10_PAYLOAD"
_p10_check "P10a: a FIRST hold on a fresh marker set is permitted (exit 0)" "$HOOK_EC" "0"
_p10_check "P10a: exactly one in_flight_hold event" "$(_p10_hold_count)" "1"
_p10_check "P10a: and no exhaustion event on a first hold" "$(_p10_exhausted_count)" "0"
_p10_check "P10a: current_iteration byte-identical across the held run" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "5"
_p10_check "P10a: safety.consecutive_failures byte-identical across the held run" \
  "$(jq -r '.safety.consecutive_failures' "$TEST_DIR/nazgul/config.json")" "2"
_p10_check "P10a: an attempt ledger, never config state — the whole config.json is byte-identical" \
  "$(cksum < "$TEST_DIR/nazgul/config.json")" "$P10_CFG_BEFORE"
_p10_check "P10a: one ledger file under nazgul/logs/.in-flight-holds/" "$(_p10_ledger_count)" "1"
P10_LEDGER=$(find "$TEST_DIR/nazgul/logs/.in-flight-holds" -type f 2>/dev/null | head -1)
P10_LEDGER_BASE="${P10_LEDGER##*/}"
_p10_check "P10a: the ledger records the one hold taken" "$(cat "$P10_LEDGER" 2>/dev/null)" "1"
_p10_check "P10a: named by a 16-char hash — the _resume_attempts_file convention, not a new one" \
  "${#P10_LEDGER_BASE}" "16"

run_hook "$P10_PAYLOAD"
_p10_check "P10b: a SECOND hold on an UNCHANGED marker set is refused (exit 2, never exit 0)" "$HOOK_EC" "2"
_p10_check "P10b: still exactly one in_flight_hold event — no second hold was taken" "$(_p10_hold_count)" "1"
_p10_check "P10b: exactly one in_flight_hold_budget_exhausted event" "$(_p10_exhausted_count)" "1"
P10_EX=$(_p10_exhausted_line)
_p10_check "P10b: the event names the fingerprint that keys the ledger file" \
  "$(printf '%s' "$P10_EX" | jq -r '.fingerprint')" "$P10_LEDGER_BASE"
_p10_check "P10b: it carries holds_taken" "$(printf '%s' "$P10_EX" | jq -r '.holds_taken')" "1"
_p10_check "P10b: holds_taken is a JSON number, not a string" \
  "$(printf '%s' "$P10_EX" | jq -r '.holds_taken | type')" "number"
_p10_check "P10b: it carries the observed live_subagents count" \
  "$(printf '%s' "$P10_EX" | jq -r '.live_subagents')" "1"
_p10_check "P10b: it names the units it declined to hold on" \
  "$(printf '%s' "$P10_EX" | jq -r '.units')" "TASK-001"
_p10_check "P10b: a spent budget is distinguishable from an unwritable one" \
  "$(printf '%s' "$P10_EX" | jq -r '.ledger')" "spent"
_p10_check "P10b: current_iteration INCREMENTED — the fall-through really reached the increment" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "6"
_p10_check "P10b: the marker is left exactly where it was" \
  "$([ -f "$TEST_DIR/nazgul/in-flight/valve-a.json" ] && echo present || echo absent)" "present"
_p10_check "P10b: exhaustion quarantines nothing" \
  "$(find "$TEST_DIR/nazgul/in-flight/quarantine" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
_p10_check "P10b: the spent ledger is not driven past the cap" "$(cat "$P10_LEDGER" 2>/dev/null)" "1"

_write_marker "$TEST_DIR/nazgul/in-flight/valve-b.json" "nazgul:implementer" "TASK-009" "$(date +%s)" "missing"
run_hook "$P10_PAYLOAD"
_p10_check "P10c: a CHANGED marker set gets its own budget and holds again (exit 0)" "$HOOK_EC" "0"
_p10_check "P10c: a second in_flight_hold event, taken on the changed set" "$(_p10_hold_count)" "2"
_p10_check "P10c: and no second exhaustion" "$(_p10_exhausted_count)" "1"
_p10_check "P10c: the ledger gains a second, differently-named file — it keys on evidence, not a global counter" \
  "$(_p10_ledger_count)" "2"
_p10_check "P10c: the newly permitted hold burns no iteration" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "6"
teardown_temp_dir

# P10d — the `unknown` arm exhausts through the SAME code path. A valve that fired only on the
# payload-driven arm would be the second convention this task exists to avoid.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/valve-bg.json" "nazgul:implementer" "TASK-003" "$(date +%s)" "true"
run_hook
_p10_check "P10d: the unknown arm's FIRST hold is permitted (exit 0)" "$HOOK_EC" "0"
_p10_check "P10d: it is the same hold event, through the same exit" "$(_p10_hold_count)" "1"
_p10_check "P10d: the unknown arm writes a ledger file too" "$(_p10_ledger_count)" "1"
_p10_check "P10d: this really is the unknown arm, not a payload-driven one" \
  "$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1 | jq -r '.bg_seen')" "unknown"
run_hook
_p10_check "P10d: the second unchanged invocation exhausts exactly as P10b does (exit 2)" "$HOOK_EC" "2"
_p10_check "P10d: no second hold on the unknown arm either" "$(_p10_hold_count)" "1"
_p10_check "P10d: the same exhaustion reason — ONE code path, not two" "$(_p10_exhausted_count)" "1"
P10_EX=$(_p10_exhausted_line)
_p10_check "P10d: holds_taken on the unknown arm" "$(printf '%s' "$P10_EX" | jq -r '.holds_taken')" "1"
_p10_check "P10d: no liveness was observed on this arm, so live_subagents is 0" \
  "$(printf '%s' "$P10_EX" | jq -r '.live_subagents')" "0"
_p10_check "P10d: it names the background unit it declined" \
  "$(printf '%s' "$P10_EX" | jq -r '.units')" "TASK-003"
_p10_check "P10d: current_iteration increments on the exhausted run" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "6"
_p10_check "P10d: the background marker is never quarantined by exhaustion" \
  "$([ -f "$TEST_DIR/nazgul/in-flight/valve-bg.json" ] && echo present || echo absent)" "present"
teardown_temp_dir

# Prior-art conformance: _resume_attempts_file's hash-unavailable fallback, copied rather than
# reinvented. A failing shim reaches _rp_sha256's own failure branch without emptying PATH.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/valve-nh.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "true"
# setup_temp_dir's own TEST_DIR carries a colon, which a PATH entry cannot: putting the shims
# there would split the entry and silently test nothing.
P10_SHIM=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-p10-shim-XXXXXX")
printf '#!/bin/sh\nexit 1\n' > "$P10_SHIM/sha256sum"
printf '#!/bin/sh\nexit 1\n' > "$P10_SHIM/shasum"
chmod +x "$P10_SHIM/sha256sum" "$P10_SHIM/shasum"
_p10_check "prior art: the shim really is reachable — a PATH that never loaded it would prove nothing" \
  "$(PATH="$P10_SHIM:$PATH" command -v sha256sum)" "$P10_SHIM/sha256sum"
HOOK_OUTPUT=$(PATH="$P10_SHIM:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
rm -rf "$P10_SHIM"
_p10_check "prior art: an unusable sha256 never aborts the hook — the hold is still taken (exit 0)" "$HOOK_EC" "0"
_p10_check "prior art: it degrades to the named fallback ledger, as _resume_attempts_file does" \
  "$([ -f "$TEST_DIR/nazgul/logs/.in-flight-holds/fallback" ] && echo present || echo absent)" "present"
_p10_check "prior art: and says so on stderr rather than degrading silently" \
  "$(printf '%s' "$HOOK_OUTPUT" | grep -c 'in-flight hold ledger hash fallback')" "1"
teardown_temp_dir

# AC12: the cap lives in code, and this objective adds no schema surface at all.
_p10_check "config purity: _IN_FLIGHT_HOLD_CAP is a script constant in scripts/stop-hook.sh" \
  "$([ "$(grep -c '_IN_FLIGHT_HOLD_CAP=1' "$STOP_HOOK")" -ge 1 ] && echo present || echo absent)" "present"
_p10_check "config purity: it is NOT a config key" \
  "$(grep -ci 'in_flight_hold_cap' "$REPO_ROOT/templates/config.json")" "0"
_p10_check "config purity: the valve adds no guards key of its own" \
  "$(jq -r '.guards | has("in_flight_hold_cap")' "$REPO_ROOT/templates/config.json")" "false"
_p10_check "config purity: templates/config.json still reports schema_version 36" \
  "$(jq -r '.schema_version' "$REPO_ROOT/templates/config.json")" "36"

assert_eq "P10 accounting: scanned == skipped + checked" "$P10_SCANNED" "$((P10_SKIPPED + P10_CHECKED))"
assert_eq "P10 floor: the valve's pin set is not empty" \
  "$([ "$P10_CHECKED" -gt 0 ] && echo yes || echo no)" "yes"
assert_eq "P10: $P10_SCANNED scanned, $P10_SKIPPED skipped, $P10_CHECKED checked — every first hold permitted, every unchanged repeat refused" \
  "$P10_FINDINGS" "0"

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

# === P9 (C1) / P6 (C4) / P12a (ruling Q4): the bounded read and what it records ===
HOOK_STDIN_LIB="$REPO_ROOT/scripts/lib/hook-stdin.sh"

# timeout(1) is absent from stock macOS, so reuse the formatter.sh:218-221 ladder.
# Its bare fallback backgrounds and polls, so no pin here can hang the suite.
_bounded_run() {
  local _br_secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_br_secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$_br_secs" "$@"
    return $?
  fi
  "$@" &
  local _br_pid=$! _br_waited=0
  while [ "$_br_waited" -lt "$_br_secs" ] && kill -0 "$_br_pid" 2>/dev/null; do
    sleep 1
    _br_waited=$(( _br_waited + 1 ))
  done
  if kill -0 "$_br_pid" 2>/dev/null; then
    kill -9 "$_br_pid" 2>/dev/null
    wait "$_br_pid" 2>/dev/null
    return 124
  fi
  wait "$_br_pid"
}

# `tail -f /dev/null` feeding a fifo IS #155's never-EOF stdin, with a writer the
# test can reap; the literal pipeline can never be reaped, since tail never writes.
_never_eof_open() {
  rm -f "$1"
  mkfifo "$1"
  tail -f /dev/null > "$1" &
  NEVER_EOF_PID=$!
}

_never_eof_close() {
  kill "$NEVER_EOF_PID" 2>/dev/null
  wait "$NEVER_EOF_PID" 2>/dev/null
  rm -f "$1"
}

_run_hook_payload() {
  HOOK_OUTPUT=$(printf '%s' "$1" | bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# --- P9 (C1 unit, obligation AC-V1): read_hook_payload in isolation ---
assert_file_exists "P9/AC-V1: scripts/lib/hook-stdin.sh exists" "$HOOK_STDIN_LIB"
assert_file_contains "P9/AC-V1: it defines read_hook_payload" "$HOOK_STDIN_LIB" "read_hook_payload()"
assert_file_contains "AC-V1: stop-hook.sh sources it by absolute \$SCRIPT_DIR path" \
  "$STOP_HOOK" 'source "$SCRIPT_DIR/lib/hook-stdin.sh"'

# A sourced lib must not alter the caller's shell options (CLAUDE.md Code Style).
P9_SET_E=$(grep -cE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$HOOK_STDIN_LIB" || true)
assert_eq "P9: hook-stdin.sh carries no set -e" "$P9_SET_E" "0"

bash -n "$HOOK_STDIN_LIB" >/dev/null 2>&1
assert_exit_code "AC-V1: hook-stdin.sh is bash -n clean" "$?" 0

P9_READER='set -euo pipefail; source "$1"; read_hook_payload P; printf "[%s][%s]" "$P" "$HOOK_STDIN_WHY"'
P9_START=$(date +%s)
P9_OUT=$(_bounded_run 8 bash -c "$P9_READER" _ "$HOOK_STDIN_LIB" </dev/null 2>&1)
P9_EC=$?
P9_ELAPSED=$(( $(date +%s) - P9_START ))
assert_eq "P9: a /dev/null stdin yields an empty payload" "$P9_OUT" "[][no_stdin]"
assert_exit_code "P9: a caller under set -euo pipefail is never aborted by the read" "$P9_EC" 0
assert_eq "P9: /dev/null returns promptly (${P9_ELAPSED}s), never waiting out the bound" \
  "$([ "$P9_ELAPSED" -lt 2 ] && echo yes || echo no)" "yes"

P9_MULTI=$(printf '{\n  "hook_event_name": "Stop",\n  "background_tasks": [],\n  "tail_marker": "P9_LAST_LINE"\n}')
P9_OUT=$(printf '%s' "$P9_MULTI" | _bounded_run 8 bash -c 'set -euo pipefail; source "$1"; read_hook_payload P; printf "%s" "$P"' _ "$HOOK_STDIN_LIB" 2>&1)
assert_eq "P9: a pretty-printed multi-line payload comes back whole" "$P9_OUT" "$P9_MULTI"
assert_contains "P9: -d '' reaches the LAST line — truncation at the first newline is what this catches" \
  "$P9_OUT" "P9_LAST_LINE"

setup_temp_dir
P9_FIFO="$TEST_DIR/p9-never-eof"
_never_eof_open "$P9_FIFO"
P9_START=$(date +%s)
P9_OUT=$(_bounded_run 20 bash -c "$P9_READER" _ "$HOOK_STDIN_LIB" < "$P9_FIFO" 2>&1)
P9_EC=$?
P9_ELAPSED=$(( $(date +%s) - P9_START ))
_never_eof_close "$P9_FIFO"
assert_eq "P9: a never-EOF stdin returns at the bound, and says so — 'timed out' never collapses into 'no payload'" \
  "$P9_OUT" "[][read_timeout]"
assert_exit_code "P9: it returned on its own, not by the wrapper's kill" "$P9_EC" 0
assert_eq "P9: ... within its own bound (${P9_ELAPSED}s < 5s)" \
  "$([ "$P9_ELAPSED" -lt 5 ] && echo yes || echo no)" "yes"
teardown_temp_dir

# --- P6 (C4): the ANTI-HANG pin — #155's own reproduction inverted ---
setup_temp_dir
setup_nazgul_dir
create_config
P6_FIFO="$TEST_DIR/p6-never-eof"
_never_eof_open "$P6_FIFO"
P6_START=$(date +%s)
_bounded_run 20 bash "$STOP_HOOK" < "$P6_FIFO" >/dev/null 2>&1
P6_EC=$?
P6_ELAPSED=$(( $(date +%s) - P6_START ))
_never_eof_close "$P6_FIFO"
assert_eq "P6 (C4): stop-hook returns under a never-EOF stdin instead of deadlocking" \
  "$([ "$P6_EC" -ne 124 ] && echo returned || echo killed_by_wrapper)" "returned"
assert_eq "P6 (C4): ... in ${P6_ELAPSED}s, under the 5 s bound" \
  "$([ "$P6_ELAPSED" -lt 5 ] && echo yes || echo no)" "yes"
assert_contains "P6: the bounded read is recorded as read_timeout, not as an absent payload" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" '"why":"read_timeout"'
teardown_temp_dir

# The terminal test is the WRONG PREDICATE (#155) and must never be the SOLE guard:
# what closes the hazard is the -t bound, so pin the bound itself, not the guard.
P6_BOUNDED=$(grep -cE 'read .*-d .. -t "\$HOOK_STDIN_TIMEOUT"' "$HOOK_STDIN_LIB" || true)
assert_eq "P6 companion: the read carries a -t bound alongside its terminal test" "$P6_BOUNDED" "1"
P6_CAT_DRAIN=$(grep -vE '^[[:space:]]*#' "$HOOK_STDIN_LIB" | grep -cE '\$\(cat' || true)
assert_eq "P6 companion: no \$(cat) drain in the code — the header names that idiom only to forbid it" \
  "$P6_CAT_DRAIN" "0"

# --- P12a (ruling Q4): one observation event per invocation, on every arm ---
setup_temp_dir
setup_nazgul_dir
create_config
run_hook
_run_hook_payload 'this is not json at all'
_run_hook_payload '{"hook_event_name":"Stop","stop_hook_active":false}'
P12_OBS=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true)
P12_COUNT=$(printf '%s\n' "$P12_OBS" | grep -c 'stop_payload_observed' || true)
assert_eq "P12a: exactly one event per invocation — 3 invocations, 3 events" "$P12_COUNT" "3"
assert_eq "P12a: each unknown arm names its OWN reason" \
  "$(printf '%s\n' "$P12_OBS" | jq -r '.why // "ABSENT"' | tr '\n' ' ')" "no_stdin not_json field_absent "
P12_WHY_OUTSIDE=$(printf '%s\n' "$P12_OBS" | jq -r 'select(has("why")) | .why' \
  | grep -vcE '^(no_stdin|read_timeout|not_json|field_absent|no_jq)$' || true)
assert_eq "P12a: every why is drawn from the closed set" "$P12_WHY_OUTSIDE" "0"
assert_eq "P12a: an absent, unparseable or key-less payload falls to unknown, never to yes" \
  "$(printf '%s\n' "$P12_OBS" | jq -r '.bg_seen' | sort -u | tr '\n' ' ')" "unknown "
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
P12_PAYLOAD=$(jq -cn '{hook_event_name:"Stop",stop_hook_active:false,
  cwd:"/p12a/SECRET-cwd",transcript_path:"/p12a/SECRET-transcript.jsonl",
  agent_transcript_path:"/p12a/SECRET-agent.jsonl",
  last_assistant_message:"SECRET assistant prose",
  background_tasks:[{id:"a1",type:"subagent",status:"running",agent_type:"nazgul:doc-generator"},
                    {id:"b1",type:"shell",status:"running",description:"SECRET command string"}]}')
_run_hook_payload "$P12_PAYLOAD"
P12_OBS=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true)
P12_COUNT=$(printf '%s\n' "$P12_OBS" | grep -c 'stop_payload_observed' || true)
assert_eq "P12a: exactly one event on the yes arm too" "$P12_COUNT" "1"
assert_eq "P12a: bg_seen is yes when background_tasks is present" \
  "$(printf '%s' "$P12_OBS" | jq -r '.bg_seen')" "yes"
assert_eq "P12a: entries counts every background_tasks entry" \
  "$(printf '%s' "$P12_OBS" | jq -r '.entries')" "2"
assert_eq "P12a: subagents counts only type==subagent" \
  "$(printf '%s' "$P12_OBS" | jq -r '.subagents')" "1"
assert_eq "P12a: live counts running/pending subagents" \
  "$(printf '%s' "$P12_OBS" | jq -r '.live')" "1"
assert_eq "P12a: the three counts land as JSON numbers, not strings" \
  "$(printf '%s' "$P12_OBS" | jq -r '[.entries,.subagents,.live]|map(type)|unique|join(",")')" "number"
assert_eq "P12a: types carries the DISTINCT type vocabulary — R4's canary made mechanical" \
  "$(printf '%s' "$P12_OBS" | jq -r '.types')" "shell,subagent"
assert_eq "P12a: statuses carries the DISTINCT status vocabulary" \
  "$(printf '%s' "$P12_OBS" | jq -r '.statuses')" "running"
assert_eq "P12a: why is ABSENT on the yes arm, so its closed set stays closed" \
  "$(printf '%s' "$P12_OBS" | jq -r 'has("why")')" "false"
assert_not_contains "P12a privacy: the event carries no cwd" "$P12_OBS" "cwd"
assert_not_contains "P12a privacy: the event carries no transcript_path" "$P12_OBS" "transcript_path"
assert_not_contains "P12a privacy: the event carries no agent_transcript_path" "$P12_OBS" "agent_transcript_path"
assert_not_contains "P12a privacy: the event carries no last_assistant_message" "$P12_OBS" "last_assistant_message"
assert_not_contains "P12a privacy: no VALUE from those four fields leaks either" "$P12_OBS" "SECRET"
P12_BYTES=${#P12_OBS}
assert_eq "P12a: the event stays bounded and structured (${P12_BYTES} bytes <= 300)" \
  "$([ "$P12_BYTES" -le 300 ] && echo yes || echo no)" "yes"
teardown_temp_dir

# === P7 (C2/AC9): every stop-hook execution under tests/ binds its own stdin ===
# Bare stdin inherits the suite's once C1 lands — the #155 never-EOF deadlock class.
P7_ROOT="$REPO_ROOT/tests"
P7_PATTERN='bash "\$STOP_HOOK"|bash "\$REPO_ROOT/scripts/stop-hook\.sh"'
P7_SCANNED=0
P7_SKIPPED=0
P7_CHECKED=0
P7_FINDINGS=0
P7_BARE=()

while IFS= read -r _p7_hit; do
  [ -n "$_p7_hit" ] || continue
  P7_SCANNED=$((P7_SCANNED + 1))
  _p7_file="${_p7_hit%%:*}"
  _p7_rest="${_p7_hit#*:}"
  _p7_line="${_p7_rest%%:*}"
  _p7_text="${_p7_rest#*:}"
  # A commented-out invocation is text, not an execution: excluded, and counted.
  case "${_p7_text#"${_p7_text%%[![:space:]]*}"}" in
    '#'*) P7_SKIPPED=$((P7_SKIPPED + 1)); continue ;;
  esac
  P7_CHECKED=$((P7_CHECKED + 1))
  case "$_p7_text" in
    *'</dev/null'*|*'< /dev/null'*) continue ;;
  esac
  # A pipe upstream of the invocation supplies (and EOFs) stdin just as well.
  case "${_p7_text%%bash \"*}" in
    *'|'*) continue ;;
  esac
  # An explicit redirect binds the invocation's OWN stdin whatever it names, and
  # P6 below deliberately binds a never-EOF fifo — that is the pin, not the leak.
  case "$_p7_text" in
    *'< "$'*|*'<"$'*) continue ;;
  esac
  P7_FINDINGS=$((P7_FINDINGS + 1))
  P7_BARE+=("${_p7_file#"$P7_ROOT/"}:$_p7_line")
done < <(grep -rnE "$P7_PATTERN" "$P7_ROOT" 2>/dev/null || true)

assert_eq "P7 accounting: scanned == skipped + checked" \
  "$P7_SCANNED" "$((P7_SKIPPED + P7_CHECKED))"

if [ "$P7_CHECKED" -gt 0 ]; then
  _pass "P7 floor: $P7_CHECKED stop-hook execution site(s) checked under tests/"
else
  _fail "P7 floor: $P7_CHECKED stop-hook execution site(s) checked under tests/" \
    "a zero-site scan is a broken scan, not a clean tree — the population cannot be empty"
fi

if [ "$P7_FINDINGS" -gt 0 ]; then
  printf '  P7 bare-stdin site: %s\n' "${P7_BARE[@]}" >&2
fi
assert_eq "P7: $P7_SCANNED scanned, $P7_SKIPPED skipped, $P7_CHECKED checked — no stop-hook execution leaves stdin bare" \
  "$P7_FINDINGS" "0"

assert_file_contains "P7: tests/run-tests.sh runs every test file with stdin bound to /dev/null" \
  "$REPO_ROOT/tests/run-tests.sh" 'bash "$test_file" < /dev/null'

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$WRITER" 2>/dev/null \
    && _pass "shellcheck clean: in-flight-marker.sh" \
    || _fail "shellcheck clean: in-flight-marker.sh" "shellcheck warnings found"
else
  _skip "shellcheck skipped (not installed): in-flight-marker.sh"
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$HOOK_STDIN_LIB" 2>/dev/null \
    && _pass "AC-V1: shellcheck clean: scripts/lib/hook-stdin.sh" \
    || _fail "AC-V1: shellcheck clean: scripts/lib/hook-stdin.sh" "shellcheck warnings found"
else
  _skip "shellcheck skipped (not installed): scripts/lib/hook-stdin.sh"
fi

report_results
