#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-conductor-premerge-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/conductor-premerge-guard.sh"

# Build an isolated conductor-run fixture.
setup() {
  WORK=$(mktemp -d); export CLAUDE_PROJECT_DIR="$WORK"
  mkdir -p "$WORK/nazgul/conductor"
  jq -n '{schema_version:22,execution:{engine:"conductor"},conductor:{enforce:{premerge_guard:true}}}' > "$WORK/nazgul/config.json"
  : > "$WORK/nazgul/conductor/.session"
  jq -n '{tasks:{
    "TASK-001":{status:"READY",verdict:"",commit:""},
    "TASK-002":{status:"DONE",verdict:"APPROVE — all reviewers passed",commit:"abc1234"},
    "TASK-003":{status:"IMPLEMENTED",verdict:"",commit:"def5678"}
  }}' > "$WORK/nazgul/conductor/graph.json"
}
teardown() { rm -rf "$WORK"; unset CLAUDE_PROJECT_DIR; }

# helper: build the Bash PreToolUse envelope and return the guard's exit code
guard_ec() { # <command>
  local ec=0
  jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

MERGE_001='git merge feat/FEAT-009/TASK-001 --no-ff -m "merge TASK-001"'
MERGE_002='git merge feat/FEAT-009/TASK-002 --no-ff -m "merge TASK-002"'
MERGE_003='git merge feat/FEAT-009/TASK-003 --no-ff -m "merge TASK-003"'

setup
# 1. unreviewed merge (READY, no verdict) -> DENY (exit 2)
assert_eq "unreviewed-merge denied" "$(guard_ec "$MERGE_001")" "2"
# 2. reviewed merge (DONE + APPROVE) -> ALLOW (exit 0)
assert_eq "reviewed merge allowed" "$(guard_ec "$MERGE_002")" "0"
# 3. IMPLEMENTED-but-not-DONE merge -> DENY (exit 2)
assert_eq "implemented-not-done merge denied" "$(guard_ec "$MERGE_003")" "2"
# 4. non-merge command -> ALLOW (out of scope)
assert_eq "non-merge command allowed" "$(guard_ec "git status")" "0"
# 5. merge command with no recognizable unit branch -> degrade to allow
assert_eq "unrecognized branch degrades to allow" "$(guard_ec "git merge origin/main --no-ff")" "0"
teardown

# 6. non-conductor engine -> no-op (ALLOW)
setup; jq '.execution.engine="sequential"' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "sequential engine no-op" "$(guard_ec "$MERGE_001")" "0"
teardown

# 7. no .session marker -> no-op (ALLOW)
setup; rm -f "$WORK/nazgul/conductor/.session"
assert_eq "no session marker no-op" "$(guard_ec "$MERGE_001")" "0"
teardown

# 8. kill-switch off -> ALLOW even an unreviewed merge
setup; jq '.conductor.enforce.premerge_guard=false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "kill-switch off allows unreviewed merge" "$(guard_ec "$MERGE_001")" "0"
teardown

# 9. kill-switch absent (default) -> still enforces (DENY unreviewed merge)
setup; jq 'del(.conductor.enforce.premerge_guard)' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "absent kill-switch still enforces" "$(guard_ec "$MERGE_001")" "2"
teardown

# 10. degrade-to-allow: no graph.json -> ALLOW
setup; rm -f "$WORK/nazgul/conductor/graph.json"
assert_eq "no graph degrades to allow" "$(guard_ec "$MERGE_001")" "0"
teardown

# 11. degrade-to-allow: unreadable config -> ALLOW
setup; rm -f "$WORK/nazgul/config.json"
assert_eq "no config degrades to allow" "$(guard_ec "$MERGE_001")" "0"
teardown

# 12. degrade-to-allow: empty stdin -> ALLOW
setup
ec=0
printf '' | bash "$GUARD" >/dev/null 2>&1 || ec=$?
assert_eq "empty stdin degrades to allow" "$ec" "0"
teardown

# 13. degrade-to-allow: jq absent -> ALLOW even an unreviewed merge. Build the
# JSON payload with the real jq first, then re-invoke the guard under a
# restricted PATH containing only the tools it needs besides jq.
setup
BASH_BIN=$(command -v bash)
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for tool in bash cat printf grep awk sort; do
  toolpath=$(command -v "$tool" 2>/dev/null) && ln -s "$toolpath" "$FAKEBIN/$tool"
done
PAYLOAD=$(jq -n --arg c "$MERGE_001" '{tool_name:"Bash",tool_input:{command:$c}}')
ec=0
PATH="$FAKEBIN" "$BASH_BIN" "$GUARD" <<<"$PAYLOAD" >/dev/null 2>&1 || ec=$?
assert_eq "no jq degrades to allow" "$ec" "0"
teardown

# 14. message-collision: an APPROVED unit's feat/.../TASK-NNN string sits inside the
# -m message while the real merge target is a DIFFERENT, unreviewed unit -> DENY
setup
assert_eq "message-collision denied" \
  "$(guard_ec 'git merge -m "ref feat/FEAT-009/TASK-002 for context" feat/FEAT-009/TASK-003 --no-ff')" "2"
teardown

# 15. &&-chained merges: each segment evaluated independently; second (unreviewed)
# merge must still be caught -> DENY
setup
assert_eq "chained merge denied" \
  "$(guard_ec 'git merge feat/FEAT-009/TASK-002 --no-ff && git merge feat/FEAT-009/TASK-003 --no-ff')" "2"
teardown

# 16. octopus merge: two branches in one invocation, one unreviewed -> DENY
setup
assert_eq "octopus merge denied" \
  "$(guard_ec 'git merge feat/FEAT-009/TASK-002 feat/FEAT-009/TASK-003 --no-ff')" "2"
teardown

# 17-24: fail-closed on detected-but-unresolvable merge forms (board-cited bypasses).
# All wrap or obscure a real, unreviewed (TASK-003) merge and must DENY.
setup
assert_eq "eval-wrapped merge denied" \
  "$(guard_ec 'eval "git merge feat/FEAT-009/TASK-003 --no-ff"')" "2"
assert_eq "bash -c wrapped merge denied" \
  "$(guard_ec "bash -c 'git merge feat/FEAT-009/TASK-003 --no-ff'")" "2"
assert_eq "sh -c wrapped merge denied" \
  "$(guard_ec "sh -c 'git merge feat/FEAT-009/TASK-003 --no-ff'")" "2"
assert_eq "bare subshell merge denied" \
  "$(guard_ec '(git merge feat/FEAT-009/TASK-003 --no-ff)')" "2"
assert_eq "env-wrapped merge denied" \
  "$(guard_ec 'env git merge feat/FEAT-009/TASK-003 --no-ff')" "2"
assert_eq "path-qualified git merge denied" \
  "$(guard_ec '/usr/bin/git merge feat/FEAT-009/TASK-003 --no-ff')" "2"
assert_eq "git -c global-option merge denied" \
  "$(guard_ec 'git -c x=y merge feat/FEAT-009/TASK-003 --no-ff')" "2"
assert_eq "git -C global-option merge denied" \
  "$(guard_ec 'git -C /some/path merge feat/FEAT-009/TASK-003 --no-ff')" "2"
teardown

# 25: reviewed merge via git -c global option still resolves and ALLOWs (proves
# the line-17 loosening doesn't over-block a resolvable reviewed merge).
setup
assert_eq "reviewed merge via git -c allowed" \
  "$(guard_ec 'git -c x=y merge feat/FEAT-009/TASK-002 --no-ff')" "0"
teardown

report_results
