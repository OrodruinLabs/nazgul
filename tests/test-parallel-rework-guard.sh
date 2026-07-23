#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="test-parallel-rework-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
echo "=== $TEST_NAME ==="
GUARD="$REPO_ROOT/scripts/parallel-rework-guard.sh"

# Build an isolated execution.parallel fixture.
setup() {
  setup_temp_dir
  mkdir -p "$TEST_DIR/nazgul/tasks"
  create_config '.execution.parallel = true'
  WORK="$TEST_DIR"
}
teardown() { teardown_temp_dir; }

# helper: task manifest with a real JSON-array `Files modified` scope (MF-025
# consumer fixture-realism — a bare comma-split would never match a real
# planner-shaped manifest) and an optional commit.
# Usage: create_owned_task <id> <status> <files-csv> [commit-sha]
create_owned_task() {
  local id="$1" status="$2" files="$3" commit="${4:-}"
  local files_json
  files_json=$(printf '%s' "$files" | jq -R -c 'split(",") | map(gsub("^\\s+|\\s+$";""))')
  create_task_file_with_files_modified "$id" "$status" "$files_json"
  if [ -n "$commit" ]; then
    printf -- '\n## Commits\n- %s\n' "$commit" >> "$TEST_DIR/nazgul/tasks/${id}.md"
  fi
}

