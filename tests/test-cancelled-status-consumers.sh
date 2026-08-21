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
source "$SCRIPT_DIR/lib/status-consumer-scan.sh"
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
DISPATCH_GUARD="$REPO_ROOT/scripts/parallel-dispatch-guard.sh"
TRANSITION="$REPO_ROOT/scripts/task-transition.sh"

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
CS_UNDRIVABLE=0; CS_FINDINGS=0
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

consumer_end() {
  [ "$TESTS_FAILED" -gt "$CS_FAILED_AT_ENTRY" ] && CS_FINDINGS=$((CS_FINDINGS + 1))
  return 0
}

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# 1/21 scripts/session-context.sh. FIRST deliberately: at the pre-change base the
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

# 2/21 scripts/post-compact.sh — the same summary, re-injected after compaction.
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

# 3/21 scripts/pre-compact.sh — the checkpoint is what recovery reads, so its
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

# 4/21 scripts/board-sync-github.sh. Its unhandled-status path REOPENS the issue,
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

# `setup`'s gh is a scripted board, not a logger: the option set lives in a file so a
# mutation that lands is visible to the independent field-list re-read that follows it.
SETUP_BIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-cancelled-setupbin-XXXXXX")
cat > "$SETUP_BIN/gh" << 'SETUP_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NAZGUL_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "repo view")
    printf '{"owner":{"login":"acme"},"name":"widget"}\n' ;;
  "project view")
    printf 'PVT_1\n' ;;
  "project field-create")
    case " $* " in
      # GitHub fails field-create when the field already exists — the upgrade path.
      *"--name Nazgul Status"*)
        [ "${NAZGUL_TEST_STATUS_CREATE_RC:-1}" = "0" ] || exit 1
        printf '{"id":"F_1","name":"Nazgul Status"}\n' ;;
      *) printf '{"id":"F_OTHER"}\n' ;;
    esac ;;
  "project field-list")
    case " $* " in
      *" --jq "*) printf '{"id":"F_1","name":"Nazgul Status"}\n' ;;
      *) jq -cn --argjson o "$(cat "$NAZGUL_TEST_OPTIONS_FILE")" \
           '{fields:[{id:"F_1",name:"Nazgul Status",options:$o},{id:"F_OTHER",name:"Task ID"}]}' ;;
    esac ;;
  "label create") ;;
  "api graphql")
    body=$(cat)
    jq -c . <<< "$body" >> "$NAZGUL_TEST_GQL_LOG"
    if jq -e '.query | test("updateProjectV2Field")' >/dev/null 2>&1 <<< "$body"; then
      case "${NAZGUL_TEST_MUTATION_MODE:-ok}" in
        fail)
          printf '{"errors":[{"message":"Your token has not been granted the required scopes"}]}\n'
          printf 'gh: Your token has not been granted the required scopes\n' >&2
          exit 1 ;;
        noop)
          after=$(jq -c '[.[] | {id, name}]' < "$NAZGUL_TEST_OPTIONS_FILE") ;;
        drop)
          after=$(jq -c --arg d "${NAZGUL_TEST_DROP_NAME:-TRIAGE}" \
            '[.variables.options[] | select(.name != $d) | {id: (.id // ("o_new_" + (.name | ascii_downcase))), name: .name}]' <<< "$body") ;;
        *)
          new_state=$(jq -c '[.variables.options[] | {id: (.id // ("o_new_" + (.name | ascii_downcase))), name: .name, color: .color, description: .description}]' <<< "$body")
          after=$(jq -c '[.[] | {id, name}]' <<< "$new_state")
          [ "${NAZGUL_TEST_MUTATION_MODE:-ok}" = "stale_readback" ] \
            || printf '%s\n' "$new_state" > "$NAZGUL_TEST_OPTIONS_FILE" ;;
      esac
      jq -cn --argjson a "$after" '{data:{updateProjectV2Field:{projectV2Field:{options:$a}}}}'
      exit 0
    fi
    case "${NAZGUL_TEST_READ_MODE:-ok}" in
      fail)
        printf '{"errors":[{"message":"Could not resolve to a node with the global id"}]}\n'
        printf 'gh: Could not resolve to a node with the global id\n' >&2
        exit 1 ;;
      notselect) printf '{"data":{"node":{}}}\n' ;;
      *) jq -cn --argjson o "$(cat "$NAZGUL_TEST_OPTIONS_FILE")" '{data:{node:{id:"F_1",options:$o}}}' ;;
    esac ;;
esac
exit 0
SETUP_GH
chmod +x "$SETUP_BIN/gh"

board_options_json() { # <name...> -> the option array a live board carries
  local n out="[]"
  for n in "$@"; do
    out=$(jq -c --arg n "$n" \
      '. + [{id: ("o_" + ($n | ascii_downcase)), name: $n, color: "GRAY", description: ("legend for " + $n)}]' <<< "$out")
  done
  printf '%s\n' "$out"
}

