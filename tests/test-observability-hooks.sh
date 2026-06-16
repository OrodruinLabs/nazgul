#!/usr/bin/env bash
set -euo pipefail

# Test: StopFailure (stop-failure.sh) and SubagentStop (subagent-stop.sh) hooks.
TEST_NAME="test-observability-hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

STOP_FAILURE="$REPO_ROOT/scripts/stop-failure.sh"
SUBAGENT_STOP="$REPO_ROOT/scripts/subagent-stop.sh"

# --- Syntax ---
if bash -n "$STOP_FAILURE" 2>/dev/null; then _pass "stop-failure.sh parses"; else _fail "stop-failure.sh parses"; fi
if bash -n "$SUBAGENT_STOP" 2>/dev/null; then _pass "subagent-stop.sh parses"; else _fail "subagent-stop.sh parses"; fi

# --- stop-failure.sh: no-op when Nazgul not initialized ---
setup_temp_dir
rc=0; echo '{}' | "$STOP_FAILURE" >/dev/null 2>&1 || rc=$?
assert_exit_code "stop-failure exits 0 without config" "$rc" 0
assert_file_not_exists "no iteration log created without config" "$TEST_DIR/nazgul/logs/iterations.jsonl"
teardown_temp_dir

# --- stop-failure.sh: records failure when initialized ---
setup_temp_dir
setup_nazgul_dir
create_config
rc=0; echo '{"session_id":"abc"}' | "$STOP_FAILURE" >/dev/null 2>&1 || rc=$?
assert_exit_code "stop-failure exits 0 with config" "$rc" 0
assert_file_contains "logs stop_failure event" "$TEST_DIR/nazgul/logs/iterations.jsonl" '"event":"stop_failure"'
assert_file_exists "writes .stop_failure breadcrumb" "$TEST_DIR/nazgul/.stop_failure"
teardown_temp_dir

# --- subagent-stop.sh: no-op when Nazgul not initialized ---
setup_temp_dir
rc=0; echo '{}' | "$SUBAGENT_STOP" >/dev/null 2>&1 || rc=$?
assert_exit_code "subagent-stop exits 0 without config" "$rc" 0
assert_file_not_exists "no subagent log created without config" "$TEST_DIR/nazgul/logs/subagents.jsonl"
teardown_temp_dir

# --- subagent-stop.sh: records metric + extracts agent name ---
setup_temp_dir
setup_nazgul_dir
create_config
rc=0; echo '{"subagent_type":"planner"}' | "$SUBAGENT_STOP" >/dev/null 2>&1 || rc=$?
assert_exit_code "subagent-stop exits 0 with config" "$rc" 0
assert_file_contains "logs subagent_stop event" "$TEST_DIR/nazgul/logs/subagents.jsonl" '"event":"subagent_stop"'
assert_file_contains "extracts agent name from input" "$TEST_DIR/nazgul/logs/subagents.jsonl" '"agent":"planner"'
teardown_temp_dir

# --- subagent-stop.sh: defaults agent to unknown when absent ---
setup_temp_dir
setup_nazgul_dir
create_config
echo '{}' | "$SUBAGENT_STOP" >/dev/null 2>&1 || true
assert_file_contains "defaults missing agent to unknown" "$TEST_DIR/nazgul/logs/subagents.jsonl" '"agent":"unknown"'
teardown_temp_dir

report_results
