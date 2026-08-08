#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-task-transition-command"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/task-utils.sh"
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"

COMMAND="$REPO_ROOT/scripts/task-transition.sh"
STATE_GUARD="$REPO_ROOT/scripts/task-state-guard.sh"
echo "=== $TEST_NAME ==="

setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/tasks"
create_config '.agents.reviewers = [] | .telemetry.bus_enabled = true'

run_transition() {
  local ec=0
  CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$COMMAND" "$@" >/dev/null 2>"$TEST_DIR/transition.err" || ec=$?
  echo "$ec"
}

guard_edit_ec() { # <task-id> <from> <to>
  local ec=0
  jq -nc --arg f "$TEST_DIR/nazgul/tasks/$1.md" --arg old "status: $2" --arg new "status: $3" \
    '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$old,new_string:$new}}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/guard.err" || ec=$?
  echo "$ec"
}

# PreToolUse validation is no longer authority. Merely asking to perform a
# legal edit is denied, leaves the file alone, and creates no ledger record.
create_task_file TASK-001 READY
assert_eq "direct status Edit is denied in favor of transactional command" \
  "$(guard_edit_ec TASK-001 READY IN_PROGRESS)" "2"
assert_contains "direct status Edit names the transactional command" \
  "$(cat "$TEST_DIR/guard.err")" "scripts/task-transition.sh transition TASK-001 READY IN_PROGRESS"
assert_eq "denied preflight leaves live status unchanged" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "READY"
assert_file_not_exists "denied preflight creates no completed-transition ledger" \
  "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"

# A later raw write cannot reuse the preflight because nothing was recorded.
set_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md" READY IN_PROGRESS
if ttg_transition_is_guarded "$TEST_DIR/nazgul" TASK-001 READY IN_PROGRESS "2000-01-01T00:00:00Z"; then
  _fail "raw write after denied preflight has no reusable authority" "unexpected exact ledger match"
else
  _pass "raw write after denied preflight has no reusable authority"
fi

# Happy path: disk changes first and the exact completed edge is recorded.
create_task_file TASK-002 READY
assert_eq "transaction command applies legal edge" \
  "$(run_transition transition TASK-002 READY IN_PROGRESS)" "0"
assert_eq "transaction command updates canonical disk status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "IN_PROGRESS"
assert_file_exists "completed transition ledger created" "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
TS=$(jq -r 'select(.task_id == "TASK-002") | .timestamp' "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl")
assert_eq "completed transition records its source snapshot hash" \
  "$(jq -r 'select(.task_id == "TASK-002") | .before_sha256 | test("^[0-9a-f]{64}$")' "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl")" "true"
assert_eq "completed transition records its verified target hash" \
  "$(jq -r 'select(.task_id == "TASK-002") | .after_sha256 | test("^[0-9a-f]{64}$")' "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl")" "true"
if ttg_transition_is_guarded "$TEST_DIR/nazgul" TASK-002 READY IN_PROGRESS "$TS"; then
  _pass "exact completed edge is queryable"
else
  _fail "exact completed edge is queryable" "READY -> IN_PROGRESS was not found"
fi
if ttg_transition_is_guarded "$TEST_DIR/nazgul" TASK-002 PLANNED IN_PROGRESS "$TS"; then
  _fail "same endpoint with wrong source is not authority" "PLANNED -> IN_PROGRESS matched READY -> IN_PROGRESS"
else
  _pass "same endpoint with wrong source is not authority"
fi

LEDGER_LINES=$(wc -l < "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl" | tr -d ' ')
assert_eq "stale source is rejected" "$(run_transition transition TASK-002 READY BLOCKED)" "1"
assert_eq "stale source preserves live status" "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "IN_PROGRESS"
assert_eq "stale source writes no authority record" \
  "$(wc -l < "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl" | tr -d ' ')" "$LEDGER_LINES"
assert_eq "invalid graph edge is rejected" "$(run_transition transition TASK-002 IN_PROGRESS DONE)" "1"
assert_eq "invalid edge preserves live status" "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "IN_PROGRESS"

# Evidence is checked before a staged write.
create_task_file TASK-003 IN_PROGRESS
assert_eq "IMPLEMENTED without commit/red-run evidence is rejected" \
  "$(run_transition transition TASK-003 IN_PROGRESS IMPLEMENTED)" "1"
assert_eq "failed evidence gate preserves status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-003.md")" "IN_PROGRESS"

# IDs resolve beneath the canonical tasks directory; a terminal symlink never
# becomes an arbitrary-file transition target.
create_task_file TASK-004 READY
mv "$TEST_DIR/nazgul/tasks/TASK-004.md" "$TEST_DIR/outside-task.md"
ln -s "$TEST_DIR/outside-task.md" "$TEST_DIR/nazgul/tasks/TASK-004.md"
assert_eq "symlink task manifest is rejected" "$(run_transition transition TASK-004 READY IN_PROGRESS)" "1"
assert_eq "symlink target remains unchanged" "$(get_task_status "$TEST_DIR/outside-task.md")" "READY"
LEAF_GUARD_EC=0
jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-004.md" --arg old 'status: READY' --arg new 'status: IN_PROGRESS' \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$old,new_string:$new}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/leaf.err" || LEAF_GUARD_EC=$?
assert_exit_code "symlink task leaf is rejected by preflight" "$LEAF_GUARD_EC" 2
assert_contains "task-leaf escape diagnostic is explicit" \
  "$(cat "$TEST_DIR/leaf.err")" "does not resolve to its canonical project runtime path"

# A symlinked tasks/ directory is also an escape, even though the leaf itself
# is a regular file. Both the command and the preflight guard reject it.
rm -f "$TEST_DIR/nazgul/tasks/TASK-004.md"
mv "$TEST_DIR/outside-task.md" "$TEST_DIR/nazgul/tasks/TASK-004.md"
ESCAPE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-taskdir.XXXXXX")
mv "$TEST_DIR/nazgul/tasks" "$ESCAPE_ROOT/tasks"
ln -s "$ESCAPE_ROOT/tasks" "$TEST_DIR/nazgul/tasks"
assert_eq "symlinked task directory is rejected by command" \
  "$(run_transition transition TASK-004 READY IN_PROGRESS)" "1"