PRE_FEAT031_OPTIONS=$(board_options_json PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW CHANGES_REQUESTED DONE BLOCKED)
CUSTOMISED_OPTIONS=$(board_options_json PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW CHANGES_REQUESTED DONE BLOCKED TRIAGE)
CURRENT_OPTIONS=$(board_options_json PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW CHANGES_REQUESTED DONE BLOCKED CANCELLED)

board_setup_fixture() { # <options-json> [read-mode] [mutation-mode] [status-create-rc]
  setup_temp_dir; setup_git_repo; setup_nazgul_dir
  create_config
  export NAZGUL_TEST_GH_LOG="$TEST_DIR/gh-argv.txt"
  export NAZGUL_TEST_GQL_LOG="$TEST_DIR/gh-graphql.txt"
  export NAZGUL_TEST_OPTIONS_FILE="$TEST_DIR/board-options.json"
  export NAZGUL_TEST_READ_MODE="${2:-ok}"
  export NAZGUL_TEST_MUTATION_MODE="${3:-ok}"
  export NAZGUL_TEST_STATUS_CREATE_RC="${4:-1}"
  : > "$NAZGUL_TEST_GH_LOG"; : > "$NAZGUL_TEST_GQL_LOG"
  printf '%s\n' "$1" > "$NAZGUL_TEST_OPTIONS_FILE"
  SETUP_ERR=$(PATH="$SETUP_BIN:$PATH" bash "$BOARD_SCRIPT" setup 7 2>&1 >/dev/null) && SETUP_RC=0 || SETUP_RC=$?
  GH_LOG=$(cat "$NAZGUL_TEST_GH_LOG")
  SETUP_MUTATION=$(grep -F 'updateProjectV2Field' "$NAZGUL_TEST_GQL_LOG" || true)
  SETUP_CONFIG="$TEST_DIR/nazgul/config.json"
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

  # `setup`'s own `gh`: a scripted board, not a logger. `field-create` fails exactly
  # as GitHub does when the field exists — the fallback path every upgraded board takes.
  if [ "$(PATH="$SETUP_BIN:$PATH" command -v gh)" != "$SETUP_BIN/gh" ]; then
    _fail "board-sync setup: the scripted gh is first on PATH" \
      "resolved $(PATH="$SETUP_BIN:$PATH" command -v gh) — the real gh would have been driven"
  else
    # The upgrade path: a board whose `Nazgul Status` predates CANCELLED.
    board_setup_fixture "$PRE_FEAT031_OPTIONS"
    assert_eq "board-sync setup: proof the scripted gh was driven — the owner is the stub's fiction" \
      "$(jq -r '.board.provider_config.owner' "$SETUP_CONFIG")" "acme"
    assert_contains "board-sync setup: and every gh call was recorded by it" \
      "$GH_LOG" "repo view --json owner,name"
    assert_eq "board-sync setup: an eight-option board is upgraded and setup succeeds" "$SETUP_RC" "0"
    assert_contains "board-sync setup: the reported outcome names the option it added" \
      "$SETUP_ERR" "Nazgul Status options added: CANCELLED"
    assert_contains "board-sync setup: a mutation was sent" "$SETUP_MUTATION" "updateProjectV2Field"
    for _opt in PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW CHANGES_REQUESTED DONE BLOCKED; do
      assert_eq "board-sync setup: the mutation returns $_opt with its original id" \
        "$(jq -r --arg n "$_opt" '.variables.options[] | select(.name == $n) | .id' <<< "$SETUP_MUTATION")" \
        "o_$(tr '[:upper:]' '[:lower:]' <<< "$_opt")"
      assert_eq "board-sync setup: and $_opt keeps its own description" \
        "$(jq -r --arg n "$_opt" '.variables.options[] | select(.name == $n) | .description' <<< "$SETUP_MUTATION")" \
        "legend for $_opt"
    done
    assert_eq "board-sync setup: all eight originals plus the ninth are sent, none dropped" \
      "$(jq -r '.variables.options | length' <<< "$SETUP_MUTATION")" "9"
    assert_eq "board-sync setup: the new option carries no id, so GitHub creates it" \
      "$(jq -r '.variables.options[] | select(.name == "CANCELLED") | has("id")' <<< "$SETUP_MUTATION")" "false"
    assert_eq "board-sync setup: the stored map resolves CANCELLED" \
      "$(jq -r '.board.provider_config.status_option_ids.CANCELLED' "$SETUP_CONFIG")" "o_new_cancelled"
    assert_eq "board-sync setup: and the board is enabled on success" \
      "$(jq -r '.board.enabled' "$SETUP_CONFIG")" "true"
    assert_contains "board-sync setup: the migration leaves a telemetry record" \
      "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" '"result":"added"'
    teardown_temp_dir

    # An option Nazgul never heard of is the real data-loss risk: it is preserved by id.
    board_setup_fixture "$CUSTOMISED_OPTIONS"
    assert_eq "board-sync setup: a board-owner's own option survives the migration" \
      "$(jq -r '.variables.options[] | select(.name == "TRIAGE") | .id' <<< "$SETUP_MUTATION")" "o_triage"
    assert_eq "board-sync setup: with its colour and description untouched" \
      "$(jq -r '.variables.options[] | select(.name == "TRIAGE") | .color + "/" + .description' <<< "$SETUP_MUTATION")" \
      "GRAY/legend for TRIAGE"
    assert_eq "board-sync setup: and the option set only ever grows" \
      "$(jq -r '.variables.options | length' <<< "$SETUP_MUTATION")" "10"
    teardown_temp_dir

    # Idempotence: the same board a second time has nothing to add.
    board_setup_fixture "$CURRENT_OPTIONS"
    assert_eq "board-sync setup: a nine-option board still succeeds" "$SETUP_RC" "0"
    assert_eq "board-sync setup: and mutates nothing" "$SETUP_MUTATION" ""
    assert_contains "board-sync setup: 'nothing to do' says so rather than claiming an add" \
      "$SETUP_ERR" "Nazgul Status options: nothing to add"
    assert_not_contains "board-sync setup: an unchanged board never reports an add" \
      "$SETUP_ERR" "options added"
    assert_eq "board-sync setup: the pre-existing CANCELLED id is stored unchanged" \
      "$(jq -r '.board.provider_config.status_option_ids.CANCELLED' "$SETUP_CONFIG")" "o_cancelled"
    teardown_temp_dir

    # A freshly created field arrives with all nine and is equally quiet.
    board_setup_fixture "$CURRENT_OPTIONS" ok ok 0
    assert_eq "board-sync setup: a freshly created field needs no migration" "$SETUP_MUTATION" ""
    assert_eq "board-sync setup: and the fresh path still succeeds" "$SETUP_RC" "0"
    teardown_temp_dir

    # The half this defect is really about: a mechanism that could not act must not
    # exit 0. Every refusal is named, and none of them writes a board config.
    board_setup_fixture "$PRE_FEAT031_OPTIONS" ok fail
    assert_eq "board-sync setup: a failed mutation exits nonzero, not 0" "$SETUP_RC" "1"
    assert_contains "board-sync setup: the failure is named mutation_failed" \
      "$SETUP_ERR" "Could not add missing 'Nazgul Status' options (mutation_failed)"
    assert_contains "board-sync setup: gh's own reason is carried through" \
      "$SETUP_ERR" "has not been granted the required scopes"
    assert_contains "board-sync setup: the remedy names where to add it by hand" \
      "$SETUP_ERR" "https://github.com/orgs/acme/projects/7/settings/fields"
    assert_contains "board-sync setup: and how to fix the likely cause" \
      "$SETUP_ERR" "gh auth refresh -s project"
    assert_not_contains "board-sync setup: a failed setup never reports completion" \
      "$SETUP_ERR" "Setup complete"
    assert_eq "board-sync setup: and never enables the board" \
      "$(jq -r '.board.enabled' "$SETUP_CONFIG")" "false"
    assert_eq "board-sync setup: nor stores a map missing CANCELLED" \
      "$(jq -r '.board.provider_config.status_option_ids.CANCELLED // "absent"' "$SETUP_CONFIG")" "absent"
    assert_contains "board-sync setup: the refusal leaves its own telemetry record" \
      "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" '"result":"mutation_failed"'
    teardown_temp_dir

    board_setup_fixture "$PRE_FEAT031_OPTIONS" ok noop
    assert_eq "board-sync setup: a mutation that changed nothing exits nonzero" "$SETUP_RC" "1"
    assert_contains "board-sync setup: 'reported success, changed nothing' is its own name" \
      "$SETUP_ERR" "(mutation_no_effect)"
    assert_contains "board-sync setup: and says which option is still absent" \
      "$SETUP_ERR" "still lacks: CANCELLED"
    teardown_temp_dir

    board_setup_fixture "$CUSTOMISED_OPTIONS" ok drop
    assert_eq "board-sync setup: an option lost to the mutation exits nonzero" "$SETUP_RC" "1"
    assert_contains "board-sync setup: losing a pre-existing option is its own name" \
      "$SETUP_ERR" "(mutation_dropped_option)"
    assert_contains "board-sync setup: and the lost option is named" "$SETUP_ERR" "TRIAGE"
    teardown_temp_dir

    board_setup_fixture "$PRE_FEAT031_OPTIONS" ok stale_readback
    assert_eq "board-sync setup: an independent re-read that disagrees exits nonzero" "$SETUP_RC" "1"
    assert_contains "board-sync setup: the map gate refuses rather than storing a gap" \
      "$SETUP_ERR" "Status option ids unresolved after reconciliation: CANCELLED"
    assert_contains "board-sync setup: and states what an unresolved id would cost" \
      "$SETUP_ERR" "board column silently kept its previous value"
    teardown_temp_dir

    board_setup_fixture "$PRE_FEAT031_OPTIONS" fail
    assert_eq "board-sync setup: an unreadable field exits nonzero" "$SETUP_RC" "1"
    assert_contains "board-sync setup: 'could not look' is named apart from 'could not write'" \
      "$SETUP_ERR" "(read_failed)"
    assert_eq "board-sync setup: and nothing is mutated on a failed read" "$SETUP_MUTATION" ""
    teardown_temp_dir

    board_setup_fixture "$PRE_FEAT031_OPTIONS" notselect
    assert_eq "board-sync setup: a field that is not single-select exits nonzero" "$SETUP_RC" "1"
    assert_contains "board-sync setup: with a name of its own" "$SETUP_ERR" "(not_single_select)"
    teardown_temp_dir
  fi
fi
consumer_end

# 5/21 skills/status/SKILL.md — the operator-facing report.
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

# 6/21 scripts/lib/structured-state.sh (TASK-002) — vocabulary, never the
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

# 7/21 scripts/lib/task-transition-guard.sh (TASK-002) — the edge set, the
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

# 8/21 scripts/lib/task-utils.sh (TASK-002) — the one counter five call sites read.
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

# 9/21 scripts/stop-hook.sh completion predicate (TASK-002).
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

# 10/21 scripts/stop-hook.sh aggregate-unit walk (TASK-003) — CANCELLED leaves the
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

# 11/21 skills/task/SKILL.md `skip` (TASK-002).
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

# 12/21 CONSUMER scripts/lib/parallel-batch.sh. ADR-022 called it a non-consumer on
# `_pb_blocked_tasks` alone; two further status predicates vetoed a cancelled dep.
consumer_begin
setup_temp_dir; setup_nazgul_dir
create_config
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

# compute_dispatch_batch's dependency gate was a second, hand-inlined copy of the
# predicate ttg_dependency_satisfied owns; it now calls that authority.
setup_temp_dir; setup_nazgul_dir
create_config
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "READY" "TASK-001"
PB_OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "parallel-batch: a CANCELLED dependency does not veto dispatch" \
  "$(jq -r '.tasks | join(",")' <<< "$PB_OUT")" "TASK-002"
teardown_temp_dir

setup_temp_dir; setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY" "TASK-001"
PB_OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "parallel-batch control: a DONE dependency dispatches, as it always did" \
  "$(jq -r '.tasks | join(",")' <<< "$PB_OUT")" "TASK-002"
teardown_temp_dir

setup_temp_dir; setup_nazgul_dir
create_config
create_task_file "TASK-001" "IN_PROGRESS"
create_task_file "TASK-002" "READY" "TASK-001"
PB_OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "parallel-batch control: an unfinished dependency still vetoes" \
  "$(jq -r '.reason' <<< "$PB_OUT")" "no dispatchable tasks"
teardown_temp_dir

# Routing through the one authority also makes the parallel path granularity-aware,
# which the inline copy never was.
setup_temp_dir; setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_task_file "TASK-001" "IMPLEMENTED"
create_task_file "TASK-002" "READY" "TASK-001"
PB_OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "parallel-batch: the dependency gate honours review_gate.granularity" \
  "$(jq -r '.tasks | join(",")' <<< "$PB_OUT")" "TASK-002"
teardown_temp_dir

# _pb_layer_waves partitions on the terminal set, so a cancelled task is neither a
# dispatchable unit nor a dependency its dependents wait behind.
setup_temp_dir; setup_nazgul_dir
create_config
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "READY" "TASK-001"
create_task_file "TASK-003" "BLOCKED"
create_task_file "TASK-004" "READY" "TASK-003"
PB_WAVES=$(compute_waves "$TEST_DIR/nazgul/tasks")
assert_not_contains "parallel-batch: a CANCELLED task is no dispatchable wave unit" \
  "$PB_WAVES" "TASK-001"
assert_eq "parallel-batch: its dependent layers into wave 1, not behind it" \
  "$(jq -r '.[0].units | join(",")' <<< "$PB_WAVES")" "TASK-002,TASK-003"
assert_eq "parallel-batch control: a BLOCKED dependency still layers its dependent behind" \
  "$(jq -r '.[1].units | join(",")' <<< "$PB_WAVES")" "TASK-004"
teardown_temp_dir
consumer_end

# 13/21 CONSUMER scripts/parallel-dispatch-guard.sh — never enumerated by ADR-022 at
# all. A CANCELLED unit will never ship, so re-dispatching it is the wasted work.
dispatch_ec() { # <subagent_type> <prompt>
  local ec=0
  jq -n --arg t "$1" --arg p "$2" \
    '{tool_name:"Agent",tool_input:{subagent_type:$t,run_in_background:false,prompt:$p}}' \
    | bash "$DISPATCH_GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

consumer_begin
setup_temp_dir; setup_nazgul_dir
create_config '.execution.parallel = true'
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "READY"
consumer_checked
assert_eq "dispatch guard: a CANCELLED unit is not re-dispatched to an implementer" \
  "$(dispatch_ec implementer "NAZGUL_UNIT: TASK-001")" "2"
assert_eq "dispatch guard: nor re-dispatched to the review board" \
  "$(dispatch_ec review-gate "NAZGUL_UNIT: TASK-001")" "2"
assert_eq "dispatch guard control: a READY unit is still dispatchable" \
  "$(dispatch_ec implementer "NAZGUL_UNIT: TASK-002")" "0"
teardown_temp_dir
consumer_end

# 14/21 CONSUMER scripts/task-transition.sh — ADR-022 exempted it as hardcoding no
# status vocabulary; `repair`'s quarantine-metadata check hardcodes one.
repair_stderr() {
  { CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$TRANSITION" repair TASK-001 >/dev/null; } 2>&1 || true
}
quarantine_manifest() { # <blocked-from> <blocked-observed>
  local dest="$TEST_DIR/nazgul/tasks/TASK-001.md"
  printf -- '---\nstatus: BLOCKED\n---\n# TASK-001\n\n## Metadata\n- **Depends on**: none\n- **Blocked kind**: reconciliation\n- **Blocked from**: %s\n- **Blocked observed**: %s\n' \
    "$1" "$2" > "$dest"
}

consumer_begin
setup_temp_dir; setup_nazgul_dir
create_config
quarantine_manifest CANCELLED DONE
consumer_checked
TT_ERR=$(repair_stderr)
assert_not_contains "task-transition: a CANCELLED quarantine endpoint is not corrupt metadata" \
  "$TT_ERR" "not a canonical status"
assert_contains "task-transition: the refusal names its real cause instead" \
  "$TT_ERR" "repair refused"
quarantine_manifest NOT_A_STATUS DONE
TT_ERR=$(repair_stderr)
assert_contains "task-transition control: a genuinely off-vocabulary endpoint is still corrupt" \
  "$TT_ERR" "not a canonical status"
teardown_temp_dir
consumer_end

# 15/21 NON-CONSUMER scripts/parallel-rework-guard.sh — ownership needs
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

# 16/21 NON-CONSUMER scripts/webhook-forward.sh — counts DONE only, via its own
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

# 17/21 NON-CONSUMER scripts/git-hooks/pre-merge-commit — identity is a SHA under
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

# ADR-022 exempted this guard as UNREACHABLE by a cancelled task. IMPLEMENTED ->
# CANCELLED is a legal edge, so such a task ships both signals and is reached.
setup_temp_dir
pm_init_repo "$TEST_DIR/repo"
PM_SHA=$(pm_branch "$TEST_DIR/repo" "feat/FEAT-031/TASK-004")
pm_task "$TEST_DIR/repo" "TASK-004" "CANCELLED" "$PM_SHA"
pm_merge "$TEST_DIR/repo" "feat/FEAT-031/TASK-004"
assert_exit_code "pre-merge: a task cancelled AFTER implementing is reached, and blocks" "$PM_EC" 1
assert_contains "pre-merge: the block names the cancelled unit" "$PM_STDERR" "TASK-004"
teardown_temp_dir
consumer_end

# 18/21 NON-CONSUMER scripts/scrub-stale-review-artifacts.sh — examined and exempt:
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

# 19/21 skills/metrics/SKILL.md — the outcome report an operator reads after a run.
consumer_begin
METRICS_SKILL="$REPO_ROOT/skills/metrics/SKILL.md"
if [ ! -r "$METRICS_SKILL" ]; then
  consumer_undrivable "skills/metrics/SKILL.md"
else
  consumer_checked
  MANIFEST_SOURCE=$(awk '/^1\. \*\*Task manifests\*\*/{f=1;next} f && /^2\. /{exit} f' "$METRICS_SKILL")
  if [ -z "$MANIFEST_SOURCE" ]; then
    _fail "metrics skill: the task-manifest source block was located" \
      "awk range matched zero lines — the rows below would trivially pass against an empty string"
  else
    _pass "metrics skill: the task-manifest source block was located"
  fi
  assert_contains "metrics skill: CANCELLED is a counted status" "$MANIFEST_SOURCE" "CANCELLED"
  assert_contains "metrics skill: beside BLOCKED, which it does not replace" "$MANIFEST_SOURCE" "BLOCKED"
  assert_contains "metrics skill: it is never folded into DONE" \
    "$MANIFEST_SOURCE" "never folded into DONE"
fi
consumer_end

# 20/21 templates/task-manifest.md — the state-machine contract every new manifest carries.
consumer_begin
MANIFEST_TEMPLATE="$REPO_ROOT/templates/task-manifest.md"
if [ ! -r "$MANIFEST_TEMPLATE" ]; then
  consumer_undrivable "templates/task-manifest.md"
else
  consumer_checked
  VALID_STATES_BLOCK=$(awk '/^<!-- Valid states:/{f=1} f{print} f && /-->/{exit}' "$MANIFEST_TEMPLATE")
  if [ -z "$VALID_STATES_BLOCK" ]; then
    _fail "manifest template: the valid-states comment was located" \
      "awk range matched zero lines — the rows below would trivially pass against an empty string"
  else
    _pass "manifest template: the valid-states comment was located"
  fi
  assert_contains "manifest template: CANCELLED is in the valid-state vocabulary" \
    "$VALID_STATES_BLOCK" "| CANCELLED"
  assert_contains "manifest template: the in-edge is recorded" \
    "$VALID_STATES_BLOCK" "-> CANCELLED"
  assert_contains "manifest template: both terminal states are named as terminal" \
    "$VALID_STATES_BLOCK" "DONE and CANCELLED are both terminal"
  DEPENDS_BLOCK=$(awk '/^- \*\*Depends on\*\*/{f=1;next} f{print} f && /-->/{exit}' "$MANIFEST_TEMPLATE")
  if [ -z "$DEPENDS_BLOCK" ]; then
    _fail "manifest template: the Depends on comment was located" \
      "awk range matched zero lines — the row below would trivially pass against an empty string"
  else
    _pass "manifest template: the Depends on comment was located"
  fi
  assert_contains "manifest template: a CANCELLED dependency satisfies the gate" \
    "$DEPENDS_BLOCK" "CANCELLED also satisfies"
fi
consumer_end

# 21/21 RULES.md — the durable contract; §2 is where a reader learns the status exists.
consumer_begin
RULES_DOC="$REPO_ROOT/RULES.md"
if [ ! -r "$RULES_DOC" ]; then
  consumer_undrivable "RULES.md"
else
  consumer_checked
  CANCEL_SECTION=$(awk '/^### Cancellation, the Second Terminal Status/{f=1;next} f && /^### /{exit} f' "$RULES_DOC")
  if [ -z "$CANCEL_SECTION" ]; then
    _fail "RULES.md: the cancellation section was located" \
      "awk range matched zero lines — the rows below would trivially pass against an empty string"
  else
    _pass "RULES.md: the cancellation section was located"
  fi
  assert_contains "RULES.md: the section carries a tier, like every rule" "$CANCEL_SECTION" "[enforced]"
  assert_contains "RULES.md: CANCELLED has no out-edge" "$CANCEL_SECTION" "no out-edge"
  assert_contains "RULES.md: the reconciliation quarantine is refused a cancellation" \
    "$CANCEL_SECTION" "Blocked kind: reconciliation"
  TRANSITION_TABLE=$(awk '/^### Permitted Transitions/{f=1;next} f && /^### /{exit} f' "$RULES_DOC")
  assert_contains "RULES.md: the permitted-transition table carries the in-edge" \
    "$TRANSITION_TABLE" "| CANCELLED |"
  FORBIDDEN=$(awk '/^### Forbidden Transitions/{f=1;next} f && /^### /{exit} f' "$RULES_DOC")
  assert_contains "RULES.md: the forbidden list names both terminal statuses" \
    "$FORBIDDEN" "DONE, CANCELLED -> any state"
  DEP_GATE=$(awk '/^### Dependency Gate/{f=1;next} f && /^### /{exit} f' "$RULES_DOC")
  assert_contains "RULES.md: a CANCELLED dependency satisfies the gate in every granularity" \
    "$DEP_GATE" "CANCELLED"
fi
consumer_end

rm -rf "$FAKEBIN" "$SETUP_BIN"

# `deferred-to-TASK-013` is retired, not kept at a permanent =0: TASK-013 landed, so no
# call site can produce it, and a reason that cannot occur misreports the scan (RULES.md §15).
echo "  consumer-scan: ${CS_SCANNED} scanned, ${CS_SKIPPED} skipped (undrivable=${CS_UNDRIVABLE}), ${CS_CHECKED} checked, ${CS_FINDINGS} findings"
assert_eq "consumer-scan: scanned == skipped + checked" \
  "$CS_SCANNED" "$((CS_SKIPPED + CS_CHECKED))"
assert_eq "consumer-row registry: every row in THIS file was driven" "$CS_CHECKED" "21"

# The rows above are an authored registry, which certifies its author. The
# denominator it cannot discharge is asked mechanically here instead.
if ! scs_run "$REPO_ROOT"; then
  _fail "population-scan: the shipped tree is walkable" "no scripts/ directory under $REPO_ROOT"
else
  # Board-3 NEW-5: a bare mention certified nothing. TASK-017: `named-only` is a
  # FINDING now — an unreached site is unpinned, and a skip would recount it as checked.
  scs_pin_scan "$REPO_ROOT/tests" "$REPO_ROOT" "$SCS_CONSUMERS"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _skip "population-scan [$rel]: unreadable between discovery and pin check — not checked"
  done <<< "$SCS_PS_VANISHED_PATHS"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _fail "population-scan [$rel]: reached by a test through a rooted path" \
      "named by some test file but never through a rooted reference — undecidable from text, so nothing here pins it" \
      "  fix: drive it with a CANCELLED fixture through \"\$REPO_ROOT/$rel\", or exempt it where its behaviour belongs"
  done <<< "$SCS_PS_UNDECIDABLE_PATHS"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    _fail "population-scan [$rel]: pinned by at least one test file" \
      "this file reads task status and no tests/test-*.sh names it" \
      "  fix: drive it with a CANCELLED fixture here, or wherever its behaviour belongs"
  done <<< "$SCS_PS_UNPINNED_PATHS"
  scs_pin_scan_line "population-scan"
  assert_eq "population-scan: coverage accounting adds up (N == M + K)" \
    "$SCS_PS_SCANNED" "$((SCS_PS_SKIPPED + SCS_PS_CHECKED))"
  assert_eq "population-scan: every discovered status consumer is reached by a test" \
    "$SCS_PS_FINDINGS" "0"

  PS_PINNED="$SCS_PS_PINNED"
  POP_FLOOR="${NAZGUL_STATUS_CONSUMER_FLOOR:-12}"
  if [ "$PS_PINNED" -ge "$POP_FLOOR" ]; then
    _pass "population-scan: the walk actually reached the tree ($PS_PINNED consumers >= $POP_FLOOR)"
  else
    _fail "population-scan: the walk actually reached the tree" \
      "only $PS_PINNED consumer(s) pinned — a broken predicate, not a clean tree"
  fi
fi

# The pin classifier, dogfooded against a tests dir built to contain each class: the
# shipped tree yields only `reached`, so two arms would otherwise never be driven.
PIN_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-pin-class-XXXXXX")
mkdir -p "$PIN_SCRATCH/tests"
cat > "$PIN_SCRATCH/tests/test-driver.sh" <<'PINDRV'
#!/usr/bin/env bash
bash "$REPO_ROOT/scripts/reached-consumer.sh" --check
PINDRV
cat > "$PIN_SCRATCH/tests/test-mentions.sh" <<'PINMEN'
#!/usr/bin/env bash
# see also scripts/commented-consumer.sh, which this file does not drive
for known in scripts/listed-consumer.sh; do
  assert_contains "discovery still reaches $known" "$SCS_CONSUMERS" "$known"
done
PINMEN
assert_eq "pin-class dogfood: a rooted non-comment reference is reached" \
  "$(scs_pin_class "$PIN_SCRATCH/tests" scripts/reached-consumer.sh)" "reached"
assert_eq "pin-class dogfood: a mention inside a comment is undecidable, not a pin" \
  "$(scs_pin_class "$PIN_SCRATCH/tests" scripts/commented-consumer.sh)" "named-only"
assert_eq "pin-class dogfood: another test's discovery list is not a pin (the circular case)" \
  "$(scs_pin_class "$PIN_SCRATCH/tests" scripts/listed-consumer.sh)" "named-only"
assert_eq "pin-class dogfood: an unmentioned file is a finding, not a skip" \
  "$(scs_pin_class "$PIN_SCRATCH/tests" scripts/absent-consumer.sh)" "unnamed"

# TASK-017: the DISPOSITION, dogfooded on the same tree — the shipped population is
# all `reached`, so the two failing classes are otherwise never driven end to end.
mkdir -p "$PIN_SCRATCH/scripts"
for _c in reached commented listed absent; do
  printf '#!/usr/bin/env bash\n# status: DONE\n' > "$PIN_SCRATCH/scripts/${_c}-consumer.sh"
done
PIN_POP='scripts/reached-consumer.sh
scripts/commented-consumer.sh
scripts/listed-consumer.sh
scripts/absent-consumer.sh'
scs_pin_scan "$PIN_SCRATCH/tests" "$PIN_SCRATCH" "$PIN_POP"
assert_eq "pin-scan dogfood: a named-but-unreached site is a FINDING, not a skip" \
  "$SCS_PS_UNDECIDABLE" "2"
assert_eq "pin-scan dogfood: nothing is skipped when every file is on disk" "$SCS_PS_SKIPPED" "0"
assert_eq "pin-scan dogfood: the undecidable sites are counted as checked" "$SCS_PS_CHECKED" "4"
assert_eq "pin-scan dogfood: findings = undecidable + unpinned" "$SCS_PS_FINDINGS" "3"
assert_contains "pin-scan dogfood: each undecidable site is named" \
  "$SCS_PS_UNDECIDABLE_PATHS" "scripts/commented-consumer.sh"
assert_eq "pin-scan dogfood: N == M + K" \
  "$SCS_PS_SCANNED" "$((SCS_PS_SKIPPED + SCS_PS_CHECKED))"

scs_pin_scan "$PIN_SCRATCH/tests" "$PIN_SCRATCH" "$PIN_POP
scripts/vanished-consumer.sh"
assert_eq "pin-scan dogfood: the one surviving skip is 'vanished', and it is counted" \
  "$SCS_PS_VANISHED" "1"
assert_eq "pin-scan dogfood: a vanished file still balances N == M + K" \
  "$SCS_PS_SCANNED" "$((SCS_PS_SKIPPED + SCS_PS_CHECKED))"
assert_contains "pin-scan dogfood: the coverage line names its only skip reason" \
  "$(scs_pin_scan_line population-scan)" "1 skipped (vanished=1)"
rm -rf "$PIN_SCRATCH"

# lean-comments: allow-run — the shape of the defect, kept beside the pin that detects it.
# TASK-017 / issue #230: a checking tool that cannot reproduce its own verdict is
# evidence of nothing. `producer | grep -q` is a SIGPIPE race under `set -o pipefail`
# — grep exits at the first match, the producer dies 141, pipefail returns 141 — and
# it only bites once the de-commented body outruns the 64 KiB pipe buffer. The pin
# therefore BUILDS an oversized consumer instead of trusting the shipped tree's
# largest file to stay large, so it cannot be silently disarmed by a refactor.
DET_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-scs-determinism-XXXXXX")
mkdir -p "$DET_SCRATCH/scripts"
{
  printf '#!/usr/bin/env bash\n'
  printf 'state="IN_PROGRESS"\n'
  awk 'BEGIN { for (i = 0; i < 16000; i++) printf "pad_%06d=\"body wider than one pipe buffer\"\n", i }'
  printf 'read_frontmatter_field "$manifest" status\n'
} > "$DET_SCRATCH/scripts/oversized-consumer.sh"
DET_BODY=$(scs_code "$DET_SCRATCH/scripts/oversized-consumer.sh")
if [ "${#DET_BODY}" -gt 65536 ]; then
  _pass "determinism: the pin's own subject outruns the pipe buffer (${#DET_BODY} bytes > 65536)"
else
  _fail "determinism: the pin's own subject outruns the pipe buffer" \
    "body is ${#DET_BODY} bytes, at or under the 65536-byte pipe buffer — the pin is disarmed"
fi

DET_SEEN=""
for _i in $(seq 1 12); do
  if scs_is_consumer "$DET_SCRATCH/scripts/oversized-consumer.sh"; then _r=consumer; else _r=not-consumer; fi
  case " $DET_SEEN " in *" $_r "*) ;; *) DET_SEEN="$DET_SEEN $_r" ;; esac
done
DET_SEEN="${DET_SEEN# }"
assert_eq "determinism: scs_is_consumer returns one answer over 12 runs on one oversized file" \
  "$DET_SEEN" "consumer"

# The whole-scan property, asserted the way a caller experiences it: the same tree,
# twice in one test, must agree on `checked` and `findings`.
scs_run "$REPO_ROOT" && DET_N1="$SCS_N" DET_K1="$SCS_K" DET_F1="$SCS_F" DET_U1="$SCS_UNTRIAGED$SCS_UNCLASSIFIED"
scs_run "$REPO_ROOT" && DET_K2="$SCS_K" DET_F2="$SCS_F" DET_U2="$SCS_UNTRIAGED$SCS_UNCLASSIFIED"
assert_eq "determinism: two scs_run passes over one tree agree on checked" \
  "${DET_K1-run1-unset}" "${DET_K2-run2-unset}"
assert_eq "determinism: two scs_run passes over one tree agree on findings" \
  "${DET_F1-run1-unset}" "${DET_F2-run2-unset}"
assert_eq "determinism: and on WHICH files those findings are" \
  "${DET_U1-run1-unset}" "${DET_U2-run2-unset}"

# Equality between two runs cannot see a walk that collapses in BOTH, so this
# denominator is derived independently of the walk it checks.
DET_TREE_N=$(find "$REPO_ROOT/scripts" \( -type f -o -type l \) | wc -l | tr -d ' ')
DET_STDIN_N=$(printf 'swallow-me\n%.0s' $(seq 1 200) | { scs_run "$REPO_ROOT" && printf '%s' "$SCS_N"; })
assert_eq "determinism: the walk enumerates every file in the tree (independent count)" \
  "${DET_N1-run1-unset}" "$DET_TREE_N"
assert_eq "determinism: and still does so when the caller's stdin is full (dedicated fd)" \
  "$DET_STDIN_N" "$DET_TREE_N"
rm -rf "$DET_SCRATCH"

report_results
