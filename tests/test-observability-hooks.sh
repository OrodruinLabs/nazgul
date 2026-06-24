#!/usr/bin/env bash
set -euo pipefail

# Test: observability hooks — each hook emits a correctly-typed line to
# events.jsonl and no longer appends to its legacy file.
TEST_NAME="test-observability-hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

STOP_FAILURE="$REPO_ROOT/scripts/stop-failure.sh"
SUBAGENT_STOP="$REPO_ROOT/scripts/subagent-stop.sh"
TASK_COMPLETED="$REPO_ROOT/scripts/task-completed.sh"
POST_COMPACT="$REPO_ROOT/scripts/post-compact.sh"
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

# --- Syntax checks ---
if bash -n "$STOP_FAILURE" 2>/dev/null; then _pass "stop-failure.sh parses"; else _fail "stop-failure.sh parses"; fi
if bash -n "$SUBAGENT_STOP" 2>/dev/null; then _pass "subagent-stop.sh parses"; else _fail "subagent-stop.sh parses"; fi
if bash -n "$TASK_COMPLETED" 2>/dev/null; then _pass "task-completed.sh parses"; else _fail "task-completed.sh parses"; fi
if bash -n "$POST_COMPACT" 2>/dev/null; then _pass "post-compact.sh parses"; else _fail "post-compact.sh parses"; fi

# ---------------------------------------------------------------------------
# stop-failure.sh
# ---------------------------------------------------------------------------

# --- stop-failure.sh: no-op when Nazgul not initialized ---
setup_temp_dir
rc=0; echo '{}' | "$STOP_FAILURE" >/dev/null 2>&1 || rc=$?
assert_exit_code "stop-failure exits 0 without config" "$rc" 0
assert_file_not_exists "no events.jsonl created without config" "$TEST_DIR/nazgul/logs/events.jsonl"
teardown_temp_dir

# --- stop-failure.sh: emits stop_failure to events.jsonl ---
setup_temp_dir
setup_nazgul_dir
create_config
rc=0; echo '{"session_id":"abc"}' | "$STOP_FAILURE" >/dev/null 2>&1 || rc=$?
assert_exit_code "stop-failure exits 0 with config" "$rc" 0
assert_file_exists "creates events.jsonl" "$TEST_DIR/nazgul/logs/events.jsonl"
assert_file_contains "events.jsonl has stop_failure event type" "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"stop_failure"'
assert_file_contains "events.jsonl has sv field" "$TEST_DIR/nazgul/logs/events.jsonl" '"sv":1'
assert_file_not_exists "no legacy iterations.jsonl created" "$TEST_DIR/nazgul/logs/iterations.jsonl"
assert_file_exists "writes .stop_failure breadcrumb" "$TEST_DIR/nazgul/.stop_failure"
teardown_temp_dir

# --- stop-failure.sh: bus_enabled:false makes emit a no-op ---
setup_temp_dir
setup_nazgul_dir
create_config '.telemetry.bus_enabled = false'
echo '{}' | "$STOP_FAILURE" >/dev/null 2>&1 || true
assert_file_not_exists "stop-failure no-op when bus_enabled false" "$TEST_DIR/nazgul/logs/events.jsonl"
teardown_temp_dir

# ---------------------------------------------------------------------------
# subagent-stop.sh
# ---------------------------------------------------------------------------

# --- subagent-stop.sh: no-op when Nazgul not initialized ---
setup_temp_dir
rc=0; echo '{}' | "$SUBAGENT_STOP" >/dev/null 2>&1 || rc=$?
assert_exit_code "subagent-stop exits 0 without config" "$rc" 0
assert_file_not_exists "no events.jsonl created without config" "$TEST_DIR/nazgul/logs/events.jsonl"
teardown_temp_dir

