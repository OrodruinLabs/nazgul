#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-parallel-dispatch-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/parallel-dispatch-guard.sh"

# Build an isolated execution.parallel fixture.
setup() {
  setup_temp_dir
  mkdir -p "$TEST_DIR/nazgul/tasks"
  create_config '.execution.parallel = true'
  WORK="$TEST_DIR"
}
teardown() { teardown_temp_dir; }

# helper: build the Agent PreToolUse envelope and return the guard's exit code
guard_ec() { # <subagent_type> <run_in_background> <prompt>
  local ec=0
  jq -n --arg t "$1" --argjson bg "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$t,run_in_background:$bg,prompt:$p}}' \
    | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

# helper: same envelope, but return the guard's stderr instead of its exit code
guard_stderr() { # <subagent_type> <run_in_background> <prompt>
  jq -n --arg t "$1" --argjson bg "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$t,run_in_background:$bg,prompt:$p}}' \
    | bash "$GUARD" 2>&1 >/dev/null || true
}

setup
create_task_file TASK-001 READY
create_task_file_with_commits TASK-002 DONE "abc1234"
create_task_file_with_commits TASK-003 IMPLEMENTED "def5678"

# 1. background implementer dispatch of a not-yet-done unit -> ALLOW (exit 0):
#    background/concurrent dispatch from the main session is now the intended
#    mechanism for the parallel execution option, not a violation (was Rule 1
#    in the old conductor guard; deleted by design).
assert_eq "background implementer allowed (intended mechanism)" "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "0"
# 2. synchronous first dispatch of a READY unit -> ALLOW (exit 0)
assert_eq "sync first dispatch allowed" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-001")" "0"
# 3. re-dispatch of a DONE unit -> DENY (exit 2)
assert_eq "re-dispatch of DONE unit denied" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "2"
# 4. non-work-unit background dispatch (e.g. general-purpose) -> ALLOW
assert_eq "non-unit background allowed" "$(guard_ec "general-purpose" true "helper")" "0"
# 5. review-gate dispatch for an IMPLEMENTED unit -> ALLOW (the legitimate next step, not a re-dispatch)
assert_eq "review-gate on IMPLEMENTED unit allowed" "$(guard_ec "nazgul:review-gate" false "NAZGUL_UNIT: TASK-003")" "0"
# 6. review-gate re-dispatch for a DONE unit -> DENY (already reviewed, wasted work)
assert_eq "review-gate on DONE unit denied" "$(guard_ec "nazgul:review-gate" false "NAZGUL_UNIT: TASK-002")" "2"
# 7. implementer re-dispatch for an IMPLEMENTED unit -> DENY (implementation already done)
assert_eq "implementer on IMPLEMENTED unit denied" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-003")" "2"
# 8. no NAZGUL_UNIT line for a non-work-unit agent -> ALLOW
assert_eq "no unit line, non-work-unit agent allowed" "$(guard_ec "general-purpose" false "no unit here")" "0"
# 9. unknown task id -> ALLOW (no manifest to check status against)
assert_eq "unknown task id allowed" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-999")" "0"
teardown

# 10. off: execution.parallel=false -> ALLOW everything (no-op)
setup
create_task_file_with_commits TASK-002 DONE "abc1234"
jq '.execution.parallel = false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "parallel=false no-op" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "0"
teardown

# 11. kill-switch: dispatch_guard=false -> ALLOW everything (operator safety valve)
setup
create_task_file_with_commits TASK-002 DONE "abc1234"
jq '.execution.enforce.dispatch_guard = false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "kill-switch allows DONE re-dispatch" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "0"
teardown

# 12. kill-switch absent (default) -> still ENFORCES (deny DONE re-dispatch)
setup
create_task_file_with_commits TASK-002 DONE "abc1234"
jq 'del(.execution.enforce.dispatch_guard)' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "absent kill-switch still enforces" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "2"
teardown

# 13-16. MF-053 fail-closed: a present-but-unparseable config.json must BLOCK
# re-dispatch of an already-DONE unit (not silently no-op as "parallel=false"
# would), across every torn/corrupt shape a real write can leave on disk. A
# genuinely absent config is the one case that still safely no-ops (case 17).
for shape in corrupt empty truncated; do
  setup
  create_task_file_with_commits TASK-002 DONE "abc1234"
  case "$shape" in
    corrupt)   printf 'not json' > "$WORK/nazgul/config.json" ;;
    empty)     : > "$WORK/nazgul/config.json" ;;
    truncated) printf '{"execution": {"para' > "$WORK/nazgul/config.json" ;;
  esac
  assert_eq "$shape config fails closed (DONE re-dispatch blocked)" \
    "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "2"
  assert_contains "$shape config diagnostic names the reason" \
    "$(guard_stderr "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" \
    "config.json is unreadable"
  teardown
done

# 17. missing config.json entirely -> still safely no-ops (ALLOW), distinct
# from "present but unparseable" above.
setup
rm -f "$WORK/nazgul/config.json"
create_task_file_with_commits TASK-002 DONE "abc1234"
assert_eq "missing config still no-ops (allowed)" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "0"
teardown

report_results
