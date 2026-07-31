#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-subagent-stop"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
# write_dispatch_manifest: builds a real, production-shaped .dispatch.json
# fixture (same helper review-gate itself calls) rather than hand-rolling one.
source "$REPO_ROOT/scripts/lib/review-provenance.sh"

echo "=== $TEST_NAME ==="

HOOK="$REPO_ROOT/scripts/subagent-stop.sh"

_sha256() {
  { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}'
}

# Real subagent-transcript-shaped JSONL: tool-use turn, tool-result turn, final text-only turn.
_write_fixture_transcript() {
  local path="$1" final_text="$2"
  mkdir -p "$(dirname "$path")"
  {
    printf '{"type":"assistant","agentId":"fixture-agent","message":{"role":"assistant","content":[{"type":"text","text":"Reading the diff..."}]}}\n'
    printf '{"type":"assistant","agentId":"fixture-agent","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{}}]}}\n'
    printf '{"type":"user","agentId":"fixture-agent","message":{"role":"user","content":[{"type":"tool_result","content":"file contents"}]}}\n'
    jq -cn --arg t "$final_text" \
      '{type:"assistant",agentId:"fixture-agent",message:{role:"assistant",content:[{type:"text",text:$t}]}}'
  } > "$path"
}

_seed_events() {
  local events_file="$1"; shift
  mkdir -p "$(dirname "$events_file")"
  for task_id in "$@"; do
    printf '{"sv":1,"ts":"2026-01-01T00:00:00Z","event":"reviewer_verdict","task_id":"%s","reviewer":"code-reviewer","decision":"APPROVE","confidence":95,"iteration":3}\n' \
      "$task_id" >> "$events_file"
  done
}

# Seeds one reviewer_verdict event carrying an explicit review_unit field —
# the post-fix emit contract (TASK-004) the coverage detector must read
# directly instead of inferring.
_seed_event_with_unit() {
  local events_file="$1" task_id="$2" review_unit="$3"
  mkdir -p "$(dirname "$events_file")"
  printf '{"sv":1,"ts":"2026-01-01T00:00:00Z","event":"reviewer_verdict","task_id":"%s","review_unit":"%s","reviewer":"code-reviewer","decision":"APPROVE","confidence":95,"iteration":3}\n' \
    "$task_id" "$review_unit" >> "$events_file"
}

# --- Test 1: review-gate subagent with one reviewer_verdict writes coverage record ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
_seed_events "$TEST_DIR/nazgul/logs/events.jsonl" "TASK-001"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "review-gate: exits 0" "$rc" "0"
assert_file_exists "review-gate: coverage file created" "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
coverage_line=$(tail -1 "$TEST_DIR/nazgul/logs/review-coverage.jsonl")
assert_contains "coverage record has task_id TASK-001" "$coverage_line" '"task_id":"TASK-001"'
assert_contains "coverage record has sv:1" "$coverage_line" '"sv":1'
assert_contains "coverage record has ts field" "$coverage_line" '"ts"'
assert_contains "single-task: granularity_used is task" "$coverage_line" '"granularity_used":"task"'
assert_contains "single-task: review_unit is TASK-001" "$coverage_line" '"review_unit":"TASK-001"'
assert_contains "coverage record has iteration field" "$coverage_line" '"iteration"'
assert_contains "coverage record has subagent_stop event in events.jsonl" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl")" '"event":"subagent_stop"'
teardown_temp_dir

# --- Test 2: review-gate with multiple tasks and group granularity ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"group"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
_seed_events "$TEST_DIR/nazgul/logs/events.jsonl" "TASK-001" "TASK-002"
mkdir -p "$TEST_DIR/nazgul/tasks"
printf -- '---\nstatus: IMPLEMENTED\n---\n# TASK-001\n- **Group**: 2\n' \
  > "$TEST_DIR/nazgul/tasks/TASK-001.md"
printf -- '---\nstatus: IMPLEMENTED\n---\n# TASK-002\n- **Group**: 2\n' \
  > "$TEST_DIR/nazgul/tasks/TASK-002.md"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "group: exits 0" "$rc" "0"
assert_file_exists "group: coverage file created" "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
line_count=$(wc -l < "$TEST_DIR/nazgul/logs/review-coverage.jsonl" | tr -d ' ')
assert_eq "group: two records written (one per task)" "$line_count" "2"
while IFS= read -r line; do
  assert_contains "group: each record has GROUP-2 unit" "$line" '"review_unit":"GROUP-2"'
  assert_contains "group: granularity_used is group" "$line" '"granularity_used":"group"'
