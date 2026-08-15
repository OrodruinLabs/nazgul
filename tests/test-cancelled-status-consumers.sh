#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# Test: the CANCELLED status-vocabulary CONSUMER SET (ADR-022). Every member is
# DRIVEN with a CANCELLED fixture, including the recorded non-consumers.
TEST_NAME="test-cancelled-status-consumers"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"
source "$REPO_ROOT/scripts/lib/parallel-batch.sh"

echo "=== $TEST_NAME ==="

SESSION_SCRIPT="$REPO_ROOT/scripts/session-context.sh"
POSTCOMPACT_SCRIPT="$REPO_ROOT/scripts/post-compact.sh"
PRECOMPACT_SCRIPT="$REPO_ROOT/scripts/pre-compact.sh"
BOARD_SCRIPT="$REPO_ROOT/scripts/board-sync-github.sh"
WEBHOOK_SCRIPT="$REPO_ROOT/scripts/webhook-forward.sh"
REWORK_GUARD="$REPO_ROOT/scripts/parallel-rework-guard.sh"
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"
PRE_MERGE="$REPO_ROOT/scripts/git-hooks/pre-merge-commit"
DISPATCH="$REPO_ROOT/scripts/git-hooks/_dispatch.sh"

# Fake `gh`/`curl`, first on PATH only for the two consumers that shell out.
# Each records its argv verbatim; neither touches the network.
FAKEBIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-cancelled-fakebin-XXXXXX")
cat > "$FAKEBIN/gh" << 'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NAZGUL_TEST_GH_LOG"
exit 0
FAKE_GH
cat > "$FAKEBIN/curl" << 'FAKE_CURL'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  [ "$prev" = "-d" ] && printf '%s\n' "$arg" >> "$NAZGUL_TEST_CURL_PAYLOAD"
  prev="$arg"
done
exit 0
FAKE_CURL
chmod +x "$FAKEBIN/gh" "$FAKEBIN/curl"

# Coverage accounting (RULES.md §15): a row is "checked" only once its fixture
# actually ran; an unbuildable one is skipped, never counted as passed.
CS_SCANNED=0; CS_CHECKED=0; CS_SKIPPED=0
CS_UNDRIVABLE=0; CS_DEFERRED=0; CS_FINDINGS=0
CS_FAILED_AT_ENTRY=0

consumer_begin() {
  CS_SCANNED=$((CS_SCANNED + 1))
  CS_FAILED_AT_ENTRY=$TESTS_FAILED
}

consumer_checked() { CS_CHECKED=$((CS_CHECKED + 1)); }

consumer_undrivable() {
  CS_SKIPPED=$((CS_SKIPPED + 1)); CS_UNDRIVABLE=$((CS_UNDRIVABLE + 1))
  _skip "consumer [$1]: fixture unbuildable — not checked"
}

consumer_deferred() {
  CS_SCANNED=$((CS_SCANNED + 1))
  CS_SKIPPED=$((CS_SKIPPED + 1)); CS_DEFERRED=$((CS_DEFERRED + 1))
  _skip "consumer [$1]: deferred-to-TASK-013 (Wave 6) — not asserted here"
}

consumer_end() {
  [ "$TESTS_FAILED" -gt "$CS_FAILED_AT_ENTRY" ] && CS_FINDINGS=$((CS_FINDINGS + 1))
  return 0
}

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# 1/16 scripts/session-context.sh. FIRST deliberately: at the pre-change base the
# injected summary carries no cancelled figure, so this reads as "it did not exist".
consumer_begin
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "BLOCKED"
consumer_checked
SC_OUTPUT=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "session-context: the injected summary reports a cancelled count" \
  "$SC_OUTPUT" "1 cancelled"
assert_contains "session-context: blocked is reported apart from cancelled" "$SC_OUTPUT" "1 blocked"
assert_contains "session-context: the cancelled task is not counted as done" "$SC_OUTPUT" "1 done"
assert_contains "session-context: the cancelled task still counts into the total" \
  "$SC_OUTPUT" "Total: 3"
teardown_temp_dir