TASKDIR_GUARD_EC=0
jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-004.md" --arg old 'status: READY' --arg new 'status: IN_PROGRESS' \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$old,new_string:$new}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/taskdir.err" || TASKDIR_GUARD_EC=$?
assert_exit_code "symlinked task directory is rejected by preflight" "$TASKDIR_GUARD_EC" 2
assert_contains "task-directory escape diagnostic is explicit" \
  "$(cat "$TEST_DIR/taskdir.err")" "does not resolve to its canonical project runtime path"
rm -f "$TEST_DIR/nazgul/tasks"
mv "$ESCAPE_ROOT/tasks" "$TEST_DIR/nazgul/tasks"
rmdir "$ESCAPE_ROOT"

# The same directory escape must fail even when its physical target remains
# under the project root (the generic source-file guard must not take over).
mv "$TEST_DIR/nazgul/tasks" "$TEST_DIR/alternate-tasks"
ln -s "$TEST_DIR/alternate-tasks" "$TEST_DIR/nazgul/tasks"
INPROJECT_DIR_EC=0
jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-004.md" --arg old 'status: READY' --arg new 'status: IN_PROGRESS' \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$old,new_string:$new}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/inproject-dir.err" || INPROJECT_DIR_EC=$?
assert_exit_code "in-project symlinked tasks directory is rejected" "$INPROJECT_DIR_EC" 2
assert_contains "in-project task-directory escape names canonical path" \
  "$(cat "$TEST_DIR/inproject-dir.err")" "does not resolve to its canonical project runtime path"
rm -f "$TEST_DIR/nazgul/tasks"
mv "$TEST_DIR/alternate-tasks" "$TEST_DIR/nazgul/tasks"

# A long external alias chain into a real task must fail closed when canonical
# resolution reaches its hop bound, never fall through as an outside write.
CHAIN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-chain.XXXXXX")
ln -s "$TEST_DIR/nazgul/tasks/TASK-004.md" "$CHAIN_DIR/link17"
CHAIN_I=16
while [ "$CHAIN_I" -ge 0 ]; do
  CHAIN_NEXT=$((CHAIN_I + 1))
  ln -s "$CHAIN_DIR/link${CHAIN_NEXT}" "$CHAIN_DIR/link${CHAIN_I}"
  CHAIN_I=$((CHAIN_I - 1))
done
CHAIN_EC=0
jq -nc --arg f "$CHAIN_DIR/link0" --arg old 'status: READY' --arg new 'status: IN_PROGRESS' \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$old,new_string:$new}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/chain.err" || CHAIN_EC=$?
assert_exit_code "overlong symlink alias fails closed" "$CHAIN_EC" 2
assert_contains "overlong symlink alias diagnostic is explicit" \
  "$(cat "$TEST_DIR/chain.err")" "overlong symlink chain"
rm -f "$CHAIN_DIR"/link*
rmdir "$CHAIN_DIR"

# Deterministic race: a PATH-wrapped cp mutates the live source immediately
# after staging. The final content comparison must fail and preserve that
# concurrent write instead of overwriting it with the staged status.
create_task_file TASK-005 READY
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-fakebin.XXXXXX")
cat > "$FAKEBIN/cp" <<'FAKECP'
#!/usr/bin/env bash
printf 'cp:%s\n' "$*" >> "${NAZGUL_TEST_CP_LOG:?}"
/bin/cp "$@" || exit $?
case "${1:-}" in
  */TASK-005.md) printf '\nconcurrent-metadata: preserved\n' >> "$1" ;;
esac
FAKECP
chmod +x "$FAKEBIN/cp"
RACE_EC=0
PATH="$FAKEBIN:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" NAZGUL_TEST_CP_LOG="$TEST_DIR/cp.log" \
  bash "$COMMAND" transition TASK-005 READY IN_PROGRESS \
  >/dev/null 2>"$TEST_DIR/race.err" || RACE_EC=$?
rm -f "$FAKEBIN/cp"
rmdir "$FAKEBIN"
assert_exit_code "concurrent manifest mutation aborts compare-before-replace" "$RACE_EC" 1
assert_eq "concurrent mutation keeps original status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-005.md")" "READY"
assert_contains "concurrent metadata is preserved" \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-005.md")" "concurrent-metadata: preserved"
assert_contains "race diagnostic is explicit" "$(cat "$TEST_DIR/race.err")" "changed while its transition was staged"

# Validation and the pre-replace comparison must use one immutable snapshot. Mutating the
# live manifest on the first hash invocation reproduces the old ordering:
# validation had already read the old bytes, then the hash/copy used new bytes
# and the transition succeeded. The staged-snapshot implementation detects it.
create_task_file TASK-008 READY
HASHBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-hashbin.XXXXXX")
REAL_SHA256SUM=$(command -v sha256sum)
cat > "$HASHBIN/sha256sum" <<'FAKEHASH'
#!/usr/bin/env bash
if [ ! -f "${NAZGUL_TEST_HASH_MARKER:?}" ]; then
  : > "$NAZGUL_TEST_HASH_MARKER"
  printf '\nconcurrent-evidence: changed-before-hash\n' >> "${NAZGUL_TEST_MUTATE_FILE:?}"
fi
exec "${NAZGUL_REAL_SHA256SUM:?}"
FAKEHASH
chmod +x "$HASHBIN/sha256sum"
SNAPSHOT_EC=0
PATH="$HASHBIN:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" \
  NAZGUL_REAL_SHA256SUM="$REAL_SHA256SUM" \
  NAZGUL_TEST_HASH_MARKER="$TEST_DIR/hash.marker" \
  NAZGUL_TEST_MUTATE_FILE="$TEST_DIR/nazgul/tasks/TASK-008.md" \
  bash "$COMMAND" transition TASK-008 READY IN_PROGRESS \
  >/dev/null 2>"$TEST_DIR/snapshot.err" || SNAPSHOT_EC=$?