done < "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
teardown_temp_dir

# --- Test 3: non-review-gate subagent writes no coverage record ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
_seed_events "$TEST_DIR/nazgul/logs/events.jsonl" "TASK-001"

HOOK_INPUT='{"subagent_type":"implementer"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "non-review-gate: exits 0" "$rc" "0"
assert_file_not_exists "non-review-gate: no coverage file written" \
  "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
teardown_temp_dir

# --- Test 4: missing events.jsonl is a silent no-op ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "missing events.jsonl: exits 0" "$rc" "0"
assert_file_not_exists "missing events.jsonl: no coverage file" \
  "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
teardown_temp_dir

# --- Test 5: events.jsonl with no reviewer_verdict events is a silent no-op ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '{"sv":1,"ts":"2026-01-01T00:00:00Z","event":"subagent_stop","agent":"implementer"}\n' \
  > "$TEST_DIR/nazgul/logs/events.jsonl"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "no reviewer_verdict events: exits 0" "$rc" "0"
assert_file_not_exists "no reviewer_verdict events: no coverage file" \
  "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
teardown_temp_dir

# --- Test 6: uninitialised Nazgul (no config.json) exits 0 and writes nothing ---
setup_temp_dir
export CLAUDE_PROJECT_DIR="$TEST_DIR"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "uninitialised: exits 0" "$rc" "0"
assert_file_not_exists "uninitialised: no coverage file" \
  "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
teardown_temp_dir

# --- Test 7: subagent_stop event always emitted (even for non-review-gate) ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

HOOK_INPUT='{"subagent_type":"implementer"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "non-review-gate: exits 0 and emits subagent_stop" "$rc" "0"
assert_file_exists "subagent_stop event emitted to events.jsonl" \
  "$TEST_DIR/nazgul/logs/events.jsonl"
assert_file_contains "events.jsonl has subagent_stop event" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"subagent_stop"'
teardown_temp_dir

# --- Test 8: feature granularity writes FEATURE-<feat_id> review_unit ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"feature"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
_seed_events "$TEST_DIR/nazgul/logs/events.jsonl" "TASK-001" "TASK-002"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "feature granularity: exits 0" "$rc" "0"
assert_file_exists "feature: coverage file created" "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
while IFS= read -r line; do
  assert_contains "feature: review_unit is FEATURE-FEAT-003" "$line" '"review_unit":"FEATURE-FEAT-003"'
  assert_contains "feature: granularity_used is feature" "$line" '"granularity_used":"feature"'
done < "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
teardown_temp_dir

# --- Test 9: event carrying review_unit "GROUP-1" is read directly (ground
# truth), not dropped by the unchanged TASK-[0-9]* task_id filter, and
# granularity_used is sourced from the event rather than inferred ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
_seed_event_with_unit "$TEST_DIR/nazgul/logs/events.jsonl" "TASK-001" "GROUP-1"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "ground-truth review_unit: exits 0" "$rc" "0"
assert_file_exists "ground-truth review_unit: coverage file created" \
  "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
coverage_line=$(tail -1 "$TEST_DIR/nazgul/logs/review-coverage.jsonl")
assert_contains "ground-truth review_unit: task_id not dropped" "$coverage_line" '"task_id":"TASK-001"'
assert_contains "ground-truth review_unit: review_unit is GROUP-1 from event" "$coverage_line" '"review_unit":"GROUP-1"'
assert_contains "ground-truth review_unit: granularity_used is group (sourced from event)" \
  "$coverage_line" '"granularity_used":"group"'
teardown_temp_dir

# --- Test 10: event carrying review_unit "FEATURE-FEAT-999" is read directly
# even though config granularity says "task" — ground truth wins over config
# inference ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
_seed_event_with_unit "$TEST_DIR/nazgul/logs/events.jsonl" "TASK-002" "FEATURE-FEAT-999"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "ground-truth feature unit: exits 0" "$rc" "0"
coverage_line=$(tail -1 "$TEST_DIR/nazgul/logs/review-coverage.jsonl")
assert_contains "ground-truth feature unit: review_unit is FEATURE-FEAT-999" \
  "$coverage_line" '"review_unit":"FEATURE-FEAT-999"'