# A run that dropped work must not render identically to one where every task
# shipped — the collapse this objective exists to close.
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "DONE"
SC_ALL_DONE=$(bash "$SESSION_SCRIPT" 2>&1 | grep '^Tasks:')
teardown_temp_dir
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "CANCELLED"
SC_ONE_CANCELLED=$(bash "$SESSION_SCRIPT" 2>&1 | grep '^Tasks:')
teardown_temp_dir
if [ "$SC_ALL_DONE" = "$SC_ONE_CANCELLED" ]; then
  _fail "session-context: a dropped task does not render as a shipped one" \
    "expected: two different summary lines" "  actual: both are '$SC_ALL_DONE'"
else
  _pass "session-context: a dropped task does not render as a shipped one"
fi
assert_contains "session-context: an uncancelled run reports zero, not silence" \
  "$SC_ALL_DONE" "0 cancelled"
consumer_end

# 2/16 scripts/post-compact.sh — the same summary, re-injected after compaction.
consumer_begin
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "BLOCKED"
consumer_checked
PC_OUTPUT=$(bash "$POSTCOMPACT_SCRIPT" 2>&1)
assert_contains "post-compact: the re-injected summary reports a cancelled count" \
  "$PC_OUTPUT" "1 cancelled"
assert_contains "post-compact: blocked is reported apart from cancelled" "$PC_OUTPUT" "1 blocked"
assert_contains "post-compact: the cancelled task still counts into the total" \
  "$PC_OUTPUT" "Total: 3"
teardown_temp_dir
consumer_end

# 3/16 scripts/pre-compact.sh — the checkpoint is what recovery reads, so its
# buckets must still sum to total with a cancelled task present.
consumer_begin
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.current_iteration = 4'
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "CANCELLED"
create_task_file "TASK-004" "BLOCKED"
create_task_file "TASK-005" "PLANNED"
consumer_checked
bash "$PRECOMPACT_SCRIPT" >/dev/null 2>&1
CP_FILE="$TEST_DIR/nazgul/checkpoints/iteration-004.json"
assert_json_field "pre-compact: the checkpoint carries a cancelled field" \
  "$CP_FILE" ".plan_snapshot.cancelled" "2"
assert_json_field "pre-compact: blocked did not absorb the cancelled pair" \
  "$CP_FILE" ".plan_snapshot.blocked" "1"
CP_SUM=$(jq -r '.plan_snapshot | (.done + .approved + .ready + .in_progress + .in_review
  + .changes_requested + .blocked + .planned + .cancelled)' "$CP_FILE" 2>/dev/null)
CP_TOTAL=$(jq -r '.plan_snapshot.total_tasks' "$CP_FILE" 2>/dev/null)
assert_eq "pre-compact: the checkpoint buckets sum to total_tasks" "$CP_SUM" "$CP_TOTAL"
teardown_temp_dir
consumer_end

# 4/16 scripts/board-sync-github.sh. Its unhandled-status path REOPENS the issue,
# so the miss-mode here is an active wrong action, not a stall.
board_fixture() { # <status>
  setup_temp_dir; setup_git_repo; setup_nazgul_dir
  create_config '.board.enabled = true' '.board.provider = "github"' \
    '.board.provider_config = {"owner":"acme","repo":"widget","project_id":"PVT_1",
      "field_ids":{"nazgul_status":"F_1"},
      "status_option_ids":{"DONE":"o_done","BLOCKED":"o_blocked","CANCELLED":"o_cancelled",
      "IMPLEMENTED":"o_impl"}}' \
    '.board.task_map = {"TASK-001":{"issue_number":42,"item_id":"IT_1"}}'
  create_task_file "TASK-001" "$1"
  export NAZGUL_TEST_GH_LOG="$TEST_DIR/gh-argv.txt"
  : > "$NAZGUL_TEST_GH_LOG"
  PATH="$FAKEBIN:$PATH" bash "$BOARD_SCRIPT" sync-task "$TEST_DIR/nazgul/tasks/TASK-001.md" \
    >/dev/null 2>&1
  GH_LOG=$(cat "$NAZGUL_TEST_GH_LOG")
}

consumer_begin
if [ "$(PATH="$FAKEBIN:$PATH" command -v gh)" != "$FAKEBIN/gh" ]; then
  consumer_undrivable "scripts/board-sync-github.sh"
