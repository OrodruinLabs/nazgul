#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-conductor-rework-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/conductor-rework-guard.sh"

# Build an isolated conductor-run fixture.
setup() {
  WORK=$(mktemp -d); export CLAUDE_PROJECT_DIR="$WORK"
  mkdir -p "$WORK/nazgul/conductor"
  jq -n '{schema_version:20,execution:{engine:"conductor"},conductor:{enforce:{rework_guard:true}}}' > "$WORK/nazgul/config.json"
  : > "$WORK/nazgul/conductor/.session"
  jq -n '{tasks:{
    "TASK-001":{status:"DONE",commit:"abc1234",file_scope:["scripts/lib/inbox-provider.sh"]},
    "TASK-002":{status:"READY",file_scope:["scripts/heartbeat.sh"]}
  }}' > "$WORK/nazgul/conductor/graph.json"
}
teardown() { rm -rf "$WORK"; unset CLAUDE_PROJECT_DIR; }

# helper: build the Edit PreToolUse envelope and return the guard's exit code
guard_ec() { # <file_path>
  local ec=0
  jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

setup
# 1. edit a file owned by a DONE+committed unit -> DENY (exit 2)
assert_eq "rework of committed unit denied" "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
# 2. edit a file owned by a READY (uncommitted) unit -> ALLOW (exit 0)
assert_eq "first write of ready unit allowed" "$(guard_ec "scripts/heartbeat.sh")" "0"
# 3. edit an unrelated file -> ALLOW
assert_eq "out-of-scope file allowed" "$(guard_ec "docs/README.md")" "0"
teardown

# 4. off-conductor: engine=sequential -> ALLOW everything (no-op)
setup; jq '.execution.engine="sequential"' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "sequential engine no-op" "$(guard_ec "scripts/lib/inbox-provider.sh")" "0"
teardown

# 5. no .session marker -> ALLOW (no-op)
setup; rm -f "$WORK/nazgul/conductor/.session"
assert_eq "no session marker no-op" "$(guard_ec "scripts/lib/inbox-provider.sh")" "0"
teardown

# 6. kill-switch explicit false -> ALLOW even though unit is DONE+committed
setup; jq '.conductor.enforce.rework_guard=false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "kill-switch false allows rework" "$(guard_ec "scripts/lib/inbox-provider.sh")" "0"
teardown

# 7. rework_guard key absent entirely -> guard still enforces (default true)
setup; jq 'del(.conductor.enforce.rework_guard)' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "absent enforce key still denies" "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
teardown

# 8. IMPLEMENTED status (not just DONE) with a commit -> DENY
setup; jq '.tasks["TASK-001"].status="IMPLEMENTED"' "$WORK/nazgul/conductor/graph.json" > "$WORK/g" && mv "$WORK/g" "$WORK/nazgul/conductor/graph.json"
assert_eq "IMPLEMENTED with commit denied" "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
teardown

# 9. suffix-collision false positive: editing other/scripts/heartbeat.sh must
# NOT be treated as owned by a unit committed+scoped to scripts/heartbeat.sh,
# even though the edited path ends with "/scripts/heartbeat.sh". Make
# TASK-002 committed for this case so the collision is actually exercised.
setup
jq '.tasks["TASK-002"].status="DONE" | .tasks["TASK-002"].commit="def5678"' \
  "$WORK/nazgul/conductor/graph.json" > "$WORK/g" && mv "$WORK/g" "$WORK/nazgul/conductor/graph.json"
assert_eq "suffix-collision path allowed" "$(guard_ec "other/scripts/heartbeat.sh")" "0"
teardown

# 10. /private-symlink false negative (macOS): CLAUDE_PROJECT_DIR is reported
# without the /private prefix but the tool gives back the symlink-normalized
# absolute path (/private$WORK/...). The normalized-relative form must still
# resolve to the scoped, committed file and be DENIED. This is the exact
# false-negative from the review finding: pre-fix, REL stays absolute (the
# case-prefix-strip misses because "$WORK" != "/private$WORK"), no scope
# entry matches "/private$WORK/scripts/lib/inbox-provider.sh" verbatim, and
# the edit is silently ALLOWED.
setup
assert_eq "private-symlink absolute path denied" \
  "$(guard_ec "/private${WORK}/scripts/lib/inbox-provider.sh")" "2"
teardown

report_results