assert_contains "ground-truth feature unit: granularity_used is feature" \
  "$coverage_line" '"granularity_used":"feature"'
teardown_temp_dir

# --- Test 11: mixed run — one task's event carries review_unit (ground truth
# wins, no fallback call), the other task's event is pre-fix (no review_unit
# field, falls back to resolve_review_unit reading the task manifest's Group
# field) — both resolve correctly in the same review-gate invocation ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"group"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
_seed_event_with_unit "$TEST_DIR/nazgul/logs/events.jsonl" "TASK-001" "GROUP-5"
_seed_events "$TEST_DIR/nazgul/logs/events.jsonl" "TASK-002"
mkdir -p "$TEST_DIR/nazgul/tasks"
printf -- '---\nstatus: IMPLEMENTED\n---\n# TASK-002\n- **Group**: 2\n' \
  > "$TEST_DIR/nazgul/tasks/TASK-002.md"

HOOK_INPUT='{"subagent_type":"review-gate"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "mixed pre/post-fix events: exits 0" "$rc" "0"
line_count=$(wc -l < "$TEST_DIR/nazgul/logs/review-coverage.jsonl" | tr -d ' ')
assert_eq "mixed pre/post-fix events: two records written" "$line_count" "2"
task001_line=$(grep '"task_id":"TASK-001"' "$TEST_DIR/nazgul/logs/review-coverage.jsonl")
task002_line=$(grep '"task_id":"TASK-002"' "$TEST_DIR/nazgul/logs/review-coverage.jsonl")
assert_contains "mixed: TASK-001 uses event's GROUP-5 (ground truth)" "$task001_line" '"review_unit":"GROUP-5"'
assert_contains "mixed: TASK-002 falls back to resolver's GROUP-2 (manifest field)" "$task002_line" '"review_unit":"GROUP-2"'
teardown_temp_dir

# --- Test 13: reviewer completion whose agent_type is in the unit's
# .dispatch.json `selected` roster gets a well-formed receipt appended ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "" "FEAT-003" "1" -- code-reviewer security-reviewer >/dev/null
FINAL_TEXT=$'---\nverdict: APPROVE\nconfidence: 95\n---\n\nAll acceptance criteria verified.'
TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture1.jsonl"
_write_fixture_transcript "$TRANSCRIPT" "$FINAL_TEXT"
EXPECTED_HASH=$(printf '%s' "$FINAL_TEXT" | _sha256)

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"code-reviewer",agent_id:"fixture-agent"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "receipt: exits 0" "$rc" "0"
assert_file_exists "receipt: review-receipts.jsonl created" "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
receipt_line=$(tail -1 "$TEST_DIR/nazgul/logs/review-receipts.jsonl")
assert_contains "receipt: unit is TASK-001" "$receipt_line" '"unit":"TASK-001"'
assert_contains "receipt: reviewer is code-reviewer" "$receipt_line" '"reviewer":"code-reviewer"'
assert_contains "receipt: hash matches sha256 of reviewer's final text" "$receipt_line" "\"hash\":\"$EXPECTED_HASH\""
assert_contains "receipt: has ts field" "$receipt_line" '"ts"'
teardown_temp_dir

# --- Test 14: non-reviewer completion (agent_type not in any unit's selected
# roster) appends no receipt and leaves existing telemetry unchanged ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "" "FEAT-003" "1" -- code-reviewer >/dev/null
TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture2.jsonl"
_write_fixture_transcript "$TRANSCRIPT" "irrelevant implementer output"

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"implementer",agent_id:"fixture-agent-2"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "non-reviewer: exits 0" "$rc" "0"
assert_file_not_exists "non-reviewer: no receipt file written" "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
assert_file_contains "non-reviewer: subagent_stop telemetry still recorded" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"subagent_stop"'
teardown_temp_dir

# --- Test 15: reviewer-named agent completes but no review unit has ANY
# dispatch manifest at all (nazgul/reviews/ empty) -> safe no-op, no crash ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture3.jsonl"
_write_fixture_transcript "$TRANSCRIPT" $'---\nverdict: APPROVE\nconfidence: 90\n---'

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"code-reviewer",agent_id:"fixture-agent-3"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "no dispatch manifest: exits 0" "$rc" "0"
assert_file_not_exists "no dispatch manifest: no receipt file written" "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
teardown_temp_dir