else
  consumer_checked
  board_fixture CANCELLED
  assert_contains "board-sync: a cancelled task's issue is closed" \
    "$GH_LOG" "issue close 42 --repo acme/widget"
  assert_contains "board-sync: closed as not planned, not as delivered" \
    "$GH_LOG" "--reason not planned"
  assert_not_contains "board-sync: a cancelled task's issue is NOT reopened" "$GH_LOG" "issue reopen"
  assert_contains "board-sync: the nazgul:cancelled label is applied" \
    "$GH_LOG" "--add-label nazgul:cancelled"
  assert_contains "board-sync: the status labels stay mutually exclusive" \
    "$GH_LOG" "--remove-label nazgul:cancelled"
  assert_contains "board-sync: the project status field is set from a known option id" \
    "$GH_LOG" "--single-select-option-id o_cancelled"
  teardown_temp_dir

  # The controls: the arms this must stay distinct from, and proof the reopen
  # path is still live for a genuinely non-terminal status.
  board_fixture DONE
  assert_contains "board-sync control: a done task's issue is closed" \
    "$GH_LOG" "issue close 42 --repo acme/widget"
  assert_not_contains "board-sync control: a done task is not closed as not planned" \
    "$GH_LOG" "--reason not planned"
  teardown_temp_dir

  board_fixture BLOCKED
  assert_contains "board-sync control: a blocked task's issue is commented, not closed" \
    "$GH_LOG" "issue comment 42"
  assert_not_contains "board-sync control: a blocked task's issue is not closed" \
    "$GH_LOG" "issue close"
  teardown_temp_dir

  board_fixture IMPLEMENTED
  assert_contains "board-sync control: the reopen arm still fires for a live status" \
    "$GH_LOG" "issue reopen 42"
  teardown_temp_dir
fi
consumer_end

# 5/16 skills/status/SKILL.md — the operator-facing report.
consumer_begin
STATUS_SKILL="$REPO_ROOT/skills/status/SKILL.md"
if [ ! -r "$STATUS_SKILL" ]; then
  consumer_undrivable "skills/status/SKILL.md"
else
  consumer_checked
  PROGRESS_BLOCK=$(awk '/^Task Progress$/{f=1} f && /^Active Task$/{exit} f' "$STATUS_SKILL")
  if [ -z "$PROGRESS_BLOCK" ]; then
    _fail "status skill: the Task Progress block was located" \
      "awk range matched zero lines — the rows below would trivially pass against an empty string"
  else
    _pass "status skill: the Task Progress block was located"
  fi
  assert_contains "status skill: a Cancelled row exists" "$PROGRESS_BLOCK" "Cancelled:"
  assert_contains "status skill: beside Blocked, which it does not replace" \
    "$PROGRESS_BLOCK" "Blocked:"
  assert_contains "status skill: beside Done, which it does not replace" "$PROGRESS_BLOCK" "Done:"
fi
consumer_end

# 6/16 scripts/lib/structured-state.sh (TASK-002) — vocabulary, never the
# off-vocabulary placeholder.
consumer_begin
setup_temp_dir; setup_nazgul_dir
create_task_file "TASK-001" "CANCELLED"
consumer_checked
assert_eq "structured-state: read_task_status returns CANCELLED, never INVALID" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md" "PLANNED")" "CANCELLED"
if _in_list CANCELLED "$VALID_STATUSES"; then
  _pass "structured-state: CANCELLED is a VALID_STATUSES member"
else
  _fail "structured-state: CANCELLED is a VALID_STATUSES member" "expected: 0" "  actual: nonzero"
fi
teardown_temp_dir
consumer_end

# 7/16 scripts/lib/task-transition-guard.sh (TASK-002) — the edge set, the
# quarantine refusal, and the dependency gate.
consumer_begin
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config
consumer_checked
if ttg_valid_transition IN_PROGRESS CANCELLED; then
  _pass "transition guard: a non-terminal status may be cancelled"
else
  _fail "transition guard: a non-terminal status may be cancelled" "expected: 0" "  actual: nonzero"
fi
if ttg_valid_transition CANCELLED READY; then
  _fail "transition guard: CANCELLED is terminal" "expected: nonzero" "  actual: 0"
else
  _pass "transition guard: CANCELLED is terminal"
fi
if ttg_dependency_satisfied "$TEST_DIR/nazgul" "CANCELLED"; then
  _pass "transition guard: a CANCELLED dependency satisfies the gate"
else
  _fail "transition guard: a CANCELLED dependency satisfies the gate" \
    "expected: 0" "  actual: nonzero (expected set: ${TTG_DEP_EXPECTED:-unset})"