rm -f "$HASHBIN/sha256sum"
rmdir "$HASHBIN"
assert_exit_code "validation is bound to the staged snapshot" "$SNAPSHOT_EC" 1
assert_eq "snapshot race preserves source status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-008.md")" "READY"
assert_contains "snapshot race preserves concurrent bytes" \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-008.md")" "concurrent-evidence: changed-before-hash"

# Transition locks fail closed, and a reason is written in the same atomic
# replacement when a BLOCKED edge succeeds.
create_task_file TASK-006 READY
mkdir -p "$TEST_DIR/nazgul/locks/task-transition-TASK-006.lock"
assert_eq "held per-task lock blocks concurrent transition" \
  "$(run_transition transition TASK-006 READY IN_PROGRESS)" "1"
assert_eq "held lock preserves status" "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-006.md")" "READY"
LOCKED_EDIT_EC=0
jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-006.md" \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"- **Group**: 1",new_string:"- **Group**: 2"}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/locked-edit.err" || LOCKED_EDIT_EC=$?
assert_exit_code "held transition lock blocks cooperative metadata edit" "$LOCKED_EDIT_EC" 2
assert_contains "held transition lock diagnostic names in-flight writer" \
  "$(cat "$TEST_DIR/locked-edit.err")" "in-flight transactional transition"
rmdir "$TEST_DIR/nazgul/locks/task-transition-TASK-006.lock"

# Locks left by a process that no longer exists are reclaimed; the ownerless
# lock above stays fail-closed for as long as it is inside the orphan grace.
create_task_file TASK-009 READY
mkdir -p "$TEST_DIR/nazgul/locks/task-transition-TASK-009.lock"
printf '99999999 deadbeef\n' \
  > "$TEST_DIR/nazgul/locks/task-transition-TASK-009.lock/owner.99999999.deadbeef"
assert_eq "dead-owner per-task lock is recovered" \
  "$(run_transition transition TASK-009 READY IN_PROGRESS)" "0"
assert_eq "recovered lock transition reaches target" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-009.md")" "IN_PROGRESS"

# An ownerless lock directory carries no ownership to prove dead, so it used to
# be unreclaimable forever: mkdir fails, the owner glob matches nothing, and
# per-task callers pass attempts=1 — every later transition for that task
# wedged until a human ran rmdir. It is now reclaimable once it has outlived
# the grace period, and only then.
create_task_file TASK-043 READY
ORPHAN_LOCK="$TEST_DIR/nazgul/locks/task-transition-TASK-043.lock"
mkdir -p "$ORPHAN_LOCK"
assert_eq "ownerless lock inside the grace period still fails closed" \
  "$(run_transition transition TASK-043 READY IN_PROGRESS)" "1"
assert_dir_exists "ownerless lock inside the grace period is preserved" "$ORPHAN_LOCK"
assert_eq "fail-closed ownerless lock preserves status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-043.md")" "READY"
touch -t 200001010000 "$ORPHAN_LOCK"
assert_eq "ownerless lock older than the grace period is reclaimed" \
  "$(run_transition transition TASK-043 READY IN_PROGRESS)" "0"
assert_eq "reclaimed ownerless lock transition reaches target" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-043.md")" "IN_PROGRESS"
assert_dir_not_exists "reclaimed ownerless lock is released again" "$ORPHAN_LOCK"

# The other half of that window: a writer signalled after its mkdir but before
# its owner-file write publishes its token anyway, so the caller's release trap
# clears the directory it created instead of leaving an orphan behind.
UNOWNED_LOCK="$TEST_DIR/nazgul/locks/unowned-release-test.lock"
mkdir -p "$UNOWNED_LOCK"
if _ttg_release_lock "$UNOWNED_LOCK" "deadbeef"; then
  _pass "release clears a claimed-but-never-owned lock directory"
else
  _fail "release clears a claimed-but-never-owned lock directory" "expected: 0" "  actual: nonzero"
fi
assert_dir_not_exists "claimed-but-never-owned lock is gone after release" "$UNOWNED_LOCK"

FOREIGN_LOCK="$TEST_DIR/nazgul/locks/foreign-release-test.lock"
mkdir -p "$FOREIGN_LOCK"
printf '99999999 cafebabe\n' > "$FOREIGN_LOCK/owner.99999999.cafebabe"
if _ttg_release_lock "$FOREIGN_LOCK" "deadbeef"; then
  _fail "release never removes a lock owned by someone else" "expected: nonzero" "  actual: 0"
else
  _pass "release never removes a lock owned by someone else"
fi
assert_dir_exists "foreign lock survives a mismatched release" "$FOREIGN_LOCK"
rm -f "$FOREIGN_LOCK/owner.99999999.cafebabe"
rmdir "$FOREIGN_LOCK"

create_task_file TASK-007 READY
assert_eq "single-line BLOCKED reason is committed with status" \
  "$(run_transition transition TASK-007 READY BLOCKED '--reason=dependency unavailable')" "0"
assert_eq "BLOCKED reason transition updates status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-007.md")" "BLOCKED"
assert_contains "BLOCKED reason persisted" "$(cat "$TEST_DIR/nazgul/tasks/TASK-007.md")" \
  "- **Blocked reason**: dependency unavailable"

create_task_file TASK-010 READY
chmod 640 "$TEST_DIR/nazgul/tasks/TASK-010.md"
assert_eq "space-separated --reason form succeeds" \
  "$(run_transition transition TASK-010 READY BLOCKED --reason 'literal\nbackslash')" "0"
assert_contains "reason preserves literal backslashes" \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-010.md")" '- **Blocked reason**: literal\nbackslash'
assert_eq "transition preserves task manifest mode" \
  "$(_ttg_file_mode "$TEST_DIR/nazgul/tasks/TASK-010.md")" "640"

create_task_file TASK-011 READY
assert_eq "reason is rejected for a non-BLOCKED target" \
  "$(run_transition transition TASK-011 READY IN_PROGRESS --reason unrelated)" "1"
assert_eq "rejected irrelevant reason preserves status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-011.md")" "READY"