# --- Test 16: agent_transcript_path missing/unreadable -> safe no-op, no crash ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "" "FEAT-003" "1" -- code-reviewer >/dev/null

HOOK_INPUT='{"transcript_path":"/some/parent/session.jsonl","agent_transcript_path":"/nonexistent/path.jsonl","agent_type":"code-reviewer","agent_id":"fixture-agent-4"}'
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "missing agent_transcript_path: exits 0" "$rc" "0"
assert_file_not_exists "missing agent_transcript_path: no receipt file written" \
  "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
teardown_temp_dir

# --- Test 17: same reviewer name selected across two units' manifests ->
# receipt is attributed to exactly one unit (the most-recently-created
# manifest), not duplicated across both ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "" "FEAT-003" "1" -- code-reviewer >/dev/null
sleep 1.1
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-002" "" "FEAT-003" "1" -- code-reviewer >/dev/null
TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture5.jsonl"
_write_fixture_transcript "$TRANSCRIPT" $'---\nverdict: APPROVE\nconfidence: 90\n---'

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"code-reviewer",agent_id:"fixture-agent-5"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "ambiguous unit: exits 0" "$rc" "0"
line_count=$(wc -l < "$TEST_DIR/nazgul/logs/review-receipts.jsonl" | tr -d ' ')
assert_eq "ambiguous unit: exactly one receipt written" "$line_count" "1"
receipt_line=$(tail -1 "$TEST_DIR/nazgul/logs/review-receipts.jsonl")
assert_contains "ambiguous unit: attributed to the most-recently-created manifest (TASK-002)" \
  "$receipt_line" '"unit":"TASK-002"'
teardown_temp_dir

# --- Test 18 (test-plan #3, keystone): empty final_text with NO resolvable
# review-dispatch unit (simulating a standalone architect-ruling stall, not a
# board dispatch) still emits subagent_empty_return, with unit explicitly
# "unknown" rather than the event being silently skipped ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture6.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"architect",agent_id:"fixture-agent-6"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "keystone empty-return: exits 0" "$rc" "0"
assert_file_contains "keystone: subagent_empty_return event emitted" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"subagent_empty_return"'
empty_return_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "keystone: agent is architect" "$empty_return_line" '"agent":"architect"'
assert_contains "keystone: unit is explicit unknown sentinel" "$empty_return_line" '"unit":"unknown"'
assert_file_not_exists "keystone: no receipt written (unit unresolved)" \
  "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
teardown_temp_dir

# --- Test 19 (test-plan #4): empty final_text WITH a resolvable
# review-dispatch unit emits the event with the correct unit populated ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "" "FEAT-003" "1" -- code-reviewer >/dev/null
TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture7.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"code-reviewer",agent_id:"fixture-agent-7"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "resolvable-unit empty-return: exits 0" "$rc" "0"
empty_return_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "resolvable-unit: unit is TASK-001" "$empty_return_line" '"unit":"TASK-001"'
assert_file_not_exists "resolvable-unit: no receipt written (final_text empty)" \
  "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
teardown_temp_dir

# --- Test 20 (test-plan #6, regression floor): non-empty final_text with a
# resolvable unit emits NO subagent_empty_return event, and the pre-existing
# review-receipts.jsonl hashing behavior (LR-001/FEAT-017) is unchanged ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "" "FEAT-003" "1" -- code-reviewer >/dev/null
FINAL_TEXT=$'---\nverdict: APPROVE\nconfidence: 95\n---\n\nAll acceptance criteria verified.'
TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture8.jsonl"
_write_fixture_transcript "$TRANSCRIPT" "$FINAL_TEXT"
EXPECTED_HASH=$(printf '%s' "$FINAL_TEXT" | _sha256)

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"code-reviewer",agent_id:"fixture-agent-8"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "regression floor: exits 0" "$rc" "0"
assert_not_contains "regression floor: no subagent_empty_return event" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl")" '"event":"subagent_empty_return"'
receipt_line=$(tail -1 "$TEST_DIR/nazgul/logs/review-receipts.jsonl")
assert_contains "regression floor: receipt hash unchanged" "$receipt_line" "\"hash\":\"$EXPECTED_HASH\""
assert_contains "regression floor: receipt unit unchanged" "$receipt_line" '"unit":"TASK-001"'
teardown_temp_dir