fi
create_task_file "TASK-001" "BLOCKED"
QUARANTINED="$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")
- **Blocked kind**: reconciliation"
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-001" BLOCKED CANCELLED \
  "$QUARANTINED" 2>/dev/null; then
  _fail "transition guard: cancellation is not a second exit from the quarantine" \
    "expected: nonzero" "  actual: 0"
else
  _pass "transition guard: cancellation is not a second exit from the quarantine"
fi
teardown_temp_dir
consumer_end

# 8/16 scripts/lib/task-utils.sh (TASK-002) — the one counter five call sites read.
consumer_begin
setup_temp_dir; setup_nazgul_dir
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "BLOCKED"
consumer_checked
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks" 2>"$TEST_DIR/count.err" >/dev/null
assert_eq "task-utils: CANCELLED_COUNT increments" "${CANCELLED_COUNT:-unset}" "1"
assert_eq "task-utils: INVALID_COUNT does not" "${INVALID_COUNT:-unset}" "0"
assert_not_contains "task-utils: no off-vocabulary diagnostic on stderr" \
  "$(cat "$TEST_DIR/count.err")" "off-vocabulary"
teardown_temp_dir
consumer_end

COMPLETION_CONFIG=('.agents.reviewers = ["code-reviewer"]' '.learning.auto_distill_post_loop = false'
  '.docs.verify_comments = false' '.self_audit.enabled = false')

# 9/16 scripts/stop-hook.sh completion predicate (TASK-002).
consumer_begin
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
create_review_dir "TASK-001"
consumer_checked
run_hook
assert_exit_code "stop-hook completion: DONE + CANCELLED completes the loop" "$HOOK_EC" 0
assert_contains "stop-hook completion: the done/cancelled split is reported" \
  "$HOOK_OUTPUT" "1/2 done, 1 cancelled"
teardown_temp_dir
consumer_end

# 10/16 scripts/stop-hook.sh aggregate-unit walk (TASK-003) — CANCELLED leaves the
# unit, BLOCKED still holds it.
consumer_begin
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "group"' "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "IMPLEMENTED"
create_task_file "TASK-002" "CANCELLED"
consumer_checked
run_hook
assert_contains "stop-hook unit walk: a cancelled sibling does not veto the board" \
  "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
assert_contains "stop-hook unit walk: the carried-out task is named" \
  "$HOOK_OUTPUT" "carried out CANCELLED (TASK-002)"
assert_dir_not_exists "stop-hook unit walk: a cancelled task acquires no review dir" \
  "$TEST_DIR/nazgul/reviews/TASK-002"
teardown_temp_dir

setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "group"' "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "IMPLEMENTED"
create_task_file "TASK-002" "BLOCKED"
run_hook
assert_not_contains "stop-hook unit walk: a BLOCKED sibling still holds the unit" \
  "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
teardown_temp_dir
consumer_end

# 11/16 skills/task/SKILL.md `skip` (TASK-002).
consumer_begin
TASK_SKILL="$REPO_ROOT/skills/task/SKILL.md"
if [ ! -r "$TASK_SKILL" ]; then
  consumer_undrivable "skills/task/SKILL.md"
else
  consumer_checked
  SKIP_SECTION=$(awk '/^#### `skip TASK-NNN`/{f=1} f && /^#### `unblock TASK-NNN`/{exit} f' \
    "$TASK_SKILL")
  if [ -z "$SKIP_SECTION" ]; then
    _fail "task skill: the skip section was located" "awk range matched zero lines"
  else
    _pass "task skill: the skip section was located"
  fi
  assert_contains "task skill: skip names CANCELLED" "$SKIP_SECTION" "CANCELLED"
  assert_not_contains "task skill: skip performs no dependency-graph surgery" \
    "$SKIP_SECTION" "edit that line to"
fi
consumer_end

# 12/16 NON-CONSUMER scripts/lib/parallel-batch.sh. _pb_blocked_tasks matches only
# BLOCKED and INVALID|"", which is what makes veto sites 3 and 4 free.
consumer_begin
setup_temp_dir; setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
consumer_checked
if execution_should_halt "$TEST_DIR/nazgul" >/dev/null 2>&1; then
  _pass "parallel-batch: a CANCELLED task does not halt execution"
else
  _fail "parallel-batch: a CANCELLED task does not halt execution" \
    "expected: 0" "  actual: nonzero ($(execution_should_halt "$TEST_DIR/nazgul" 2>&1))"