# Distinct task locks may proceed together. Hold the shared ledger lock briefly
# so both commands queue at the same critical section, then prove both exact
# completed edges survive serialization.
create_task_file TASK-012 READY
create_task_file TASK-013 READY
mkdir -p "$TEST_DIR/nazgul/logs/.guarded-transitions.lock"
printf '%s helddeadbeef\n' "$$" \
  > "$TEST_DIR/nazgul/logs/.guarded-transitions.lock/owner.$$.helddeadbeef"
P1_EC=0; P2_EC=0
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$COMMAND" transition TASK-012 READY IN_PROGRESS \
  >/dev/null 2>"$TEST_DIR/parallel-1.err" & P1=$!
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$COMMAND" transition TASK-013 READY IN_PROGRESS \
  >/dev/null 2>"$TEST_DIR/parallel-2.err" & P2=$!
sleep 0.05
rm -f "$TEST_DIR/nazgul/logs/.guarded-transitions.lock/owner.$$.helddeadbeef"
rmdir "$TEST_DIR/nazgul/logs/.guarded-transitions.lock"
wait "$P1" || P1_EC=$?
wait "$P2" || P2_EC=$?
assert_exit_code "first concurrent task records authority" "$P1_EC" 0
assert_exit_code "second concurrent task records authority" "$P2_EC" 0
assert_eq "concurrent task ledger retains both exact edges" \
  "$(jq -s '[.[] | select((.task_id == "TASK-012" or .task_id == "TASK-013") and .from == "READY" and .to == "IN_PROGRESS")] | length' "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl")" "2"

create_task_file TASK-019 READY
SAME1_EC=0; SAME2_EC=0
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$COMMAND" transition TASK-019 READY IN_PROGRESS \
  >/dev/null 2>"$TEST_DIR/same-1.err" & SAME1=$!
CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$COMMAND" transition TASK-019 READY BLOCKED --reason competing \
  >/dev/null 2>"$TEST_DIR/same-2.err" & SAME2=$!
wait "$SAME1" || SAME1_EC=$?
wait "$SAME2" || SAME2_EC=$?
SAME_SUCCESSES=0
[ "$SAME1_EC" -eq 0 ] && SAME_SUCCESSES=$((SAME_SUCCESSES + 1))
[ "$SAME2_EC" -eq 0 ] && SAME_SUCCESSES=$((SAME_SUCCESSES + 1))
assert_eq "same-task competing transitions have exactly one winner" "$SAME_SUCCESSES" "1"
assert_eq "same-task winner records exactly one authority edge" \
  "$(jq -s '[.[] | select(.task_id == "TASK-019")] | length' "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl")" "1"

create_task_file TASK-020 READY
mkdir -p "$TEST_DIR/nazgul/logs/.guarded-transitions.lock"
printf '99999999 cafebabe\n' \
  > "$TEST_DIR/nazgul/logs/.guarded-transitions.lock/owner.99999999.cafebabe"
assert_eq "dead-owner ledger lock is recovered" \
  "$(run_transition transition TASK-020 READY IN_PROGRESS)" "0"
assert_eq "recovered ledger lock retains the completed edge" \
  "$(jq -s '[.[] | select(.task_id == "TASK-020" and .from == "READY" and .to == "IN_PROGRESS")] | length' "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl")" "1"

# Once disk replacement succeeds, a logger failure is loud but may not invent
# authority. TASK-003's reconciliation path owns recovery from this state.
create_task_file TASK-021 READY
mv "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl" "$TEST_DIR/nazgul/logs/guarded-transitions.saved"
printf '%s\n' '{"task_id":"TASK-021","from":"READY","to":"IN_PROGRESS","timestamp":"2099-01-01T00:00:00Z"}' \
  > "$TEST_DIR/ledger-symlink-target"
ln -s "$TEST_DIR/ledger-symlink-target" "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
assert_eq "ledger failure after disk replacement returns nonzero" \
  "$(run_transition transition TASK-021 READY IN_PROGRESS)" "1"
assert_eq "ledger failure does not roll back a completed disk write" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-021.md")" "IN_PROGRESS"
assert_eq "ledger symlink target is never overwritten" \
  "$(jq -r '.task_id' "$TEST_DIR/ledger-symlink-target")" "TASK-021"
if ttg_transition_is_guarded "$TEST_DIR/nazgul" TASK-021 READY IN_PROGRESS "2000-01-01T00:00:00Z"; then
  _fail "ledger reader rejects external symlink authority" "forged external ledger was trusted"
else
  _pass "ledger reader rejects external symlink authority"
fi
rm -f "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
mv "$TEST_DIR/nazgul/logs/guarded-transitions.saved" "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
if ttg_transition_is_guarded "$TEST_DIR/nazgul" TASK-021 READY IN_PROGRESS "2000-01-01T00:00:00Z"; then
  _fail "failed logger creates no false authority" "unexpected TASK-021 edge"
else
  _pass "failed logger creates no false authority"
fi

# Observe the logger boundary itself: by the time its jq encoder runs, the
# canonical manifest must already expose the target state on disk.
create_task_file TASK-022 READY
JQBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-jqbin.XXXXXX")
REAL_JQ=$(command -v jq)
cat > "$JQBIN/jq" <<'FAKEJQ'
#!/usr/bin/env bash
case " $* " in
  *" TASK-022 "*)
    awk -F ': ' '/^status:/ {print $2; exit}' "${NAZGUL_TEST_OBSERVED_TASK:?}" > "${NAZGUL_TEST_OBSERVED_STATUS:?}"
    ;;
esac
exec "${NAZGUL_REAL_JQ:?}" "$@"
FAKEJQ
chmod +x "$JQBIN/jq"
LOGGER_EC=0
PATH="$JQBIN:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" NAZGUL_REAL_JQ="$REAL_JQ" \
  NAZGUL_TEST_OBSERVED_TASK="$TEST_DIR/nazgul/tasks/TASK-022.md" \
  NAZGUL_TEST_OBSERVED_STATUS="$TEST_DIR/logger-observed.status" \
  bash "$COMMAND" transition TASK-022 READY IN_PROGRESS \
  >/dev/null 2>"$TEST_DIR/logger.err" || LOGGER_EC=$?
