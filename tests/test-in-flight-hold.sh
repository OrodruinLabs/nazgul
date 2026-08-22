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
EVENT_COUNT=$(grep -c '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true); EVENT_COUNT="${EVENT_COUNT:-0}"
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
EVENT_COUNT=$(grep -c '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true); EVENT_COUNT="${EVENT_COUNT:-0}"
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
STALE_EVENT_COUNT=$(grep -c '"reason":"in_flight_stale"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true); STALE_EVENT_COUNT="${STALE_EVENT_COUNT:-0}"
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

# P11a (binding ruling on PR #245, finding 1) — PROVEN class x LIVE payload, the cell neither P1 nor
# the P2 negative ever drove. A background:"false" marker is disposed identically regardless of BG_LIVE.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/fg.json" "nazgul:implementer" "TASK-FOREGROUND" "$NOW" "false"
# The second, HELD marker is what makes the units-exclusion assertion below non-vacuous: it forces
# units to be NON-EMPTY, so "TASK-FOREGROUND is absent" cannot pass by the field being empty instead.
_write_marker "$TEST_DIR/nazgul/in-flight/held.json" "nazgul:implementer" "TASK-HELD" "$NOW" "missing"
run_hook "$(cat "$FIXTURES/stop-payload/stop-two-subagents-one-shell.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
# A dispatchable READY task is planted on purpose: without the hold this run blocks with exit 2, so
# exit 0 discriminates here instead of being the no-plan default.
assert_exit_code "P11a: liveness is its own basis, so the tick still holds (exit 0)" "$HOOK_EC" 0
# SUBSTRING TRAPS, both live: in_flight_orphan is a strict prefix of in_flight_orphan_candidate and
# in_flight_hold of in_flight_hold_budget_exhausted, so every token below carries its closing quote.
assert_contains "P11a: a live tick does NOT rescue a background:\"false\" marker from quarantine" "$EVENTS" '"reason":"in_flight_orphan"'
assert_file_exists "P11a: the proven-class marker really moved to nazgul/in-flight/quarantine/" "$TEST_DIR/nazgul/in-flight/quarantine/fg.json"
assert_file_not_exists "P11a: ... and is gone from nazgul/in-flight/" "$TEST_DIR/nazgul/in-flight/fg.json"
assert_contains "P11a: the hold is STILL emitted on the same tick" "$EVENTS" '"reason":"in_flight_hold"'
P11A_HOLD=$(grep '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_eq "P11a: the hold's units names the held marker — the exclusion below is not an empty-field pass" \
  "$(printf '%s' "$P11A_HOLD" | jq -r '.units' 2>/dev/null)" "TASK-HELD"
assert_eq "P11a (consequence 2): units NEVER accumulates the background:\"false\" unit" \
  "$(printf '%s' "$P11A_HOLD" | jq -r 'if (.units | test("TASK-FOREGROUND")) then "named" else "absent" end' 2>/dev/null)" "absent"
assert_eq "P11a: the hold counts only the held marker" \
  "$(printf '%s' "$P11A_HOLD" | jq -r '.count' 2>/dev/null)" "1"
assert_contains "P11a: the live arm's own discriminator is still present" "$P11A_HOLD" '"live_subagents":2'
assert_file_exists "P11a: the non-false marker is left in place" "$TEST_DIR/nazgul/in-flight/held.json"
teardown_temp_dir

# P11b (binding ruling, second cell) — a NAMED marker's proof is CONTRACTUAL, and a named dispatch can
# be genuinely background AND live, so on a live tick it is HELD rather than quarantined.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/named.json" "nazgul:implementer" "TASK-NAMED" "$(date +%s)" "missing" "true"
run_hook "$(cat "$FIXTURES/stop-payload/stop-two-subagents-one-shell.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
assert_exit_code "P11b: a named marker on a live tick is held, not moved (exit 0)" "$HOOK_EC" 0
assert_file_exists "P11b: the named marker is still at its original path" "$TEST_DIR/nazgul/in-flight/named.json"
assert_file_not_exists "P11b: the named marker is NOT quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/named.json"
# SUBSTRING TRAP (same as P2 at :397-399): the closing quote is what keeps this off the candidate.
assert_not_contains "P11b: a contractual proof is never emitted as a PROVEN leak on a live tick" "$EVENTS" '"reason":"in_flight_orphan"'
P11B_HOLD=$(grep '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_eq "P11b: the hold names the named marker, so the negative above ran against real output" \
  "$(printf '%s' "$P11B_HOLD" | jq -r '.units' 2>/dev/null)" "TASK-NAMED"
teardown_temp_dir

# P11c (ruling: fingerprint interaction, ACCEPT but pin) — quarantining a proven-class marker changes
# the HELD set once, so Q1's budget is refreshed at most once: a marker can leave that set only once.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
_write_marker "$TEST_DIR/nazgul/in-flight/fg.json" "nazgul:implementer" "TASK-FOREGROUND" "$NOW" "false"
_write_marker "$TEST_DIR/nazgul/in-flight/held.json" "nazgul:implementer" "TASK-HELD" "$NOW" "missing"
run_hook "$(cat "$FIXTURES/stop-payload/stop-two-subagents-one-shell.json")"
assert_exit_code "P11c: tick 1 — the post-quarantine HELD set takes its one hold (exit 0)" "$HOOK_EC" 0
run_hook "$(cat "$FIXTURES/stop-payload/stop-two-subagents-one-shell.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
assert_exit_code "P11c: tick 2 — an unchanged HELD set is refused a second hold (exit 2)" "$HOOK_EC" 2
P11C_HOLDS=$(grep -c '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true); P11C_HOLDS="${P11C_HOLDS:-0}"
assert_eq "P11c: a proven-class quarantine grants AT MOST ONE additional hold" "$P11C_HOLDS" "1"
assert_contains "P11c: tick 2 records the exhausted budget rather than falling through silently" "$EVENTS" '"reason":"in_flight_hold_budget_exhausted"'
P11C_ORPHANS=$(grep -c '"reason":"in_flight_orphan"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true); P11C_ORPHANS="${P11C_ORPHANS:-0}"
assert_eq "P11c: the marker is quarantined once and only once across both ticks" "$P11C_ORPHANS" "1"
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
# rename, a wrong shape or a payload that never arrived degrades to the payload-absent arm.
P5_SCANNED=0
P5_SKIPPED=0
P5_CHECKED=0
P5_FINDINGS=0
P5_CASES=(
  'a literal non-JSON string|not_json|not json'
  'valid JSON without the key|field_absent|{"hook_event_name":"Stop"}'
  'a document truncated mid-read|not_json|{"hook_event_name":"Stop","background_tasks":[{"id":"a1","type":"subagent","status":"run'
  'an empty payload|no_stdin|'
  'background_tasks present but a string|field_wrong_type|{"hook_event_name":"Stop","background_tasks":"not-an-array"}'
  'background_tasks present but an object|field_wrong_type|{"hook_event_name":"Stop","background_tasks":{"a":1}}'
  'background_tasks an explicit JSON null|field_wrong_type|{"hook_event_name":"Stop","background_tasks":null}'
  'background_tasks an OBJECT of task objects|field_wrong_type|{"hook_event_name":"Stop","background_tasks":{"t1":{"type":"subagent","status":"running"}}}'
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
  # Zero counts under bg_seen:"yes" is the collapse itself: byte-identical to an observed empty
  # array, so a record that could not be read would read as one that was. NONE when no event at all.
  p5_collapse=$(printf '%s' "$P5_OBS" | jq -r \
    'if .bg_seen == "yes" and .entries == 0 and .subagents == 0 and .live == 0 then "yes" else "no" end' 2>/dev/null)
  P5_GOT="exit=$p5_exit why=${p5_why:-NONE} bg_seen=${p5_seen:-NONE} collapse=${p5_collapse:-NONE} marker=$p5_marker quarantine=$p5_quar unverifiable=$p5_unver hold=$p5_hold candidate=$p5_cand"
  P5_WANT="exit=safe why=$p5_want_why bg_seen=unknown collapse=no marker=present quarantine=absent unverifiable=yes hold=no candidate=no"
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
# The hold is the DISPOSITION; the stale record is a REPORT. Round 1 asserted the absence of the
# record as a proxy for the disposition, which is what F15 below shows was never the same claim.
assert_contains "F15 (in the P8 cell): the over-age marker is reported, not silenced by the hold it was granted" "$EVENTS" '"reason":"in_flight_stale"'
assert_eq "F15 (in the P8 cell): ... and that record marks itself held-over-age, so it never reads as a declined hold" \
  "$(grep '"reason":"in_flight_stale"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1 | jq -r '.held_over_age')" "true"
assert_file_exists "P8: the over-age marker is left in place" "$TEST_DIR/nazgul/in-flight/stale.json"
assert_file_not_exists "P8: the over-age marker is not quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/stale.json"
assert_eq "P8: a held iteration is not burned" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "5"
teardown_temp_dir

# F15 (union mo@:240, ADR-014) — #211 forbids a stale bound DECLINING a hold when a subagent is
# observed live; it never asked for the crashed-subagent diagnostic to be silenced along with it.
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
F15_LINE=$(grep '"reason":"in_flight_stale"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_exit_code "F15: the over-age marker is STILL held — reporting it changes no disposition (exit 0)" "$HOOK_EC" 0
assert_contains "F15: the hold really was taken on this tick" "$EVENTS" '"reason":"in_flight_hold"'
assert_contains "F15: and the crashed-subagent diagnostic survives the hold" "$EVENTS" '"reason":"in_flight_stale"'
# held_over_age is what separates this emit from the ordinary decline-the-hold stale branch: a tree
# where the marker fell through to that branch would satisfy the reason pin above but not this one.
assert_eq "F15: the record marks itself as held over age, not as a declined hold" \
  "$(printf '%s' "$F15_LINE" | jq -r '.held_over_age')" "true"
assert_eq "F15: it carries the bound it exceeded" \
  "$(printf '%s' "$F15_LINE" | jq -r '.limit')" "30"
assert_eq "F15: and an age genuinely past that bound, read off the record" \
  "$(printf '%s' "$F15_LINE" | jq -r 'if .age_minutes >= 31 then "over" else "under" end')" "over"
assert_contains "F15: the stderr line says HELD ON, never the declined branch's wording" "$HOOK_OUTPUT" "HELD ON anyway"
assert_file_exists "F15: the over-age marker is left in place" "$TEST_DIR/nazgul/in-flight/stale.json"
assert_file_not_exists "F15: and is never quarantined by being reported" "$TEST_DIR/nazgul/in-flight/quarantine/stale.json"
assert_eq "F15: a held iteration is still not burned" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "5"
teardown_temp_dir

# F15 companion — the age test is real and not an unconditional emit: a FRESH marker under the SAME
# live payload takes the same hold and records no staleness at all.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/fresh.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "missing"
run_hook "$(cat "$FIXTURES/stop-payload/stop-two-subagents-one-shell.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
assert_exit_code "F15 companion: a fresh marker under a live payload holds exactly as before (exit 0)" "$HOOK_EC" 0
assert_contains "F15 companion: the same hold, through the same arm" "$EVENTS" '"reason":"in_flight_hold"'
assert_not_contains "F15 companion: and NO stale record — the new emit is age-gated, not unconditional" "$EVENTS" '"reason":"in_flight_stale"'
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

# F5 (union mo@:254, ADR-014) — ruling Q2's third state acts on nothing, and recorded nothing either.
# Its DISPOSITION is passed by the ruling and unchanged here; only the silence is.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "missing"
F5_QUAR_BEFORE=$(find "$TEST_DIR/nazgul/in-flight/quarantine" -type f 2>/dev/null | wc -l | tr -d ' ')
run_hook "$(cat "$FIXTURES/stop-payload-synthetic/unknown-status-queued.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
F5_LINE=$(grep '"reason":"in_flight_present_not_live"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_contains "F5: the third state emits a stop_gate record of its own" "$EVENTS" '"reason":"in_flight_present_not_live"'
assert_contains "F5: and a loud stderr line, the treatment in_flight_stale already gets" "$HOOK_OUTPUT" "PRESENT-NOT-LIVE in-flight marker"
assert_contains "F5: the stderr line names the unit it could not classify" "$HOOK_OUTPUT" "TASK-002"
assert_eq "F5: the record names that unit too" "$(printf '%s' "$F5_LINE" | jq -r '.unit')" "TASK-002"
assert_eq "F5: ... and the agent" "$(printf '%s' "$F5_LINE" | jq -r '.agent')" "nazgul:implementer"
# Both counts are compared against the fixture's own numbers rather than asserted present: a record
# that carried neither, or carried a constant, would still satisfy a bare presence check.
assert_eq "F5: it carries the two counts that produced the state — present, and not live" \
  "$(printf '%s' "$F5_LINE" | jq -r '"\(.subagents_present)/\(.live)"')" "1/0"
assert_eq "F5: subagents_present is a JSON number, not a string" \
  "$(printf '%s' "$F5_LINE" | jq -r '.subagents_present | type')" "number"
assert_eq "F5: it quotes the unrecognised statuses verbatim — the reason the tick could not tell" \
  "$(printf '%s' "$F5_LINE" | jq -r '.statuses')" "queued,running"
# SCOPE FENCE (ruling): a record was added, a disposition was not. Every P11 disposition still holds.
assert_file_exists "F5: the marker is still at its original path" "$TEST_DIR/nazgul/in-flight/legacy.json"
assert_file_not_exists "F5: the marker is NOT quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/legacy.json"
assert_eq "F5: the quarantine/ file count is unchanged across the run" \
  "$(find "$TEST_DIR/nazgul/in-flight/quarantine" -type f 2>/dev/null | wc -l | tr -d ' ')" "$F5_QUAR_BEFORE"
assert_not_contains "F5: still no hold — a record is not a disposition" "$EVENTS" '"reason":"in_flight_hold"'
assert_not_contains "F5: and still no orphan candidate — a subagent IS present" "$EVENTS" '"reason":"in_flight_orphan_candidate"'
assert_exit_code "F5: the run still degrades to an ordinary blocked iteration (exit 2)" "$HOOK_EC" 2
teardown_temp_dir

# F5 negative — the new reason is reached only by the third state. An observed-EMPTY payload keeps
# its candidate disposition, so a collapse of the two arms is caught here and not only by review.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
_write_marker "$TEST_DIR/nazgul/in-flight/legacy.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "missing"
run_hook "$(cat "$FIXTURES/stop-payload-synthetic/background-tasks-empty.json")"
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
assert_contains "F5 negative: an empty background_tasks[] still files the orphan candidate" "$EVENTS" '"reason":"in_flight_orphan_candidate"'
assert_not_contains "F5 negative: and never the present-not-live reason — no subagent is present" "$EVENTS" '"reason":"in_flight_present_not_live"'
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
  n=$(grep -c '"reason":"in_flight_hold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

_p10_exhausted_count() {
  local n
  n=$(grep -c '"reason":"in_flight_hold_budget_exhausted"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true)
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
P10_EC_A="$HOOK_EC"
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
_p10_check "P10a: the ledger records the one hold taken on its count line" "$(head -n 1 "$P10_LEDGER" 2>/dev/null)" "1"
_p10_check "P10a: named by a 16-char hash — the _resume_attempts_file convention, not a new one" \
  "${#P10_LEDGER_BASE}" "16"

run_hook "$P10_PAYLOAD"
# Asserted as the PAIR, not as a bare exit 2: a tree where no hold is ever taken exits 2 on both
# runs, so a lone `2` would score "the valve refused it" for a run the valve never saw.
_p10_check "P10a then P10b: the first hold taken and the unchanged repeat refused (0 then 2)" \
  "$P10_EC_A/$HOOK_EC" "0/2"
_p10_check "P10b: still exactly one in_flight_hold event — no second hold was taken" "$(_p10_hold_count)" "1"
_p10_check "P10b: exactly one in_flight_hold_budget_exhausted event" "$(_p10_exhausted_count)" "1"
P10_EX=$(_p10_exhausted_line)
# The length rides along because two absent values compare equal: with no event and no ledger
# file, a bare equality would score "" against "" and call it a match.
_p10_check "P10b: the event names the fingerprint that keys the ledger file, and it is a real hash" \
  "$(printf '%s' "$P10_EX" | jq -r '.fingerprint')/${#P10_LEDGER_BASE}" "$P10_LEDGER_BASE/16"
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
_p10_check "P10b: the spent ledger is not driven past the cap" "$(head -n 1 "$P10_LEDGER" 2>/dev/null)" "1"

_write_marker "$TEST_DIR/nazgul/in-flight/valve-b.json" "nazgul:implementer" "TASK-009" "$(date +%s)" "missing"
run_hook "$P10_PAYLOAD"
# Exit code AND hold count together: after two prior invocations a run can reach exit 0 down
# paths that have nothing to do with a hold, and only the second hold event distinguishes them.
_p10_check "P10c: a CHANGED marker set gets its own budget and holds again (exit 0, second hold)" \
  "$HOOK_EC/$(_p10_hold_count)" "0/2"
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
  "$(printf '%s' "$HOOK_OUTPUT" | grep -c 'in-flight hold ledger hash fallback' || true)" "1"
teardown_temp_dir

# P10e (F6) — the ZERO-marker live hold. Its key used to be sha256("") = e3b0c44298fc1c14, a
# lifetime constant, so this arm got exactly one hold per project and then degraded silently.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
P10E_A='{"hook_event_name":"Stop","background_tasks":[{"id":"sub-alpha","type":"subagent","status":"running"}]}'
P10E_B='{"hook_event_name":"Stop","background_tasks":[{"id":"sub-bravo","type":"subagent","status":"running"}]}'
P10E_C='{"hook_event_name":"Stop","background_tasks":[{"id":"sub-charlie","type":"subagent","status":"running"}]}'
run_hook "$P10E_A"; P10E_EC1="$HOOK_EC"
run_hook "$P10E_A"; P10E_EC2="$HOOK_EC"
run_hook "$P10E_B"; P10E_EC3="$HOOK_EC"
run_hook "$P10E_C"; P10E_EC4="$HOOK_EC"
# The four exit codes as ONE value: a tree that never holds exits 2 four times and a tree that
# never bounds exits 0 four times, and only the 0/2/0/0 shape distinguishes the fix from both.
_p10_check "P10e: the zero-marker hold is bounded per EPISODE — taken, refused on the repeat, taken again on each changed one" \
  "$P10E_EC1/$P10E_EC2/$P10E_EC3/$P10E_EC4" "0/2/0/0"
_p10_check "P10e: no marker was ever present, so this really is the zero-marker arm the constant key broke" \
  "$(find "$TEST_DIR/nazgul/in-flight" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "0"
_p10_check "P10e: three holds across three distinct live-subagent sets" "$(_p10_hold_count)" "3"
_p10_check "P10e: exactly one exhaustion — the repeat of the SAME episode" "$(_p10_exhausted_count)" "1"
_p10_check "P10e: and the key still binds, so the fix did not simply unbound the arm" \
  "$(printf '%s' "$(_p10_exhausted_line)" | jq -r '.holds_taken')" "1"
# Three files with three DISTINCT names: "a ledger file exists" is satisfied by the constant key too.
_p10_check "P10e: three ledger entries, one per episode" "$(_p10_ledger_count)" "3"
_p10_check "P10e: ... under three different names — the key is a property of the episode, not a constant" \
  "$(find "$TEST_DIR/nazgul/logs/.in-flight-holds" -type f 2>/dev/null | sed 's|.*/||' | sort -u | wc -l | tr -d ' ')" "3"
_p10_check "P10e: none of them is sha256(\"\"), the lifetime constant the empty key hashed to" \
  "$([ -e "$TEST_DIR/nazgul/logs/.in-flight-holds/e3b0c44298fc1c14" ] && echo present || echo absent)" "absent"
teardown_temp_dir

# P10j (F6, the other half) — an episode with nothing to key on. The zero-marker key rests on
# background_tasks[].id, and an undocumented field can go away; a constant key is what it replaced.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
run_hook '{"hook_event_name":"Stop","background_tasks":[{"type":"subagent","status":"running"}]}'
P10J_LINE=$(grep '"reason":"in_flight_hold_unbudgetable"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
_p10_check "P10j: the payload really is live, so the hold arm was reached and not skipped upstream" \
  "$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1 | jq -r '.live')" "1"
_p10_check "P10j: an episode that cannot be keyed is refused, not held on a constant (exit 2)" "$HOOK_EC" "2"
_p10_check "P10j: no hold was taken" "$(_p10_hold_count)" "0"
_p10_check "P10j: it is a mechanism failure, not a spent budget" \
  "$(printf '%s' "$P10J_LINE" | jq -r '.reason')" "in_flight_hold_unbudgetable"
_p10_check "P10j: holds_taken stays 0 — nothing was spent" \
  "$(printf '%s' "$P10J_LINE" | jq -r '.holds_taken')" "0"
_p10_check "P10j: and it says why on stderr rather than degrading silently" \
  "$(printf '%s' "$HOOK_OUTPUT" | grep -c 'carry no id' || true)" "1"
_p10_check "P10j: no ledger entry was written for an unkeyable episode" "$(_p10_ledger_count)" "0"
teardown_temp_dir

# P10f (F6) — the ledger directory is not write-only. Entries name the marker set they were keyed
# on, so an episode whose markers were cleared takes its entry with it.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
P10F_PAYLOAD='{"hook_event_name":"Stop","background_tasks":[{"id":"s1","type":"subagent","status":"running"}]}'
_write_marker "$TEST_DIR/nazgul/in-flight/prune-a.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "missing"
run_hook "$P10F_PAYLOAD"
P10F_FIRST=$(find "$TEST_DIR/nazgul/logs/.in-flight-holds" -type f 2>/dev/null | head -1)
_p10_check "P10f: the first episode leaves exactly one ledger entry" "$(_p10_ledger_count)" "1"
_p10_check "P10f: line 1 is still the count, so the ledger the cap reads is unchanged" \
  "$(head -n 1 "$P10F_FIRST" 2>/dev/null)" "1"
_p10_check "P10f: lines 2+ record the marker set it was keyed on — the evidence the prune reads" \
  "$(tail -n +2 "$P10F_FIRST" 2>/dev/null)" "prune-a.json"
# subagent-stop.sh's clear, by hand: the set this entry names no longer exists anywhere.
rm -f "$TEST_DIR/nazgul/in-flight/prune-a.json"
_write_marker "$TEST_DIR/nazgul/in-flight/prune-b.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "missing"
run_hook "$P10F_PAYLOAD"
_p10_check "P10f: a cleared marker set does not leave its entry behind — the directory does not grow" \
  "$(_p10_ledger_count)" "1"
_p10_check "P10f: ... and the entry that went is the OLD one, so this is a prune and not a no-op" \
  "$([ -e "$P10F_FIRST" ] && echo present || echo absent)" "absent"
_p10_check "P10f: the second episode took its own hold, so the surviving entry was really written" \
  "$(_p10_hold_count)" "2"
_write_marker "$TEST_DIR/nazgul/in-flight/prune-c.json" "nazgul:implementer" "TASK-003" "$(date +%s)" "missing"
run_hook "$P10F_PAYLOAD"
# The trap this closes: a prune that deleted everything would also satisfy "does not grow".
_p10_check "P10f: an entry whose markers still exist SURVIVES — the prune is evidence-driven, not a truncate" \
  "$(_p10_ledger_count)" "2"
_p10_check "P10f: the changed set holds again, so the surviving entry did not refuse it" "$(_p10_hold_count)" "3"
teardown_temp_dir

# P10g (F8) — the fingerprint's collation is pinned in source. The behavioural half below cannot
# discriminate on a host whose UTF-8 locale collates like C, which is why the grep carries it.
_p10_check "P10g: the key's sort runs under LC_ALL=C — a key that varies by locale is not a fingerprint" \
  "$([ "$(grep -c 'LC_ALL=C sort' "$STOP_HOOK")" -ge 1 ] && echo present || echo absent)" "present"
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight"
# `-` vs `b` is exactly the ordering that differs between C and a UTF-8 collation.
_write_marker "$TEST_DIR/nazgul/in-flight/a-b.json" "nazgul:implementer" "TASK-001" "$(date +%s)" "true"
_write_marker "$TEST_DIR/nazgul/in-flight/ab.json" "nazgul:implementer" "TASK-002" "$(date +%s)" "true"
HOOK_OUTPUT=$(LC_ALL=C bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
P10G_EC1="$HOOK_EC"
HOOK_OUTPUT=$(LC_ALL=en_US.UTF-8 bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
_p10_check "P10g: the same marker set under two collations is ONE budget, not two (0 then 2)" \
  "$P10G_EC1/$HOOK_EC" "0/2"
_p10_check "P10g: ... keyed to a single ledger entry" "$(_p10_ledger_count)" "1"
teardown_temp_dir

# P10h (F7) — the budget claim is a read/cap-check/write under one lock. A lock that cannot be
# acquired means the hold cannot be bounded, and ruling Q1 refuses an unbounded hold.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight" "$TEST_DIR/nazgul/logs/.in-flight-holds.lock"
_write_marker "$TEST_DIR/nazgul/in-flight/lock-a.json" "nazgul:implementer" "TASK-005" "$(date +%s)" "true"
run_hook
P10H_LINE=$(grep '"reason":"in_flight_hold_unbudgetable"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
_p10_check "P10h: the blocker is really in force — the lock path is a directory, so it cannot be opened for writing" \
  "$([ -d "$TEST_DIR/nazgul/logs/.in-flight-holds.lock" ] && echo dir || echo other)" "dir"
_p10_check "P10h: a claim that cannot take the lock skips the hold and continues (exit 2)" "$HOOK_EC" "2"
_p10_check "P10h: no hold was taken unbounded" "$(_p10_hold_count)" "0"
# SUBSTRING TRAP: in_flight_hold prefixes both no-hold reasons, so every count carries the closing quote.
_p10_check "P10h: it wears the mechanism-failure reason, never the spent budget's" \
  "$(printf '%s' "$P10H_LINE" | jq -r '.reason')" "in_flight_hold_unbudgetable"
_p10_check "P10h: nothing was spent — holds_taken stays 0 and the cap was never reached" \
  "$(printf '%s' "$P10H_LINE" | jq -r '.holds_taken')" "0"
_p10_check "P10h: and no exhaustion was claimed" "$(_p10_exhausted_count)" "0"
_p10_check "P10h: no ledger entry was written" "$(_p10_ledger_count)" "0"
_p10_check "P10h: the marker is left exactly where it was" \
  "$([ -f "$TEST_DIR/nazgul/in-flight/lock-a.json" ] && echo present || echo absent)" "present"
_p10_check "P10h: the run falls through to an ordinary blocked iteration" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "6"
teardown_temp_dir

# P10i (F7) — the two mechanics the cell above cannot observe from outside: the serialisation
# emit_event already uses in this process, and a rename rather than a truncate-then-write.
_p10_check "P10i: the read/cap-check/write is serialised with flock where available" \
  "$([ "$(grep -c 'flock -w 5 -x 200' "$STOP_HOOK")" -ge 1 ] && echo present || echo absent)" "present"
_p10_check "P10i: the ledger is renamed into place — a crash mid-truncate reads back as a refreshed budget" \
  "$([ "$(grep -c 'mv "$tmp" "$file"' "$STOP_HOOK")" -ge 1 ] && echo present || echo absent)" "present"

# AC12: the cap lives in code, and this objective adds no schema surface at all.
_p10_check "config purity: _IN_FLIGHT_HOLD_CAP is a script constant in scripts/stop-hook.sh" \
  "$([ "$(grep -c '_IN_FLIGHT_HOLD_CAP=1' "$STOP_HOOK")" -ge 1 ] && echo present || echo absent)" "present"
_p10_check "config purity: it is NOT a config key" \
  "$(grep -ci 'in_flight_hold_cap' "$REPO_ROOT/templates/config.json" || true)" "0"
_p10_check "config purity: the valve adds no guards key of its own" \
  "$(jq -r '.guards | has("in_flight_hold_cap")' "$REPO_ROOT/templates/config.json")" "false"
_p10_check "config purity: templates/config.json still reports schema_version 36" \
  "$(jq -r '.schema_version' "$REPO_ROOT/templates/config.json")" "36"

assert_eq "P10 accounting: scanned == skipped + checked" "$P10_SCANNED" "$((P10_SKIPPED + P10_CHECKED))"
assert_eq "P10 floor: the valve's pin set is not empty" \
  "$([ "$P10_CHECKED" -gt 0 ] && echo yes || echo no)" "yes"
assert_eq "P10: $P10_SCANNED scanned, $P10_SKIPPED skipped, $P10_CHECKED checked — every first hold permitted, every unchanged repeat refused" \
  "$P10_FINDINGS" "0"

# === F9 (union mo@:324, RULES §5): an unwritable ledger is a mechanism FAILURE, not a spent budget ===

# `.in-flight-holds` is created as a regular FILE so `mkdir -p` cannot succeed. A chmod would be
# ignored by a root-running CI and would silently test nothing.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
mkdir -p "$TEST_DIR/nazgul/in-flight" "$TEST_DIR/nazgul/logs"
_write_marker "$TEST_DIR/nazgul/in-flight/valve-uw.json" "nazgul:implementer" "TASK-007" "$(date +%s)" "true"
printf 'not a directory\n' > "$TEST_DIR/nazgul/logs/.in-flight-holds"
run_hook
EVENTS=$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)
F9_LINE=$(grep '"reason":"in_flight_hold_unbudgetable"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_eq "F9: the blocker is really in force — the ledger path is still a plain file, so mkdir -p could not have succeeded" \
  "$([ -f "$TEST_DIR/nazgul/logs/.in-flight-holds" ] && [ ! -d "$TEST_DIR/nazgul/logs/.in-flight-holds" ] && echo file || echo other)" "file"
assert_contains "F9: an unwritable ledger emits a reason of its own" "$EVENTS" '"reason":"in_flight_hold_unbudgetable"'
# SUBSTRING TRAP: in_flight_hold is a strict PREFIX of both in_flight_hold_budget_exhausted and
# in_flight_hold_unbudgetable, so every assertion here carries the compact-JSON closing quote.
assert_not_contains "F9: it never wears the spent budget's reason" "$EVENTS" '"reason":"in_flight_hold_budget_exhausted"'
assert_not_contains "F9: and no hold was taken" "$EVENTS" '"reason":"in_flight_hold"'
assert_eq "F9: holds_taken is 0 — the cap was never reached, so nothing was spent" \
  "$(printf '%s' "$F9_LINE" | jq -r '.holds_taken')" "0"
assert_eq "F9: holds_taken is a JSON number, not a string" \
  "$(printf '%s' "$F9_LINE" | jq -r '.holds_taken | type')" "number"
assert_eq "F9: the ledger field is kept — it still discriminates on the exhausted arm" \
  "$(printf '%s' "$F9_LINE" | jq -r '.ledger')" "unwritable"
assert_eq "F9: it names the unit it declined to hold on" \
  "$(printf '%s' "$F9_LINE" | jq -r '.units')" "TASK-007"
assert_contains "F9: the stderr wording is unchanged — the reason moved, the prose did not" "$HOOK_OUTPUT" "in-flight hold NOT taken"
assert_exit_code "F9: the run falls through to an ordinary blocked iteration (exit 2)" "$HOOK_EC" 2
assert_eq "F9: ... and burns it, so the fall-through really reached the increment" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "6"
assert_file_exists "F9: an unbudgetable hold quarantines nothing" "$TEST_DIR/nazgul/in-flight/valve-uw.json"
teardown_temp_dir

# === P12b (ruling Q4 item 2): the env-gated raw payload capture ===

# Same equality-on-an-extracted-value shape as P10, so the coverage line below
# counts pins that actually ran rather than pins that merely appeared.
P12_SCANNED=0
P12_SKIPPED=0
P12_CHECKED=0
P12_FINDINGS=0

_p12_check() {
  P12_SCANNED=$((P12_SCANNED + 1))
  P12_CHECKED=$((P12_CHECKED + 1))
  assert_eq "$1" "$2" "$3"
  [ "$2" = "$3" ] || P12_FINDINGS=$((P12_FINDINGS + 1))
}

_p12_state() { [ -e "$1" ] && printf 'present' || printf 'absent'; }

# GNU `stat -f` means --file-system and SUCCEEDS with unrelated output, so exit status cannot pick
# the dialect (scripts/lib/task-utils.sh:13) — accept a candidate only if it parses as octal.
_p12_mode() {
  local dialect m
  for dialect in "-f %Lp" "-c %a"; do
    # shellcheck disable=SC2086
    m=$(stat $dialect "$1" 2>/dev/null) || m=""
    case "$m" in ''|*[!0-7]*) m="" ;; esac
    [ -n "$m" ] && { printf '%s' "$m"; return 0; }
  done
  printf 'unreadable'
}

_p12_observed_count() {
  local n
  n=$(grep -c '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
P12_CAP="$TEST_DIR/nazgul/logs/stop-payload-last.json"
P12_A='{"hook_event_name":"Stop","session_id":"p12-first","background_tasks":[]}'
P12_B='{"hook_event_name":"Stop","session_id":"p12-second","background_tasks":[{"id":"s1","type":"subagent","status":"running"}]}'

# `env -u` on purpose: an operator who exports the variable would otherwise turn
# this arm into a false pass about a default it never actually observed.
HOOK_OUTPUT=$(printf '%s' "$P12_A" | env -u NAZGUL_STOP_PAYLOAD_CAPTURE bash "$STOP_HOOK" 2>&1) || true
# One pin, two facts: file absent AND the run reached the capture site. Split apart,
# the absence half also passes on a tree where the gate does not exist at all.
_p12_check "P12b: with NAZGUL_STOP_PAYLOAD_CAPTURE unset no raw capture is written, on a run that provably reached the capture site" \
  "$(_p12_state "$P12_CAP")/$(_p12_observed_count)" "absent/1"
_p12_check "P12b: nazgul/logs/ exists on that run, so the absence is specific to the capture file" \
  "$(_p12_state "$TEST_DIR/nazgul/logs")" "present"

HOOK_OUTPUT=$(printf '%s' "$P12_A" | NAZGUL_STOP_PAYLOAD_CAPTURE=1 bash "$STOP_HOOK" 2>&1) || true
_p12_check "P12b: NAZGUL_STOP_PAYLOAD_CAPTURE=1 captures the raw payload" \
  "$(_p12_state "$P12_CAP")" "present"
_p12_check "P12b: and the file holds THIS run's payload, not a placeholder" \
  "$(jq -r '.session_id' "$P12_CAP" 2>/dev/null)" "p12-first"
_p12_check "P12b: one line — a single document, not an append log" \
  "$(wc -l < "$P12_CAP" | tr -d ' ')" "1"

HOOK_OUTPUT=$(printf '%s' "$P12_B" | NAZGUL_STOP_PAYLOAD_CAPTURE=1 bash "$STOP_HOOK" 2>&1) || true
_p12_check "P12b: a second capture OVERWRITES — the file holds the SECOND payload" \
  "$(jq -r '.session_id' "$P12_CAP" 2>/dev/null)" "p12-second"
_p12_check "P12b: the FIRST payload is gone, so it was replaced and not appended to" \
  "$(grep -c 'p12-first' "$P12_CAP" || true)" "0"
_p12_check "P12b: and the line count did not grow across the two captures" \
  "$(wc -l < "$P12_CAP" | tr -d ' ')" "1"

# A one-byte file is the newline alone: proof it was REWRITTEN empty rather than
# left holding the previous run's payload.
HOOK_OUTPUT=$(NAZGUL_STOP_PAYLOAD_CAPTURE=1 bash "$STOP_HOOK" </dev/null 2>&1) || true
_p12_check "P12b: capture ON with no payload records an EMPTY capture, so 'nothing arrived' stays distinguishable from 'capture off'" \
  "$(_p12_state "$P12_CAP")/$(wc -c < "$P12_CAP" | tr -d ' ')" "present/1"

# umask 000 on purpose: at the ambient 022 a plain `>` already yields 0644, which reads as a pass
# for a mode nothing set. Under 000 an inherited mode is 0666, so only an explicit one survives.
HOOK_OUTPUT=$( (umask 000; printf '%s' "$P12_A" | NAZGUL_STOP_PAYLOAD_CAPTURE=1 bash "$STOP_HOOK") 2>&1 ) || true
_p12_check "P12b: the file that LANDS is 0600 under a permissive umask — cwd and the transcript paths are not world-readable" \
  "$(_p12_mode "$P12_CAP")" "600"
_p12_check "P12b: ... and it is the capture, not an empty stand-in — the payload survived the staged write" \
  "$(jq -r '.session_id' "$P12_CAP" 2>/dev/null)" "p12-first"

chmod 644 "$P12_CAP"
HOOK_OUTPUT=$(printf '%s' "$P12_B" | NAZGUL_STOP_PAYLOAD_CAPTURE=1 bash "$STOP_HOOK" 2>&1) || true
_p12_check "P12b: a loose pre-existing capture is REPLACED, not written through — 0644 does not survive a second run" \
  "$(_p12_mode "$P12_CAP")" "600"
_p12_check "P12b: the replace still overwrote rather than appended" \
  "$(jq -r '.session_id' "$P12_CAP" 2>/dev/null)" "p12-second"
_p12_check "P12b: and no staging file is abandoned beside it, so the temp was renamed and not leaked" \
  "$(find "$TEST_DIR/nazgul/logs" -maxdepth 1 -name '.stop-payload-last.*' 2>/dev/null | wc -l | tr -d ' ')" "0"

# AC12 again, for Q4: the switch is an ENV VAR, and this objective adds no schema surface.
_p12_check "config purity: NAZGUL_STOP_PAYLOAD_CAPTURE is not a config key" \
  "$(grep -ci 'stop_payload_capture' "$REPO_ROOT/templates/config.json" || true)" "0"
_p12_check "config purity: and no migration introduces one" \
  "$(grep -ci 'stop_payload_capture' "$REPO_ROOT/scripts/migrate-config.sh" || true)" "0"
_p12_check "config purity: templates/config.json still reports schema_version 36" \
  "$(jq -r '.schema_version' "$REPO_ROOT/templates/config.json")" "36"

assert_eq "P12b accounting: scanned == skipped + checked" "$P12_SCANNED" "$((P12_SKIPPED + P12_CHECKED))"
assert_eq "P12b floor: the capture's pin set is not empty" \
  "$([ "$P12_CHECKED" -gt 0 ] && echo yes || echo no)" "yes"
assert_eq "P12b: $P12_SCANNED scanned, $P12_SKIPPED skipped, $P12_CHECKED checked — capture is opt-in, single-file and overwritten" \
  "$P12_FINDINGS" "0"
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

# The same fifo, but SOME bytes land before the writer goes quiet forever — the
# partial-timeout case. `exec` keeps $! the pid _never_eof_close can reap.
_partial_never_eof_open() {
  rm -f "$1"
  mkfifo "$1"
  ( printf '%s' "$2"; exec tail -f /dev/null ) > "$1" &
  NEVER_EOF_PID=$!
}

_run_hook_payload() {
  HOOK_OUTPUT=$(printf '%s' "$1" | bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# --- P9 (C1 unit, obligation AC-V1): read_hook_payload in isolation ---
assert_file_exists "P9/AC-V1: scripts/lib/hook-stdin.sh exists" "$HOOK_STDIN_LIB"
assert_file_contains "P9/AC-V1: it defines read_hook_payload" "$HOOK_STDIN_LIB" "read_hook_payload()"
assert_file_contains "AC-V1: stop-hook.sh sources it by absolute \$SCRIPT_DIR path" "$STOP_HOOK" \
  'source "$SCRIPT_DIR/lib/hook-stdin.sh"'

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

# --- P9 (TASK-015): the bound's own variable — prefixed, validated, and USED ---
P9_REAL='{"hook_event_name":"Stop","background_tasks":[]}'
P9_OUT=$(printf '%s' "$P9_REAL" | _bounded_run 8 env NAZGUL_HOOK_STDIN_TIMEOUT=abc bash -c "$P9_READER" _ "$HOOK_STDIN_LIB" 2>&1)
assert_contains "P9: a rejected NAZGUL_HOOK_STDIN_TIMEOUT is announced on stderr, never coerced in silence (ADR-014)" \
  "$P9_OUT" "NAZGUL_HOOK_STDIN_TIMEOUT=abc"
assert_contains "P9: ... and the payload that WAS on stdin still arrives — a misconfigured reader must never report no_stdin" \
  "$P9_OUT" "[$P9_REAL][]"

setup_temp_dir
P9_FIFO="$TEST_DIR/p9-timeout-var"
_never_eof_open "$P9_FIFO"
P9_START=$(date +%s)
P9_OUT=$(_bounded_run 20 env NAZGUL_HOOK_STDIN_TIMEOUT=abc bash -c "$P9_READER" _ "$HOOK_STDIN_LIB" < "$P9_FIFO" 2>/dev/null)
P9_ELAPSED=$(( $(date +%s) - P9_START ))
_never_eof_close "$P9_FIFO"
assert_eq "P9: the fallback is a real 2 s BOUND — a never-EOF stdin still times out under it" "$P9_OUT" "[][read_timeout]"
assert_eq "P9: ... and the read waited it out (${P9_ELAPSED}s), so the coerced value was USED, not merely printed" \
  "$([ "$P9_ELAPSED" -ge 1 ] && [ "$P9_ELAPSED" -lt 5 ] && echo yes || echo no)" "yes"

_never_eof_open "$P9_FIFO"
P9_START=$(date +%s)
P9_OUT=$(_bounded_run 20 env NAZGUL_HOOK_STDIN_TIMEOUT=5 bash -c "$P9_READER" _ "$HOOK_STDIN_LIB" < "$P9_FIFO" 2>/dev/null)
P9_ELAPSED=$(( $(date +%s) - P9_START ))
_never_eof_close "$P9_FIFO"
assert_eq "P9: a VALID value is honoured under the NEW name — 5 s waited (${P9_ELAPSED}s), not a hard-coded 2" \
  "$([ "$P9_ELAPSED" -ge 4 ] && echo yes || echo no)" "yes"

_never_eof_open "$P9_FIFO"
P9_START=$(date +%s)
P9_OUT=$(_bounded_run 20 env HOOK_STDIN_TIMEOUT=5 bash -c "$P9_READER" _ "$HOOK_STDIN_LIB" < "$P9_FIFO" 2>/dev/null)
P9_ELAPSED=$(( $(date +%s) - P9_START ))
_never_eof_close "$P9_FIFO"
assert_eq "P9: the unprefixed name is DEAD — no shim, so a stray HOOK_STDIN_TIMEOUT cannot move the bound (${P9_ELAPSED}s < 4)" \
  "$([ "$P9_ELAPSED" -lt 4 ] && echo yes || echo no)" "yes"
assert_eq "P9: ... and the default bound still governed that read" "$P9_OUT" "[][read_timeout]"
teardown_temp_dir

# --- P9 (TASK-015): a bound hit AFTER bytes arrived keeps its own evidence ---
P9_PARTIAL='{"hook_event_name":"Stop","background_tasks":[{"id":"a1","type":"subagent","status":"running"'
setup_temp_dir
P9_FIFO="$TEST_DIR/p9-partial"
_partial_never_eof_open "$P9_FIFO" "$P9_PARTIAL"
P9_START=$(date +%s)
P9_OUT=$(_bounded_run 20 bash -c "$P9_READER" _ "$HOOK_STDIN_LIB" < "$P9_FIFO" 2>/dev/null)
P9_ELAPSED=$(( $(date +%s) - P9_START ))
_never_eof_close "$P9_FIFO"
assert_eq "P9: a partial timed-out read keeps the bytes AND names the bound — read_timeout_partial" \
  "$P9_OUT" "[$P9_PARTIAL][read_timeout_partial]"
assert_eq "P9: ... reached at the bound (${P9_ELAPSED}s), by a writer that never EOFs — not by a short clean read" \
  "$([ "$P9_ELAPSED" -ge 1 ] && [ "$P9_ELAPSED" -lt 5 ] && echo yes || echo no)" "yes"
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
P9_FIFO="$TEST_DIR/p9-partial-hook"
_partial_never_eof_open "$P9_FIFO" "$P9_PARTIAL"
_bounded_run 20 bash "$STOP_HOOK" < "$P9_FIFO" >/dev/null 2>&1
_never_eof_close "$P9_FIFO"
# jq on the field, never a substring: `read_timeout` is a strict prefix of this member.
P9_WHY=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | jq -r '.why // "ABSENT"' | tr '\n' ' ')
assert_eq "P9: stop-hook prefers the reader's verdict — a truncation of OUR making is never filed as not_json" \
  "$P9_WHY" "read_timeout_partial "
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
# jq on the field, never a substring: `read_timeout` is a strict prefix of `read_timeout_partial`.
assert_eq "P6: the bounded read is recorded as read_timeout EXACTLY — not as an absent payload, and not as a partial one" \
  "$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | jq -r '.why // "ABSENT"' | tr '\n' ' ')" \
  "read_timeout "
teardown_temp_dir

# The terminal test is the WRONG PREDICATE (#155) and must never be the SOLE guard:
# what closes the hazard is the -t bound, so pin the bound itself, not the guard.
P6_BOUNDED=$(grep -cE 'read .*-d .. -t "\$NAZGUL_HOOK_STDIN_TIMEOUT"' "$HOOK_STDIN_LIB" || true)
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
  | grep -vcE '^(no_stdin|read_timeout|read_timeout_partial|not_json|field_absent|field_wrong_type|no_jq)$' || true)
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

# --- P12a attribution: the record names the tick it describes, and a paused tick has none ---
P12_LIVE='{"hook_event_name":"Stop","background_tasks":[{"id":"s1","type":"subagent","status":"running"}]}'

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 7'
create_plan
create_task_file "TASK-001" "READY"
_run_hook_payload "$P12_LIVE"
P12_OBS=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_eq "P12a: the record carries the tick it describes, not null" \
  "$(printf '%s' "$P12_OBS" | jq -r '.iteration')" "7"
assert_eq "P12a: ... as a JSON number, so two records inside one ts second still order" \
  "$(printf '%s' "$P12_OBS" | jq -r '.iteration | type')" "number"
# This run BURNED the tick, so 7 is the tick observed and not merely the value config still holds —
# an emit below the increment would have said 8, and one above the config read still null.
assert_eq "P12a: ... on a run that moved config on to 8, so 7 is this tick and not the survivor" \
  "$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")" "8"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.paused = true' '.current_iteration = 4'
create_plan
create_task_file "TASK-001" "READY"
_run_hook_payload "$P12_LIVE"
assert_exit_code "P12a: a paused tick still allows the stop" "$HOOK_EC" 0
assert_eq "P12a: and records nothing — a paused loop has no dispatch to classify, for hours or days" \
  "$(_p12_observed_count)" "0"
# Positive control on the SAME fixture and the SAME payload: without it, the zero above also passes
# on a tree where the hook died before reaching any of this.
jq '.paused = false' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/cfg.tmp" && mv "$TEST_DIR/cfg.tmp" "$TEST_DIR/nazgul/config.json"
_run_hook_payload "$P12_LIVE"
assert_eq "P12a: ... and the identical payload DOES record once paused is cleared, so the gate is the cause" \
  "$(_p12_observed_count)" "1"
assert_eq "P12a: the unpaused record carries iteration 4, so placement below the gate kept attribution" \
  "$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" | tail -1 | jq -r '.iteration')" "4"
teardown_temp_dir

# --- P12a vocabulary integrity: an empty column must not slide the next one into its place ---
setup_temp_dir
setup_nazgul_dir
create_config
_run_hook_payload '{"hook_event_name":"Stop","background_tasks":[{"id":"e1","type":"","status":"running"}]}'
P12_OBS=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
assert_eq "P12a: an empty type does not shift the statuses vocabulary into the types field" \
  "$(printf '%s' "$P12_OBS" | jq -r '.types')" "-"
assert_eq "P12a: ... and statuses still reports its own vocabulary, so R4's renamed-value canary survives" \
  "$(printf '%s' "$P12_OBS" | jq -r '.statuses')" "running"
assert_eq "P12a: ... and the entry still counts, so the sentinel replaced a value rather than dropping one" \
  "$(printf '%s' "$P12_OBS" | jq -r '"\(.entries)/\(.bg_seen)"')" "1/yes"
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
create_config
_run_hook_payload '{"hook_event_name":"Stop","background_tasks":[]}'
_run_hook_payload '{"hook_event_name":"Stop","stop_hook_active":false}'
P12_VOCAB=$(grep '"event":"stop_payload_observed"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null \
  | jq -r '"\(.bg_seen):\(.types)/\(.statuses)"' | tr '\n' ' ')
assert_eq "P12a: an observed-but-empty vocabulary ('-') stays distinguishable from one no arm ever read ('')" \
  "$P12_VOCAB" "yes:-/- unknown:/ "
teardown_temp_dir

# === P7 (C2/AC9): every stop-hook execution under tests/ binds its own stdin ===
# Bare stdin inherits the suite's once C1 lands — the #155 never-EOF deadlock class.
P7_ROOT="$REPO_ROOT/tests"
# EVERY quoted shell-word reference to the hook, not just the `bash `-prefixed ones: a direct
# `"$STOP_HOOK"` call used to be 0 scanned while the coverage line still printed 0 findings.
P7_PATTERN='"\$STOP_HOOK"|"\$REPO_ROOT/scripts/stop-hook\.sh"'
# Command position = a separator, or a chain of env/`bash`/runner words, immediately left of the
# word. Anything else is a REFERENCE (grep target, assert argument, `[ -f ]`): skipped, not dropped.
P7_CMDPOS='(^|[|;&(])[[:space:]]*((bash|env|-u|_bounded_run|[0-9]+|[A-Z_][A-Z0-9_]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*"(\$STOP_HOOK|\$REPO_ROOT/scripts/stop-hook\.sh)"'
P7_ASSIGN='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="\$REPO_ROOT/scripts/stop-hook\.sh"'
# The direct form is pinned by site count AND by the exact files carrying it: a count alone can
# match for an unrelated reason, a count plus the file set cannot.
P7_DIRECT_EXPECT=10
P7_DIRECT_FILES_EXPECT="test-observability-hooks.sh test-stop-hook.sh "
P7_CHECKED_EXPECT=42
P7_SCANNED=0
P7_SKIPPED=0
P7_CHECKED=0
P7_FINDINGS=0
P7_DIRECT=0
P7_DIRECT_FILES=""
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
  # A continuation line whose first word IS the quoted hook reads as command position and is
  # checked as one: a false finding costs a named site to re-read, a false pass costs the class.
  if [[ "$_p7_text" =~ $P7_ASSIGN ]] || ! [[ "$_p7_text" =~ $P7_CMDPOS ]]; then
    P7_SKIPPED=$((P7_SKIPPED + 1)); continue
  fi
  P7_CHECKED=$((P7_CHECKED + 1))
  _p7_head="$_p7_text"
  case "$_p7_text" in
    *'"$STOP_HOOK"'*) _p7_head="${_p7_text%%\"\$STOP_HOOK\"*}" ;;
    *'"$REPO_ROOT/scripts/stop-hook.sh"'*) _p7_head="${_p7_text%%\"\$REPO_ROOT/scripts/stop-hook.sh\"*}" ;;
  esac
  case "$_p7_head" in
    *'bash ') ;;
    *) P7_DIRECT=$((P7_DIRECT + 1))
       P7_DIRECT_FILES="$P7_DIRECT_FILES${_p7_file#"$P7_ROOT/"}
" ;;
  esac
  case "$_p7_text" in
    *'</dev/null'*|*'< /dev/null'*) continue ;;
  esac
  # A pipe upstream supplies (and EOFs) stdin just as well; `||` is not one, and a direct call has
  # no `bash "` to split at, so the split is at the invoked word.
  case "${_p7_head//||/}" in
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

assert_eq "P7 population: the direct (non-\`bash\`-prefixed) execution form is inside the scanned population" \
  "$P7_DIRECT" "$P7_DIRECT_EXPECT"
assert_eq "P7 population: ... and it is exactly these files, so $P7_DIRECT_EXPECT is not a coincidence" \
  "$(printf '%s' "$P7_DIRECT_FILES" | sort -u | tr '\n' ' ')" "$P7_DIRECT_FILES_EXPECT"
assert_eq "P7 population: the whole execution population is pinned, so a re-narrowed pattern cannot pass quietly" \
  "$P7_CHECKED" "$P7_CHECKED_EXPECT"

if [ "$P7_CHECKED" -gt 0 ]; then
  _pass "P7 floor: $P7_CHECKED stop-hook execution site(s) checked under tests/"
else
  _fail "P7 floor: $P7_CHECKED stop-hook execution site(s) checked under tests/" \
    "a zero-site scan is a broken scan, not a clean tree — the population cannot be empty"
fi

if [ "$P7_FINDINGS" -gt 0 ]; then
  printf '  P7 bare-stdin site: %s\n' "${P7_BARE[@]}" >&2
fi
assert_eq "P7: $P7_SCANNED scanned, $P7_SKIPPED skipped, $P7_CHECKED checked ($P7_DIRECT direct) — no stop-hook execution leaves stdin bare" \
  "$P7_FINDINGS" "0"

assert_file_contains "P7: tests/run-tests.sh runs every test file with stdin bound to /dev/null" \
  "$REPO_ROOT/tests/run-tests.sh" 'bash "$test_file" < /dev/null'

# === P7b: the fixture provenance this test reads declares no ACCIDENTAL ATX heading ===
# `#155` at line start is one to every ATX-aware reader; a `#` inside a fenced block is not.
_p7b_stray_headings() {
  awk '/^```/ { fence = !fence; next } !fence && /^#+[^# ]/ { n++ } END { print n+0 }' "$1"
}
for _p7b_fx in stop-payload stop-payload-synthetic; do
  assert_eq "P7b: tests/fixtures/$_p7b_fx/PROVENANCE.md is readable at all" \
    "$([ -r "$FIXTURES/$_p7b_fx/PROVENANCE.md" ] && echo yes || echo no)" "yes"
  assert_eq "P7b: tests/fixtures/$_p7b_fx/PROVENANCE.md starts no line with a bare-# reference" \
    "$(_p7b_stray_headings "$FIXTURES/$_p7b_fx/PROVENANCE.md")" "0"
done

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