fi
create_task_file "TASK-003" "BLOCKED"
if execution_should_halt "$TEST_DIR/nazgul" >/dev/null 2>&1; then
  _fail "parallel-batch: a BLOCKED task still halts execution" "expected: nonzero" "  actual: 0"
else
  _pass "parallel-batch: a BLOCKED task still halts execution"
fi
teardown_temp_dir
consumer_end

# 13/16 NON-CONSUMER scripts/parallel-rework-guard.sh — ownership needs
# DONE|IMPLEMENTED *and* a recorded commit, so a cancelled task can own no scope.
rework_ec() { # <file_path>
  local ec=0
  jq -n --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}' \
    | bash "$REWORK_GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}
own_task() { # <id> <status> <file> [sha]
  local id="$1" status="$2" file="$3" sha="${4:-}"
  create_task_file_with_files_modified "$id" "$status" "$(jq -n -c --arg f "$file" '[$f]')"
  [ -n "$sha" ] && printf -- '\n## Commits\n- %s\n' "$sha" >> "$TEST_DIR/nazgul/tasks/${id}.md"
  return 0
}

consumer_begin
setup_temp_dir; setup_nazgul_dir
create_config '.execution.parallel = true'
own_task TASK-001 CANCELLED "scripts/foo.sh" "abc1234"
consumer_checked
assert_eq "rework guard: a CANCELLED task owns no scope" "$(rework_ec "scripts/foo.sh")" "0"
teardown_temp_dir

setup_temp_dir; setup_nazgul_dir
create_config '.execution.parallel = true'
own_task TASK-001 DONE "scripts/foo.sh" "abc1234"
assert_eq "rework guard control: the same manifest at DONE does own it" \
  "$(rework_ec "scripts/foo.sh")" "2"
teardown_temp_dir
consumer_end

# 14/16 NON-CONSUMER scripts/webhook-forward.sh — counts DONE only, via its own
# legacy-format grep, so the fixture is legacy or the assertion would be vacuous.
consumer_begin
setup_temp_dir; setup_nazgul_dir
create_config '.webhooks.enabled = true' '.webhooks.url = "https://example.invalid/hook"' \
  '.webhooks.events = ["stop"]'
create_task_file_legacy "TASK-001" "DONE"
create_task_file_legacy "TASK-002" "CANCELLED"
export NAZGUL_TEST_CURL_PAYLOAD="$TEST_DIR/curl-payload.json"
: > "$NAZGUL_TEST_CURL_PAYLOAD"
if [ "$(PATH="$FAKEBIN:$PATH" command -v curl)" != "$FAKEBIN/curl" ]; then
  consumer_undrivable "scripts/webhook-forward.sh"
else
  consumer_checked
  PATH="$FAKEBIN:$PATH" bash "$WEBHOOK_SCRIPT" stop >/dev/null 2>&1
  WH_PAYLOAD=$(cat "$NAZGUL_TEST_CURL_PAYLOAD")
  assert_eq "webhook-forward: a CANCELLED task does not move tasks_done" \
    "$(printf '%s' "$WH_PAYLOAD" | jq -r '.tasks_done' 2>/dev/null)" "1"
  assert_eq "webhook-forward: it is still counted into tasks_total" \
    "$(printf '%s' "$WH_PAYLOAD" | jq -r '.tasks_total' 2>/dev/null)" "2"
fi
teardown_temp_dir
consumer_end

# 15/16 NON-CONSUMER scripts/git-hooks/pre-merge-commit — identity is a SHA under
# ## Commits or a feat/<x>/TASK-NNN ref; a cancelled task ships neither.
pm_init_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email "t@t.t"
  git -C "$1" config user.name "t"
  git -C "$1" commit -q --allow-empty -m "init"
  mkdir -p "$1/.githooks"
  cp "$PRE_MERGE" "$1/.githooks/pre-merge-commit"
  cp "$DISPATCH" "$1/.githooks/_dispatch.sh"
  chmod +x "$1/.githooks/pre-merge-commit" "$1/.githooks/_dispatch.sh"
  git -C "$1" config core.hooksPath "$1/.githooks"
  mkdir -p "$1/nazgul/tasks"
  printf '%s' '{"execution":{"parallel":true},"guards":{"git_hooks":true}}' > "$1/nazgul/config.json"
}
pm_branch() {
  git -C "$1" checkout -q -b "$2"
  git -C "$1" commit -q --allow-empty -m "unit work"
  git -C "$1" checkout -q main
  git -C "$1" rev-parse "$2"
}
pm_task() { # <repo> <id> <status> [sha]
  local repo="$1" id="$2" status="$3" sha="${4:-}"
  {
    printf -- '---\nstatus: %s\n---\n\n# %s\n' "$status" "$id"
    [ -n "$sha" ] && printf -- '\n## Commits\n\n- %s task work\n' "$sha"
  } > "$repo/nazgul/tasks/$id.md"
  return 0
}
pm_merge() {
  PM_STDERR=$(git -C "$1" merge --no-ff -m "merge $2" "$2" 2>&1) && PM_EC=0 || PM_EC=$?
  git -C "$1" merge --abort 2>/dev/null || true
}