rm -f "$JQBIN/jq"
rmdir "$JQBIN"
assert_exit_code "logger-boundary observation transition succeeds" "$LOGGER_EC" 0
assert_eq "logger observes target already present on disk" \
  "$(cat "$TEST_DIR/logger-observed.status")" "IN_PROGRESS"

assert_eq "lowercase task id is rejected" \
  "$(run_transition transition task-022 IN_PROGRESS BLOCKED --reason invalid-id)" "1"
assert_eq "path-shaped task id is rejected" \
  "$(run_transition transition 'TASK-022/../../outside' IN_PROGRESS BLOCKED --reason invalid-id)" "1"

# Readiness is part of the authoritative transition, so dependency state cannot
# be bypassed by calling the command directly.
create_config '.afk.yolo = false'
create_task_file TASK-023 DONE
create_task_file TASK-024 PLANNED TASK-023
assert_eq "DONE dependency permits PLANNED to READY" \
  "$(run_transition transition TASK-024 PLANNED READY)" "0"
create_task_file TASK-025 READY
create_task_file TASK-026 PLANNED TASK-025
assert_eq "unfinished dependency blocks PLANNED to READY" \
  "$(run_transition transition TASK-026 PLANNED READY)" "1"
assert_eq "dependency rejection preserves PLANNED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-026.md")" "PLANNED"
create_config '.afk.yolo = true'
create_task_file TASK-027 APPROVED
create_task_file TASK-028 PLANNED TASK-027
assert_eq "APPROVED dependency permits READY in YOLO mode" \
  "$(run_transition transition TASK-028 PLANNED READY)" "0"
create_task_file TASK-034 PLANNED
sed -i.bak '/^- \*\*Depends on\*\*:/d' "$TEST_DIR/nazgul/tasks/TASK-034.md"
rm -f "$TEST_DIR/nazgul/tasks/TASK-034.md.bak"
assert_eq "missing Depends on field fails closed" \
  "$(run_transition transition TASK-034 PLANNED READY)" "1"
create_task_file TASK-035 PLANNED
printf '%s\n' '- **Depends on**: none' >> "$TEST_DIR/nazgul/tasks/TASK-035.md"
assert_eq "duplicate Depends on fields fail closed" \
  "$(run_transition transition TASK-035 PLANNED READY)" "1"
create_task_file TASK-036 PLANNED '../outside'
assert_eq "path-shaped dependency id fails closed" \
  "$(run_transition transition TASK-036 PLANNED READY)" "1"
create_task_file TASK-040 PLANNED 'TASK-*'
: > "$TEST_DIR/TASK-023"
WILDCARD_DEP_EC=0
( cd "$TEST_DIR" && CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$COMMAND" \
    transition TASK-040 PLANNED READY >/dev/null 2>"$TEST_DIR/wildcard-dependency.err" ) \
  || WILDCARD_DEP_EC=$?
rm -f "$TEST_DIR/TASK-023"
assert_exit_code "wildcard dependency is parsed literally, never pathname-expanded" \
  "$WILDCARD_DEP_EC" 1
assert_eq "wildcard dependency rejection preserves PLANNED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-040.md")" "PLANNED"

# Runtime control directories and review units are never followed through
# symlinks or free-form path metadata.
create_config '.afk.yolo = false'
create_task_file TASK-029 READY
HOSTILE_LOCK=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-hostile-lock.XXXXXX")
printf '99999999\n' > "$HOSTILE_LOCK/owner"
ln -s "$HOSTILE_LOCK" "$TEST_DIR/nazgul/locks/task-transition-TASK-029.lock"
assert_eq "symlink lock object fails closed" \
  "$(run_transition transition TASK-029 READY IN_PROGRESS)" "1"
assert_eq "symlink lock rejection does not delete external owner" \
  "$(cat "$HOSTILE_LOCK/owner")" "99999999"
rm -f "$TEST_DIR/nazgul/locks/task-transition-TASK-029.lock" "$HOSTILE_LOCK/owner"
rmdir "$HOSTILE_LOCK"

create_task_file TASK-030 READY
mv "$TEST_DIR/nazgul/logs" "$TEST_DIR/alternate-logs"
ln -s "$TEST_DIR/alternate-logs" "$TEST_DIR/nazgul/logs"
assert_eq "symlinked logs directory fails before disk replacement" \
  "$(run_transition transition TASK-030 READY IN_PROGRESS)" "1"
assert_eq "symlinked logs rejection preserves source status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-030.md")" "READY"
rm -f "$TEST_DIR/nazgul/logs"
mv "$TEST_DIR/alternate-logs" "$TEST_DIR/nazgul/logs"

create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.require_provenance = false'
create_task_file TASK-031 IN_REVIEW
mkdir -p "$TEST_DIR/nazgul/reviews"
EXTERNAL_REVIEW=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-review.XXXXXX")
cat > "$EXTERNAL_REVIEW/code-reviewer.md" <<'EXTERNAL_REVIEW_EOF'
# External review
## Verdict: APPROVED
EXTERNAL_REVIEW_EOF
ln -s "$EXTERNAL_REVIEW" "$TEST_DIR/nazgul/reviews/TASK-031"
assert_eq "symlink review directory is never completion evidence" \
  "$(run_transition transition TASK-031 IN_REVIEW DONE)" "1"
assert_eq "symlink review rejection preserves IN_REVIEW" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-031.md")" "IN_REVIEW"
rm -f "$TEST_DIR/nazgul/reviews/TASK-031" "$EXTERNAL_REVIEW/code-reviewer.md"
rmdir "$EXTERNAL_REVIEW"

create_task_file TASK-037 IN_REVIEW
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-037"
EXTERNAL_REVIEW_FILE=$(mktemp "${TMPDIR:-/tmp}/nazgul-transition-review-file.XXXXXX")
printf '%s\n' '# External review' '## Verdict: APPROVED' > "$EXTERNAL_REVIEW_FILE"
ln -s "$EXTERNAL_REVIEW_FILE" "$TEST_DIR/nazgul/reviews/TASK-037/code-reviewer.md"
assert_eq "symlink reviewer file is never completion evidence" \
  "$(run_transition transition TASK-037 IN_REVIEW DONE)" "1"