# --- subagent-stop.sh: emits subagent_stop to events.jsonl ---
setup_temp_dir
setup_nazgul_dir
create_config
rc=0; echo '{"subagent_type":"planner"}' | "$SUBAGENT_STOP" >/dev/null 2>&1 || rc=$?
assert_exit_code "subagent-stop exits 0 with config" "$rc" 0
assert_file_exists "creates events.jsonl" "$TEST_DIR/nazgul/logs/events.jsonl"
assert_file_contains "events.jsonl has subagent_stop event type" "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"subagent_stop"'
assert_file_contains "events.jsonl has sv field" "$TEST_DIR/nazgul/logs/events.jsonl" '"sv":1'
assert_file_contains "extracts agent name from input" "$TEST_DIR/nazgul/logs/events.jsonl" '"agent":"planner"'
assert_file_not_exists "no legacy subagents.jsonl created" "$TEST_DIR/nazgul/logs/subagents.jsonl"
teardown_temp_dir

# --- subagent-stop.sh: defaults agent to unknown when absent ---
setup_temp_dir
setup_nazgul_dir
create_config
echo '{}' | "$SUBAGENT_STOP" >/dev/null 2>&1 || true
assert_file_contains "defaults missing agent to unknown" "$TEST_DIR/nazgul/logs/events.jsonl" '"agent":"unknown"'
teardown_temp_dir

# --- subagent-stop.sh: iteration is null (does not read config) ---
setup_temp_dir
setup_nazgul_dir
create_config '.current_iteration = 7'
echo '{}' | "$SUBAGENT_STOP" >/dev/null 2>&1 || true
assert_file_contains "subagent_stop iteration is null" "$TEST_DIR/nazgul/logs/events.jsonl" '"iteration":null'
teardown_temp_dir

# --- subagent-stop.sh: bus_enabled:false makes emit a no-op ---
setup_temp_dir
setup_nazgul_dir
create_config '.telemetry.bus_enabled = false'
echo '{}' | "$SUBAGENT_STOP" >/dev/null 2>&1 || true
assert_file_not_exists "subagent-stop no-op when bus_enabled false" "$TEST_DIR/nazgul/logs/events.jsonl"
teardown_temp_dir

# ---------------------------------------------------------------------------
# task-completed.sh
# ---------------------------------------------------------------------------

# --- task-completed.sh: no-op when Nazgul not initialized ---
setup_temp_dir
rc=0; "$TASK_COMPLETED" >/dev/null 2>&1 || rc=$?
assert_exit_code "task-completed exits 0 without config" "$rc" 0
assert_file_not_exists "no events.jsonl created without config" "$TEST_DIR/nazgul/logs/events.jsonl"
teardown_temp_dir

# --- task-completed.sh: emits task_completed to events.jsonl ---
setup_temp_dir
setup_nazgul_dir
create_config
rc=0; "$TASK_COMPLETED" >/dev/null 2>&1 || rc=$?
assert_exit_code "task-completed exits 0 with config" "$rc" 0
assert_file_exists "creates events.jsonl" "$TEST_DIR/nazgul/logs/events.jsonl"
assert_file_contains "events.jsonl has task_completed event type" "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"task_completed"'
assert_file_contains "events.jsonl has sv field" "$TEST_DIR/nazgul/logs/events.jsonl" '"sv":1'
assert_file_not_exists "no legacy iterations.jsonl created" "$TEST_DIR/nazgul/logs/iterations.jsonl"
teardown_temp_dir

# --- task-completed.sh: best-effort task_id from stdin (task_id field) ---
setup_temp_dir
setup_nazgul_dir
create_config
echo '{"task_id":"TASK-042"}' | "$TASK_COMPLETED" >/dev/null 2>&1 || true
assert_file_contains "task_id extracted from stdin task_id field" "$TEST_DIR/nazgul/logs/events.jsonl" '"task_id":"TASK-042"'
teardown_temp_dir

# --- task-completed.sh: taskId alias also works ---
setup_temp_dir
setup_nazgul_dir
create_config
echo '{"taskId":"TASK-007"}' | "$TASK_COMPLETED" >/dev/null 2>&1 || true
assert_file_contains "task_id extracted from stdin taskId field" "$TEST_DIR/nazgul/logs/events.jsonl" '"task_id":"TASK-007"'
teardown_temp_dir