consumer_begin
setup_temp_dir
pm_init_repo "$TEST_DIR/repo"
PM_SHA=$(pm_branch "$TEST_DIR/repo" "feat/FEAT-031/TASK-002")
pm_task "$TEST_DIR/repo" "TASK-001" "CANCELLED"
pm_task "$TEST_DIR/repo" "TASK-002" "DONE" "$PM_SHA"
consumer_checked
pm_merge "$TEST_DIR/repo" "feat/FEAT-031/TASK-002"
assert_exit_code "pre-merge: a cancelled task is unreachable by both identity signals" "$PM_EC" 0
assert_not_contains "pre-merge: the cancelled task is never named as a blocker" \
  "$PM_STDERR" "TASK-001"
teardown_temp_dir

# The control: same guard, same fixture shape, still blocks a genuinely unapproved
# unit — proof the allow above is an exemption, not a dead guard.
setup_temp_dir
pm_init_repo "$TEST_DIR/repo"
PM_SHA=$(pm_branch "$TEST_DIR/repo" "feat/FEAT-031/TASK-003")
pm_task "$TEST_DIR/repo" "TASK-001" "CANCELLED"
pm_task "$TEST_DIR/repo" "TASK-003" "IMPLEMENTED" "$PM_SHA"
pm_merge "$TEST_DIR/repo" "feat/FEAT-031/TASK-003"
assert_exit_code "pre-merge control: an unapproved unit is still blocked" "$PM_EC" 1
assert_contains "pre-merge control: the block names the unapproved unit" "$PM_STDERR" "TASK-003"
teardown_temp_dir
consumer_end

# 16/16 NON-CONSUMER scripts/scrub-stale-review-artifacts.sh — examined and exempt:
# its guard enumerates the OPEN statuses, and CANCELLED is terminal.
consumer_begin
SCRUB="$REPO_ROOT/scripts/scrub-stale-review-artifacts.sh"
if [ ! -r "$SCRUB" ]; then
  consumer_undrivable "scripts/scrub-stale-review-artifacts.sh"
else
  consumer_checked
  OPEN_LOOP=$(grep -m1 'for status in READY' "$SCRUB")
  if [ -z "$OPEN_LOOP" ]; then
    _fail "scrub script: the open-status enumeration was located" \
      "no 'for status in READY' line — the assertions below would trivially pass"
  else
    _pass "scrub script: the open-status enumeration was located"
  fi
  assert_contains "scrub script: BLOCKED is an open status it still waits on" "$OPEN_LOOP" "BLOCKED"
  assert_not_contains "scrub script: CANCELLED is terminal and correctly absent" \
    "$OPEN_LOOP" "CANCELLED"
fi
consumer_end

# Deferred, named rather than omitted (TASK-013, Wave 6).
consumer_deferred "skills/metrics/SKILL.md"
consumer_deferred "templates/task-manifest.md"
consumer_deferred "RULES.md"

rm -rf "$FAKEBIN"

echo "  consumer-scan: ${CS_SCANNED} scanned, ${CS_SKIPPED} skipped (undrivable=${CS_UNDRIVABLE}, deferred-to-TASK-013=${CS_DEFERRED}), ${CS_CHECKED} checked, ${CS_FINDINGS} findings"
assert_eq "consumer-scan: scanned == skipped + checked" \
  "$CS_SCANNED" "$((CS_SKIPPED + CS_CHECKED))"
assert_eq "consumer-scan: every consumer row was driven" "$CS_CHECKED" "16"
assert_eq "consumer-scan: the deferred surfaces are named, not omitted" "$CS_DEFERRED" "3"

report_results