assert_eq "symlink reviewer rejection preserves IN_REVIEW" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-037.md")" "IN_REVIEW"
rm -f "$TEST_DIR/nazgul/reviews/TASK-037/code-reviewer.md" "$EXTERNAL_REVIEW_FILE"
rmdir "$TEST_DIR/nazgul/reviews/TASK-037"

create_config '.review_gate.granularity = "group"'
create_task_file TASK-032 IMPLEMENTED
sed -i.bak 's/^- \*\*Group\*\*:.*/- **Group**: ..\/outside/' "$TEST_DIR/nazgul/tasks/TASK-032.md"
rm -f "$TEST_DIR/nazgul/tasks/TASK-032.md.bak"
assert_eq "path-shaped review unit metadata is rejected" \
  "$(run_transition transition TASK-032 IMPLEMENTED IN_REVIEW)" "1"

# A failed ledger read must not be hidden by the following printf or replace
# the historical ledger with a one-line file.
create_config '.afk.yolo = false'
create_task_file TASK-033 READY
TAILBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-tailbin.XXXXXX")
cat > "$TAILBIN/tail" <<'FAILTAIL'
#!/usr/bin/env bash
exit 9
FAILTAIL
chmod +x "$TAILBIN/tail"
LEDGER_COUNT_BEFORE=$(wc -l < "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl" | tr -d ' ')
TAIL_EC=0
PATH="$TAILBIN:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR" \
  bash "$COMMAND" transition TASK-033 READY IN_PROGRESS \
  >/dev/null 2>"$TEST_DIR/tail.err" || TAIL_EC=$?
rm -f "$TAILBIN/tail"
rmdir "$TAILBIN"
assert_exit_code "failed ledger tail is reported" "$TAIL_EC" 1
assert_eq "failed ledger tail preserves existing authority history" \
  "$(wc -l < "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl" | tr -d ' ')" "$LEDGER_COUNT_BEFORE"
if ttg_transition_is_guarded "$TEST_DIR/nazgul" TASK-033 READY IN_PROGRESS "2000-01-01T00:00:00Z"; then
  _fail "failed ledger tail records no new authority" "unexpected TASK-033 edge"
else
  _pass "failed ledger tail records no new authority"
fi

# Bash 3.2 keeps $$ unchanged across subshells. A loser from the same sourced
# shell must not release a winner's lock merely because their PIDs match.
TOKEN_LOCK="$TEST_DIR/nazgul/locks/shared-pid-token-test.lock"
TOKEN_READY="$TEST_DIR/token-lock.ready"
(
  TOKEN_ACQUIRED=false; TOKEN_VALUE=""
  trap '[ "$TOKEN_ACQUIRED" != true ] || _ttg_release_lock "$TOKEN_LOCK" "$TOKEN_VALUE" 2>/dev/null || true' EXIT
  _ttg_acquire_lock "$TOKEN_LOCK" 1 || exit 1
  TOKEN_VALUE="$TTG_LOCK_TOKEN"; TOKEN_ACQUIRED=true
  printf 'ready\n' > "$TOKEN_READY"
  sleep 0.3
) & TOKEN_WINNER=$!
TOKEN_POLLS=0
while [ ! -f "$TOKEN_READY" ] && [ "$TOKEN_POLLS" -lt 100 ]; do
  sleep 0.01
  TOKEN_POLLS=$((TOKEN_POLLS + 1))
done
TOKEN_LOSER_EC=0
(
  TOKEN_ACQUIRED=false; TOKEN_VALUE=""
  trap '[ "$TOKEN_ACQUIRED" != true ] || _ttg_release_lock "$TOKEN_LOCK" "$TOKEN_VALUE" 2>/dev/null || true' EXIT
  if _ttg_acquire_lock "$TOKEN_LOCK" 1; then
    TOKEN_VALUE="$TTG_LOCK_TOKEN"; TOKEN_ACQUIRED=true
    exit 0
  fi
  exit 1
) || TOKEN_LOSER_EC=$?
assert_exit_code "same-PID sourced lock contender loses" "$TOKEN_LOSER_EC" 1
if [ -d "$TOKEN_LOCK" ]; then
  _pass "loser cannot release winner lock with shared Bash 3.2 PID"
else
  _fail "loser cannot release winner lock with shared Bash 3.2 PID" "winner lock disappeared"
fi
wait "$TOKEN_WINNER"
assert_dir_not_exists "winner releases only its own tokenized lock" "$TOKEN_LOCK"

# Two contenders may observe the same stale owner. Exactly one can reclaim it;
# the loser must never unlink the winner's tokenized owner (the stale-lock ABA
# regression found during independent review).
ABA_LOCK="$TEST_DIR/nazgul/locks/stale-aba-test.lock"
mkdir "$ABA_LOCK"
printf '99999999 abadcafe\n' > "$ABA_LOCK/owner.99999999.abadcafe"
ABA_GO="$TEST_DIR/stale-aba.go"
ABA_HELD="$TEST_DIR/stale-aba.held"
for ABA_I in 1 2; do
  (
    : > "$TEST_DIR/stale-aba.ready.$ABA_I"
    while [ ! -f "$ABA_GO" ]; do sleep 0.01; done
    if _ttg_acquire_lock "$ABA_LOCK" 1; then
      ABA_TOKEN="$TTG_LOCK_TOKEN"
      printf 'winner\n' > "$TEST_DIR/stale-aba.result.$ABA_I"
      : > "$ABA_HELD"
      sleep 0.2
      [ -f "$ABA_LOCK/owner.$$.${ABA_TOKEN}" ] \
        || printf 'winner-owner-removed\n' > "$TEST_DIR/stale-aba.corrupt"
      _ttg_release_lock "$ABA_LOCK" "$ABA_TOKEN"
    else
      printf 'loser\n' > "$TEST_DIR/stale-aba.result.$ABA_I"
    fi
  ) &
  eval "ABA_PID_${ABA_I}=\$!"
