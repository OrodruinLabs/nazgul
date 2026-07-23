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
FINAL_TEXT="VERDICT: APPROVE - all acceptance criteria verified"
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
_write_fixture_transcript "$TRANSCRIPT" "VERDICT: APPROVE"

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
_write_fixture_transcript "$TRANSCRIPT" "VERDICT: APPROVE"

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