# --- Test 21 (test-plan #7): turns_used on the emitted event matches the
# fixture transcript's actual count of type == "assistant" records ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture9.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""
EXPECTED_TURNS=$(jq -rs '[ .[] | select(.type == "assistant") ] | length' "$TRANSCRIPT")

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"architect",agent_id:"fixture-agent-9"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "turns_used: exits 0" "$rc" "0"
empty_return_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "turns_used: matches fixture assistant-record count ($EXPECTED_TURNS)" \
  "$empty_return_line" "\"turns_used\":$EXPECTED_TURNS"
teardown_temp_dir

# --- Test 22 (test-plan #8a): max_turns resolves from
# .claude/agents/generated/<agent>.md when a generated copy exists ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
mkdir -p "$TEST_DIR/.claude/agents/generated"
printf -- '---\nname: code-reviewer\nmaxTurns: 30\n---\n' \
  > "$TEST_DIR/.claude/agents/generated/code-reviewer.md"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture10.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"code-reviewer",agent_id:"fixture-agent-10"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "max_turns generated-copy: exits 0" "$rc" "0"
empty_return_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "max_turns generated-copy: resolves to 30" "$empty_return_line" '"max_turns":30'
teardown_temp_dir

# --- Test 23 (test-plan #8b): max_turns falls back to agents/<agent>.md when
# no generated copy exists (e.g. a standalone architect ruling agent) ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
mkdir -p "$TEST_DIR/agents"
printf -- '---\nname: architect\nmaxTurns: 40\n---\n' \
  > "$TEST_DIR/agents/architect.md"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture11.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"architect",agent_id:"fixture-agent-11"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "max_turns template-fallback: exits 0" "$rc" "0"
empty_return_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "max_turns template-fallback: resolves to 40" "$empty_return_line" '"max_turns":40'
teardown_temp_dir

# --- Test 24 (test-plan #8c): max_turns is explicitly null (never omitted)
# when neither a generated nor a committed spec file can be found ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture12.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"ghost-agent",agent_id:"fixture-agent-12"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "max_turns unresolved: exits 0" "$rc" "0"
empty_return_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "max_turns unresolved: field is explicit null, not omitted" \
  "$empty_return_line" '"max_turns":null'
teardown_temp_dir

# --- Test 25: agent_transcript_path missing/unreadable is an announced
# degradation — exits 0, no crash, but skip is stated on stderr, not silent ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

HOOK_INPUT='{"transcript_path":"/some/parent/session.jsonl","agent_transcript_path":"/nonexistent/path.jsonl","agent_type":"architect","agent_id":"fixture-agent-13"}'
output=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1); rc=$?
assert_exit_code "unreadable transcript: exits 0" "$rc" "0"
assert_contains "unreadable transcript: skip announced on stderr" "$output" \
  "skipping empty-return detection"
assert_file_not_exists "unreadable transcript: no empty-return event" \
  "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
teardown_temp_dir

# --- Test 26: a transcript file that is unparseable JSON is a detection
# error — announced on stderr, hook still exits 0, no crash ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"
TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture14.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
printf 'not valid json at all\n' > "$TRANSCRIPT"

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"architect",agent_id:"fixture-agent-14"}')
output=$(printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1); rc=$?
assert_exit_code "unparseable transcript: exits 0" "$rc" "0"
assert_contains "unparseable transcript: skip announced on stderr" "$output" \
  "skipping empty-return detection"
assert_not_contains "unparseable transcript: no subagent_empty_return event" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl")" '"event":"subagent_empty_return"'
teardown_temp_dir

