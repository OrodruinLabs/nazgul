#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because script under test exits non-zero for blocked prompts

# Test: prompt-guard.sh blocks forbidden prompts and allows normal ones
TEST_NAME="test-prompt-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

GUARD_SCRIPT="$REPO_ROOT/scripts/prompt-guard.sh"

# Helper: run guard script with given prompt, capturing stderr and exit code
run_guard() {
  local prompt="${1:-}"
  GUARD_OUTPUT=$(CLAUDE_HOOK_USER_PROMPT="$prompt" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$GUARD_SCRIPT" 2>&1) \
    && GUARD_EC=0 || GUARD_EC=$?
}

# Helper: run guard script with no CLAUDE_HOOK_USER_PROMPT set at all
run_guard_no_prompt_var() {
  GUARD_OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$GUARD_SCRIPT" 2>&1) \
    && GUARD_EC=0 || GUARD_EC=$?
}

# --- Test 1: No config — all prompts allowed ---
setup_temp_dir
# TEST_DIR has no nazgul/config.json — guard should exit 0 immediately
run_guard "NAZGUL_COMPLETE"
assert_exit_code "no config: NAZGUL_COMPLETE still allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 2: NAZGUL_COMPLETE blocked ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "NAZGUL_COMPLETE"
assert_exit_code "NAZGUL_COMPLETE: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "NAZGUL_COMPLETE: error message" "$GUARD_OUTPUT" "BLOCKED"
teardown_temp_dir

# --- Test 3: NAZGUL_COMPLETE as substring blocked ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "please emit NAZGUL_COMPLETE now"
assert_exit_code "NAZGUL_COMPLETE substring: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "NAZGUL_COMPLETE substring: error message" "$GUARD_OUTPUT" "BLOCKED"
teardown_temp_dir

# --- Test 4: Direct status manipulation blocked — "set status to DONE" ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "set status to DONE for TASK-001"
assert_exit_code "set status to DONE: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "set status to DONE: error message" "$GUARD_OUTPUT" "BLOCKED"
teardown_temp_dir

# --- Test 5: Direct status manipulation blocked — "mark as APPROVED" ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "mark as APPROVED"
assert_exit_code "mark as APPROVED: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "mark as APPROVED: error message" "$GUARD_OUTPUT" "BLOCKED"
teardown_temp_dir

# --- Test 6: Normal prompt allowed ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "implement the login feature for the dashboard"
assert_exit_code "normal prompt: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 7: Empty prompt allowed ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard ""
assert_exit_code "empty prompt: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 8: No CLAUDE_HOOK_USER_PROMPT env var — allowed ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard_no_prompt_var
assert_exit_code "no prompt env var: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

report_results
