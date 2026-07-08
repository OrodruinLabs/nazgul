#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-conductor-dispatch-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/conductor-dispatch-guard.sh"

# Build an isolated conductor-run fixture.
setup() {
  WORK=$(mktemp -d); export CLAUDE_PROJECT_DIR="$WORK"
  mkdir -p "$WORK/nazgul/conductor"
  jq -n '{schema_version:20,execution:{engine:"conductor"},conductor:{enforce:{dispatch_guard:true}}}' > "$WORK/nazgul/config.json"
  : > "$WORK/nazgul/conductor/.session"
  jq -n '{tasks:{"TASK-001":{status:"READY"},"TASK-002":{status:"DONE",commit:"abc1234"},"TASK-003":{status:"IMPLEMENTED",commit:"def5678"}}}' > "$WORK/nazgul/conductor/graph.json"
}
teardown() { rm -rf "$WORK"; unset CLAUDE_PROJECT_DIR; }

# helper: build the Agent PreToolUse envelope and return the guard's exit code
guard_ec() { # <subagent_type> <run_in_background> <prompt>
  local ec=0
  jq -n --arg t "$1" --argjson bg "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$t,run_in_background:$bg,prompt:$p}}' \
    | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

setup
# 1. background implementer dispatch -> DENY (exit 2)
assert_eq "background implementer denied" "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "2"
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
teardown

# 8. off-conductor: engine=sequential -> ALLOW everything (no-op)
setup; jq '.execution.engine="sequential"' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "sequential engine no-op" "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "0"
teardown

# 9. no .session marker -> ALLOW (no-op)
setup; rm -f "$WORK/nazgul/conductor/.session"
assert_eq "no session marker no-op" "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "0"
teardown

# 10. kill-switch: dispatch_guard=false -> ALLOW everything (operator safety valve)
setup; jq '.conductor.enforce.dispatch_guard=false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "kill-switch allows background implementer" "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "0"
assert_eq "kill-switch allows DONE re-dispatch" "$(guard_ec "nazgul:implementer" false "NAZGUL_UNIT: TASK-002")" "0"
teardown

# 11. kill-switch absent (default) -> still ENFORCES (deny background implementer)
setup; jq 'del(.conductor.enforce.dispatch_guard)' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "absent kill-switch still enforces" "$(guard_ec "nazgul:implementer" true "NAZGUL_UNIT: TASK-001")" "2"
teardown

report_results