done
ABA_POLLS=0
while { [ ! -f "$TEST_DIR/stale-aba.ready.1" ] || [ ! -f "$TEST_DIR/stale-aba.ready.2" ]; } \
  && [ "$ABA_POLLS" -lt 100 ]; do
  sleep 0.01
  ABA_POLLS=$((ABA_POLLS + 1))
done
: > "$ABA_GO"
wait "$ABA_PID_1"
wait "$ABA_PID_2"
assert_eq "two stale-lock contenders produce exactly one winner" \
  "$(grep -h '^winner$' "$TEST_DIR"/stale-aba.result.* 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "two stale-lock contenders produce exactly one loser" \
  "$(grep -h '^loser$' "$TEST_DIR"/stale-aba.result.* 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_file_not_exists "stale-lock loser never removes the winner owner" \
  "$TEST_DIR/stale-aba.corrupt"
assert_file_exists "stale-lock winner reached its protected critical section" "$ABA_HELD"
assert_dir_not_exists "stale-lock winner releases the reclaimed lock" "$ABA_LOCK"

# Completion targets are mode-specific and evidence/provenance checks live in
# the transaction command, not just in the diagnostic preflight hook.
create_config '.agents.reviewers = ["code-reviewer"]' '.afk.yolo = false' '.afk.task_pr = false'
create_task_file TASK-015 IN_REVIEW
create_review_dir TASK-015
assert_eq "APPROVED target is rejected outside YOLO task-PR mode" \
  "$(run_transition transition TASK-015 IN_REVIEW APPROVED)" "1"
assert_eq "wrong completion target preserves IN_REVIEW" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-015.md")" "IN_REVIEW"

create_config '.agents.reviewers = ["code-reviewer"]' '.afk.yolo = true' '.afk.task_pr = false'
create_task_file TASK-016 IN_REVIEW
assert_eq "YOLO without task PR still requires review evidence for DONE" \
  "$(run_transition transition TASK-016 IN_REVIEW DONE)" "1"
create_review_dir TASK-016
assert_eq "YOLO without task PR completes through reviewed DONE" \
  "$(run_transition transition TASK-016 IN_REVIEW DONE)" "0"

create_config '.agents.reviewers = ["code-reviewer"]' '.afk.yolo = true' '.afk.task_pr = true'
create_task_file TASK-017 IN_REVIEW
create_review_dir TASK-017
assert_eq "YOLO task-PR mode rejects direct IN_REVIEW to DONE" \
  "$(run_transition transition TASK-017 IN_REVIEW DONE)" "1"
assert_eq "YOLO task-PR mode completes review through APPROVED" \
  "$(run_transition transition TASK-017 IN_REVIEW APPROVED)" "0"
assert_eq "YOLO task-PR APPROVED completes through DONE" \
  "$(run_transition transition TASK-017 APPROVED DONE)" "0"

create_config '.agents.reviewers = ["code-reviewer"]' '.afk.yolo = true' '.afk.task_pr = false'
create_task_file TASK-040 IN_REVIEW
create_review_dir TASK-040
assert_eq "YOLO without task PR rejects APPROVED target" \
  "$(run_transition transition TASK-040 IN_REVIEW APPROVED)" "1"

create_config '.agents.reviewers = ["code-reviewer"]' '.afk.yolo = false' '.afk.task_pr = true'
create_task_file TASK-041 IN_REVIEW
create_review_dir TASK-041
assert_eq "non-YOLO ignores stray task_pr for APPROVED routing" \
  "$(run_transition transition TASK-041 IN_REVIEW APPROVED)" "1"
assert_eq "non-YOLO with stray task_pr still completes through DONE" \
  "$(run_transition transition TASK-041 IN_REVIEW DONE)" "0"

create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.require_provenance = true' \
  '.afk.yolo = false' '.afk.task_pr = false'
create_task_file TASK-018 IN_REVIEW
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-018"
cat > "$TEST_DIR/nazgul/reviews/TASK-018/code-reviewer.md" <<'FORGED_REVIEW'
---
verdict: APPROVE
review_token: forged-token
---
# Code review
FORGED_REVIEW
assert_eq "diff-bound provenance is enforced before DONE" \
  "$(run_transition transition TASK-018 IN_REVIEW DONE)" "1"
assert_contains "provenance rejection names the missing dispatch" \
  "$(cat "$TEST_DIR/transition.err")" "NO_DISPATCH_MANIFEST"
create_config '.agents.reviewers = ["code-reviewer"]' '.review_gate.require_provenance = false' \
  '.afk.yolo = false' '.afk.task_pr = false'
assert_eq "explicit provenance kill switch preserves legacy completion" \
  "$(run_transition transition TASK-018 IN_REVIEW DONE)" "0"

create_task_file TASK-042 READY
mv "$TEST_DIR/nazgul/config.json" "$TEST_DIR/nazgul/config.saved"
printf '{ malformed\n' > "$TEST_DIR/nazgul/config.json"
assert_eq "malformed authoritative config is rejected" \
  "$(run_transition transition TASK-042 READY IN_PROGRESS)" "1"
assert_eq "malformed config rejection preserves source status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-042.md")" "READY"
rm -f "$TEST_DIR/nazgul/config.json"
mv "$TEST_DIR/nazgul/config.saved" "$TEST_DIR/nazgul/config.json"
mv "$TEST_DIR/nazgul/config.json" "$TEST_DIR/external-config.json"
ln -s "$TEST_DIR/external-config.json" "$TEST_DIR/nazgul/config.json"
assert_eq "symlink authoritative config is rejected" \
  "$(run_transition transition TASK-042 READY IN_PROGRESS)" "1"
rm -f "$TEST_DIR/nazgul/config.json"
mv "$TEST_DIR/external-config.json" "$TEST_DIR/nazgul/config.json"

