#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-subagent-stop"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

HOOK="$REPO_ROOT/scripts/subagent-stop.sh"

_seed_events() {
  local events_file="$1"; shift
  mkdir -p "$(dirname "$events_file")"
  for task_id in "$@"; do
    printf '{"sv":1,"ts":"2026-01-01T00:00:00Z","event":"reviewer_verdict","task_id":"%s","reviewer":"code-reviewer","decision":"APPROVE","confidence":95,"iteration":3}\n' \
      "$task_id" >> "$events_file"
  done
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
  assert_contains "group: each record has GROUP- unit" "$line" '"review_unit":"GROUP-'
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

# --- Test 9: bash -n + shellcheck on subagent-stop.sh ---
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