# --- task-completed.sh: defaults task_id to unknown (CONCERN 2) ---
setup_temp_dir
setup_nazgul_dir
create_config
echo '{}' | "$TASK_COMPLETED" >/dev/null 2>&1 || true
assert_file_contains "task_id defaults to unknown" "$TEST_DIR/nazgul/logs/events.jsonl" '"task_id":"unknown"'
teardown_temp_dir

# --- task-completed.sh: bus_enabled:false makes emit a no-op ---
setup_temp_dir
setup_nazgul_dir
create_config '.telemetry.bus_enabled = false'
"$TASK_COMPLETED" >/dev/null 2>&1 || true
assert_file_not_exists "task-completed no-op when bus_enabled false" "$TEST_DIR/nazgul/logs/events.jsonl"
teardown_temp_dir

# ---------------------------------------------------------------------------
# post-compact.sh
# ---------------------------------------------------------------------------

# --- post-compact.sh: emits compaction to events.jsonl ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
rc=0; "$POST_COMPACT" >/dev/null 2>&1 || rc=$?
assert_exit_code "post-compact exits 0" "$rc" 0
assert_file_exists "creates events.jsonl" "$TEST_DIR/nazgul/logs/events.jsonl"
assert_file_contains "events.jsonl has compaction event type" "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"compaction"'
assert_file_contains "events.jsonl has sv field" "$TEST_DIR/nazgul/logs/events.jsonl" '"sv":1'
assert_file_contains "compaction has compaction_index" "$TEST_DIR/nazgul/logs/events.jsonl" '"compaction_index":1'
assert_file_contains "compaction has iteration_at_compact" "$TEST_DIR/nazgul/logs/events.jsonl" '"iteration_at_compact":5'
teardown_temp_dir

# --- post-compact.sh: bus_enabled:false → no emit but counter still updated ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.telemetry.bus_enabled = false'
"$POST_COMPACT" >/dev/null 2>&1 || true
assert_file_not_exists "post-compact no emit when bus_enabled false" "$TEST_DIR/nazgul/logs/events.jsonl"
assert_file_exists "counter file still updated when bus disabled" "$TEST_DIR/nazgul/.compaction_count"
teardown_temp_dir

# --- post-compact.sh: no-op when Nazgul not initialized ---
setup_temp_dir
rc=0; "$POST_COMPACT" >/dev/null 2>&1 || rc=$?
assert_exit_code "post-compact exits 0 without config" "$rc" 0
assert_file_not_exists "no events.jsonl created without config" \
  "$TEST_DIR/nazgul/logs/events.jsonl"
teardown_temp_dir

# ---------------------------------------------------------------------------
# stop-hook.sh — iteration_boundary emit
# ---------------------------------------------------------------------------

# --- stop-hook.sh: emits iteration_boundary to events.jsonl ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$STOP_HOOK" >/dev/null 2>&1 || rc=$?
assert_file_contains "iteration_boundary emitted" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"iteration_boundary"'
assert_file_contains "iteration_boundary has done field" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"done"'
assert_file_contains "iteration_boundary has total field" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"total"'
teardown_temp_dir

# ---------------------------------------------------------------------------
# emit resilience — unwritable events.jsonl must not change hook exit code
# ---------------------------------------------------------------------------

# --- emit resilience: unwritable events.jsonl does not change hook exit code ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/logs"
touch "$TEST_DIR/nazgul/logs/events.jsonl"
chmod 444 "$TEST_DIR/nazgul/logs/events.jsonl"
rc=0; echo '{}' | "$STOP_FAILURE" >/dev/null 2>&1 || rc=$?
assert_exit_code "emit resilience: stop-failure exits 0 even with read-only events.jsonl" "$rc" 0
chmod 644 "$TEST_DIR/nazgul/logs/events.jsonl"
teardown_temp_dir

report_results