# helper: build the Edit PreToolUse envelope and return the guard's exit code
guard_ec() { # <file_path>
  local ec=0
  jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

# helper: same envelope, but return the guard's stderr instead of its exit code
guard_stderr() { # <file_path>
  jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' | bash "$GUARD" 2>&1 >/dev/null || true
}

setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
create_owned_task TASK-002 READY "scripts/heartbeat.sh"
# 1. edit a file owned by a DONE+committed unit -> DENY (exit 2)
assert_eq "rework of committed unit denied" "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
# 2. edit a file owned by a READY (uncommitted, not-yet-scanned) unit -> ALLOW (exit 0)
assert_eq "first write of ready unit allowed" "$(guard_ec "scripts/heartbeat.sh")" "0"
# 3. edit an unrelated file -> ALLOW
assert_eq "out-of-scope file allowed" "$(guard_ec "docs/README.md")" "0"
teardown

# 4. off: execution.parallel=false -> ALLOW everything (no-op)
setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
jq '.execution.parallel = false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "parallel=false no-op" "$(guard_ec "scripts/lib/inbox-provider.sh")" "0"
teardown

# 5. kill-switch explicit false -> ALLOW even though unit is DONE+committed
setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
jq '.execution.enforce.rework_guard = false' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "kill-switch false allows rework" "$(guard_ec "scripts/lib/inbox-provider.sh")" "0"
teardown

# 6. rework_guard key absent entirely -> guard still enforces (default true)
setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
jq 'del(.execution.enforce.rework_guard)' "$WORK/nazgul/config.json" > "$WORK/c" && mv "$WORK/c" "$WORK/nazgul/config.json"
assert_eq "absent enforce key still denies" "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
teardown

# 7. IMPLEMENTED status (not just DONE) with a commit -> still DENY. A unit
# sits at IMPLEMENTED with a commit through its whole review window; the
# guard must treat it the same as DONE for ownership purposes.
setup
create_owned_task TASK-001 IMPLEMENTED "scripts/lib/inbox-provider.sh" "abc1234"
assert_eq "IMPLEMENTED with commit denied" "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
teardown

# 8. suffix-collision false positive: editing other/scripts/heartbeat.sh must
# NOT be treated as owned by a unit committed+scoped to scripts/heartbeat.sh,
# even though the edited path ends with "/scripts/heartbeat.sh".
setup
create_owned_task TASK-002 DONE "scripts/heartbeat.sh" "def5678"
assert_eq "suffix-collision path allowed" "$(guard_ec "other/scripts/heartbeat.sh")" "0"
teardown

# 9. /private-symlink false negative (macOS): CLAUDE_PROJECT_DIR is reported
# without the /private prefix but the tool gives back the symlink-normalized
# absolute path (/private$WORK/...). The normalized-relative form must still
# resolve to the scoped, committed file and be DENIED.
setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
assert_eq "private-symlink absolute path denied" \
  "$(guard_ec "/private${WORK}/scripts/lib/inbox-provider.sh")" "2"
teardown

# 10. cross-cutting exemption: TASK-003 is the current, commit-less IN_PROGRESS
# unit and ALSO declares scripts/lib/inbox-provider.sh in its own Files
# modified (a cross-cutting task touching a file TASK-001 already committed).
# The edit must be ALLOWED even though TASK-001 owns and committed that file.
setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
create_owned_task TASK-003 IN_PROGRESS "scripts/lib/inbox-provider.sh"
assert_eq "cross-cutting edit in current task's own scope allowed" \
  "$(guard_ec "scripts/lib/inbox-provider.sh")" "0"
teardown

# 11. true rework still blocked: TASK-003 is in-progress but does NOT declare
# scripts/lib/inbox-provider.sh in its own scope, so editing it is still
# rework of TASK-001's committed file, not a cross-cutting edit.
setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
create_owned_task TASK-003 IN_PROGRESS "scripts/other.sh"
assert_eq "rework outside current task's own scope still denied" \
  "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
teardown

# 12. ambiguous CURRENT (parallel wave): TWO simultaneously-dispatched,
# commit-less IN_PROGRESS units (TASK-003 and TASK-004) both declare the
# target file in their own Files modified. The guard has no caller-identity
# signal to tell which one is actually issuing the write, so it must fail
# closed and DENY rather than trust either borrowed scope.
setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
create_owned_task TASK-003 IN_PROGRESS "scripts/lib/inbox-provider.sh"
create_owned_task TASK-004 IN_PROGRESS "scripts/lib/inbox-provider.sh"
assert_eq "ambiguous two-unit CURRENT match denied (fail closed)" \
  "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
teardown

# 13. MF-025 accessor repoint: a real multi-item JSON-array `Files modified`
# value (brackets/quotes/comma, the shape a real planner manifest actually
# writes) must still be parsed correctly — the overlapping committed file is
# detected and re-work is blocked. A bare comma-split parser (the pre-fix
# behavior) could never match this shape.
setup
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh,scripts/heartbeat.sh" "abc1234"
assert_eq "multi-item JSON-array scope match blocks rework" \
  "$(guard_ec "scripts/heartbeat.sh")" "2"
teardown

# 14-17. MF-053 fail-closed: a present-but-unparseable config.json must BLOCK
# an edit into an already-committed unit's scope (not silently no-op as
# "parallel=false" would), across every torn/corrupt shape a real write can
# leave on disk. A genuinely absent config is the one case that still safely
# no-ops (case 18).
for shape in corrupt empty truncated; do
  setup
  create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
  case "$shape" in
    corrupt)   printf 'not json' > "$WORK/nazgul/config.json" ;;
    empty)     : > "$WORK/nazgul/config.json" ;;
    truncated) printf '{"execution": {"para' > "$WORK/nazgul/config.json" ;;
  esac
  assert_eq "$shape config fails closed (rework blocked)" \
    "$(guard_ec "scripts/lib/inbox-provider.sh")" "2"
  assert_contains "$shape config diagnostic names the reason" \
    "$(guard_stderr "scripts/lib/inbox-provider.sh")" \
    "config.json is unreadable"
  teardown
done

# 18. missing config.json entirely -> still safely no-ops (ALLOW), distinct
# from "present but unparseable" above.
setup
rm -f "$WORK/nazgul/config.json"
create_owned_task TASK-001 DONE "scripts/lib/inbox-provider.sh" "abc1234"
assert_eq "missing config still no-ops (allowed)" "$(guard_ec "scripts/lib/inbox-provider.sh")" "0"
teardown

report_results