# --- Test 27 (test-plan #5): reviewer with non-empty final_text and a
# resolvable review-dispatch unit, but no line matching the verdict: contract
# (real observed shape: mid-analysis trailing text, not a verdict block) ->
# emits subagent_empty_return with reason no_verdict_line and unit populated ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "" "FEAT-003" "1" -- architect-reviewer >/dev/null
NO_VERDICT_TEXT="I'm satisfied. Let me do a final check..."
TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture15.jsonl"
_write_fixture_transcript "$TRANSCRIPT" "$NO_VERDICT_TEXT"
EXPECTED_HASH=$(printf '%s' "$NO_VERDICT_TEXT" | _sha256)

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"architect-reviewer",agent_id:"fixture-agent-15"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "no-verdict-line reviewer: exits 0" "$rc" "0"
no_verdict_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "no-verdict-line reviewer: event emitted" "$no_verdict_line" '"agent":"architect-reviewer"'
assert_contains "no-verdict-line reviewer: reason is no_verdict_line" "$no_verdict_line" '"reason":"no_verdict_line"'
assert_contains "no-verdict-line reviewer: unit resolved to TASK-001" "$no_verdict_line" '"unit":"TASK-001"'
receipt_line=$(tail -1 "$TEST_DIR/nazgul/logs/review-receipts.jsonl")
assert_contains "no-verdict-line reviewer: receipt-hashing scope is untouched (still runs)" \
  "$receipt_line" "\"hash\":\"$EXPECTED_HASH\""
teardown_temp_dir

# --- Test 28 (test-plan #5, name-only signal): reviewer-named agent with NO
# dispatch manifest at all (unit stays "unknown") and non-empty final_text
# with no verdict line still emits the event -- reviewer identification by
# name alone does not depend on a resolvable dispatch manifest ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture16.jsonl"
_write_fixture_transcript "$TRANSCRIPT" "Reviewing the diff now, one moment..."

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"code-reviewer",agent_id:"fixture-agent-16"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "name-only reviewer signal: exits 0" "$rc" "0"
no_verdict_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "name-only reviewer signal: reason is no_verdict_line" "$no_verdict_line" '"reason":"no_verdict_line"'
assert_contains "name-only reviewer signal: unit is unresolved sentinel" "$no_verdict_line" '"unit":"unknown"'
teardown_temp_dir

# --- Test 29 (non-reviewer negative case): a NON-reviewer agent with
# non-empty final_text and no verdict-like text emits NO subagent_empty_return
# event at all -- non-reviewers have no verdict grammar to violate ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture17.jsonl"
_write_fixture_transcript "$TRANSCRIPT" "Implemented the feature and ran the tests."

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"implementer",agent_id:"fixture-agent-17"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "non-reviewer no-verdict text: exits 0" "$rc" "0"
assert_not_contains "non-reviewer no-verdict text: no subagent_empty_return event" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl")" '"event":"subagent_empty_return"'
teardown_temp_dir

# --- Test 30 (no double-count): a reviewer with EMPTY final_text emits only
# the TASK-004 empty_final_text event -- the verdict-line clause never also
# fires for the same completion (if/elif, not two independent checks) ---
setup_temp_dir
setup_nazgul_dir
printf '{"review_gate":{"granularity":"task"},"telemetry":{"bus_enabled":true},"feat_id":"FEAT-003"}' \
  > "$TEST_DIR/nazgul/config.json"
export CLAUDE_PROJECT_DIR="$TEST_DIR"

TRANSCRIPT="$TEST_DIR/transcripts/agent-fixture18.jsonl"
_write_fixture_transcript "$TRANSCRIPT" ""

HOOK_INPUT=$(jq -cn --arg tp "$TRANSCRIPT" \
  '{transcript_path:"/some/parent/session.jsonl",agent_transcript_path:$tp,agent_type:"code-reviewer",agent_id:"fixture-agent-18"}')
printf '%s' "$HOOK_INPUT" | bash "$HOOK" 2>&1; rc=$?
assert_exit_code "empty-text reviewer: exits 0" "$rc" "0"
event_count=$(grep -c '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_eq "empty-text reviewer: exactly one event (not double-counted)" "$event_count" "1"
empty_return_line=$(grep '"event":"subagent_empty_return"' "$TEST_DIR/nazgul/logs/events.jsonl")
assert_contains "empty-text reviewer: reason is empty_final_text" "$empty_return_line" '"reason":"empty_final_text"'
teardown_temp_dir

# --- Test 12: bash -n + shellcheck on subagent-stop.sh ---
bash -n "$HOOK" 2>/dev/null \
  && _pass "bash -n clean: subagent-stop.sh" \
  || _fail "bash -n clean: subagent-stop.sh" "syntax error detected"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$HOOK" 2>/dev/null \
    && _pass "shellcheck clean: subagent-stop.sh" \
    || _fail "shellcheck clean: subagent-stop.sh" "shellcheck warnings found"
else
  _pass "shellcheck skipped (not installed): subagent-stop.sh"
fi

report_results