# Post-image parsing must not be confused by stale body text, malformed quoted
# frontmatter, removal of the canonical field, sibling MultiEdit strings, or a
# symlink alias that points back into the canonical task directory.
create_task_file TASK-014 READY
printf '\nstatus: IN_PROGRESS\n' >> "$TEST_DIR/nazgul/tasks/TASK-014.md"
WRITE_EC=0
jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-014.md" --arg c $'---\nstatus: IN_PROGRESS\n---\nstatus: READY\n' \
  '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/write.err" || WRITE_EC=$?
assert_exit_code "full Write routes canonical status transition to command" "$WRITE_EC" 2
assert_contains "full Write route names completed-write authority" \
  "$(cat "$TEST_DIR/write.err")" "Direct task-status edits cannot record"

QUOTED_EC=0
jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-014.md" --arg old 'status: READY' --arg new 'status: "IN_PROGRESS"' \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$old,new_string:$new}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/quoted.err" || QUOTED_EC=$?
assert_exit_code "quoted canonical status cannot evade transition routing" "$QUOTED_EC" 2
assert_contains "quoted canonical status still names completed-write authority" \
  "$(cat "$TEST_DIR/quoted.err")" "Direct task-status edits cannot record"

DELETE_EC=0
jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-014.md" --arg old $'status: READY\n' --arg new '' \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$old,new_string:$new}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/delete.err" || DELETE_EC=$?
assert_exit_code "canonical status removal cannot fall back to body text" "$DELETE_EC" 2
assert_contains "canonical removal denial names invalid post-image" \
  "$(cat "$TEST_DIR/delete.err")" "missing or invalid canonical status"

MULTI_EC=0
jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-014.md" \
  '{tool_name:"MultiEdit",tool_input:{edits:[
    {file_path:$f,old_string:"# TASK-014",new_string:"# TASK-014"},
    {file_path:$f,old_string:"status: READY",new_string:"status: IN_PROGRESS"}
  ]}}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" \
  >/dev/null 2>"$TEST_DIR/multi.err" || MULTI_EC=$?
assert_exit_code "MultiEdit sibling text cannot shadow a status transition" "$MULTI_EC" 2

ALIAS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-transition-alias.XXXXXX")
ln -s "$TEST_DIR/nazgul/tasks/TASK-014.md" "$ALIAS_DIR/task-alias.md"
ALIAS_EC=0
jq -nc --arg f "$ALIAS_DIR/task-alias.md" --arg old 'status: READY' --arg new 'status: IN_PROGRESS' \
  '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$old,new_string:$new}}' \
  | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STATE_GUARD" >/dev/null 2>"$TEST_DIR/alias.err" || ALIAS_EC=$?
rm -f "$ALIAS_DIR/task-alias.md"
rmdir "$ALIAS_DIR"
assert_exit_code "external symlink alias to a task still reaches the state guard" "$ALIAS_EC" 2
assert_contains "symlink alias is routed to the transaction command" \
  "$(cat "$TEST_DIR/alias.err")" "task-transition.sh transition TASK-014 READY IN_PROGRESS"

# F1: an empty array's value expansion is fatal under `set -u` on bash < 4.4.
# Shell-independent half — the guarded idiom is stripped, so what remains is unguarded.
UNGUARDED=""
for _f in "$REPO_ROOT/scripts/lib/task-transition-guard.sh" \
  "$REPO_ROOT/scripts/task-transition.sh" "$REPO_ROOT/scripts/task-state-guard.sh"; do
  _hits=$(sed 's/\${\([A-Za-z_][A-Za-z0-9_]*\)\[@\]+"\${\1\[@\]}"}//g' "$_f" \
    | grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}' || true)
  [ -z "$_hits" ] || UNGUARDED="${UNGUARDED}${UNGUARDED:+; }${_f##*/}:${_hits}"
done
assert_eq "no unguarded empty-array value expansion survives in the transition path" \
  "$UNGUARDED" ""

# PATH bash 5 tolerates the expansion, so only a real bash < 4.4 can turn this red.
LEGACY_BASH=""
for _cand in /bin/bash /usr/bin/bash; do
  [ -x "$_cand" ] || continue
  _v=$("$_cand" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null) || continue
  case "$_v" in
    3.*|4.0|4.1|4.2|4.3) LEGACY_BASH="$_cand"; break ;;
  esac
done

if [ -z "$LEGACY_BASH" ]; then
  _skip "dependency-less READY under bash < 4.4 (none installed; running $(bash --version | head -1 | sed 's/GNU bash, version //;s/ .*//'))"
else
  create_task_file TASK-015 PLANNED none
  LEGACY_EC=0
  CLAUDE_PROJECT_DIR="$TEST_DIR" "$LEGACY_BASH" "$COMMAND" transition TASK-015 PLANNED READY \
    >/dev/null 2>"$TEST_DIR/legacy.err" || LEGACY_EC=$?
  assert_exit_code "legacy bash ($_v): dependency-less PLANNED -> READY completes" "$LEGACY_EC" 0
  assert_not_contains "legacy bash: no unbound-variable abort" \
    "$(cat "$TEST_DIR/legacy.err")" "unbound variable"
  assert_eq "legacy bash: reported success matches disk" \
    "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-015.md")" "READY"
  if ttg_transition_is_guarded "$TEST_DIR/nazgul" TASK-015 PLANNED READY "2000-01-01T00:00:00Z"; then
    _pass "legacy bash: completed edge is recorded in the ledger"
  else
    _fail "legacy bash: completed edge is recorded in the ledger" "no exact ledger match"
  fi

  create_task_file TASK-016 PLANNED none
  LEGACY_GUARD_EC=0
  jq -nc --arg f "$TEST_DIR/nazgul/tasks/TASK-016.md" \
    '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"status: PLANNED",new_string:"status: READY"}}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" "$LEGACY_BASH" "$STATE_GUARD" \
      >/dev/null 2>"$TEST_DIR/legacy-guard.err" || LEGACY_GUARD_EC=$?
  assert_exit_code "legacy bash: PreToolUse gate denies rather than failing open" "$LEGACY_GUARD_EC" 2
  assert_eq "legacy bash: denied gate leaves the manifest alone" \
    "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-016.md")" "PLANNED"
fi

teardown_temp_dir
report_results
