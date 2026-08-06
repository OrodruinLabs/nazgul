#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-task-reconciliation-repair"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/task-utils.sh"
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"
COMMAND="$REPO_ROOT/scripts/task-transition.sh"
echo "=== $TEST_NAME ==="

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) || true
}

run_cmd() {
  CMD_EC=0
  CMD_OUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$COMMAND" "$@" 2>&1) || CMD_EC=$?
}

manifest_field() { # <task-id> <label>
  grep -m1 "^- \*\*$2\*\*:" "$TEST_DIR/nazgul/tasks/$1.md" \
    | sed 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//'
}

events_for() { # <event-name>
  jq -c --arg e "$1" 'select(.event == $e)' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true
}

# A reviewed, committed manifest whose file scope is deliberately outside
# scripts/**, tests/** so the red-run gate resolves not-applicable.
reviewed_manifest() { # <task-id> <status> <base-sha> <head-sha>
  printf -- '---\nstatus: %s\n---\n# %s: Test task\n\n## Metadata\n- **Depends on**: none\n- **Group**: 1\n- **Retry count**: 0/3\n- **Files modified**: ["docs/foo.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s — feat: work\n' \
    "$2" "$1" "$3" "$4"
}

# Leaves TASK-001 really quarantined by the hook: from IN_REVIEW, observed DONE.
quarantine_fixture() {
  setup_temp_dir
  setup_git_repo
  setup_nazgul_dir
  create_config '.agents.reviewers = ["code-reviewer"]' \
    '.learning.auto_distill_post_loop = false' '.docs.verify_comments = false' \
    '.self_audit.enabled = false'
  create_plan
  create_review_dir "TASK-001"
  FIX_BASE=$(git -C "$TEST_DIR" rev-parse HEAD~1)
  FIX_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
  reviewed_manifest TASK-001 IN_REVIEW "$FIX_BASE" "$FIX_HEAD" > "$TEST_DIR/nazgul/tasks/TASK-001.md"
  run_hook
  sed -i.bak 's/^status: IN_REVIEW/status: DONE/' "$TEST_DIR/nazgul/tasks/TASK-001.md" \
    && rm -f "$TEST_DIR/nazgul/tasks/TASK-001.md.bak"
  run_hook
}

# === AC1: typed reconciliation quarantine ===

quarantine_fixture
assert_eq "Q1: untrusted status is quarantined, never 'corrected'" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_eq "Q1: quarantine is typed by kind" \
  "$(manifest_field TASK-001 'Blocked kind')" "reconciliation"
assert_eq "Q1: quarantine records the checkpoint source status" \
  "$(manifest_field TASK-001 'Blocked from')" "IN_REVIEW"
assert_eq "Q1: quarantine records the untrusted observed status" \
  "$(manifest_field TASK-001 'Blocked observed')" "DONE"
assert_contains "Q1: human-readable reason is preserved alongside the typed fields" \
  "$(manifest_field TASK-001 'Blocked reason')" "outside the guarded Write/Edit/MultiEdit path"
assert_contains "Q1: diagnostic names the repair route" \
  "$HOOK_OUTPUT" "scripts/task-transition.sh repair TASK-001"

QUARANTINE_EVENT=$(events_for reconciliation_quarantine)
assert_contains "Q1: a reconciliation_quarantine event is emitted" "$QUARANTINE_EVENT" "reconciliation_quarantine"
assert_eq "Q1: event names the task" \
  "$(printf '%s' "$QUARANTINE_EVENT" | jq -r '.task_id')" "TASK-001"
assert_eq "Q1: event carries the checkpoint source" \
  "$(printf '%s' "$QUARANTINE_EVENT" | jq -r '.checkpoint_status')" "IN_REVIEW"
assert_eq "Q1: event carries the untrusted observed target" \
  "$(printf '%s' "$QUARANTINE_EVENT" | jq -r '.observed_status')" "DONE"
assert_eq "Q1: event records the action taken, not just the mismatch" \
  "$(printf '%s' "$QUARANTINE_EVENT" | jq -r '.action')" "quarantined"
teardown_temp_dir

# --- Q2: exact completed-edge reconciliation. Both directions come from ONE
# fixture so neither can pass vacuously. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
Q2_BASE=$(git -C "$TEST_DIR" rev-parse HEAD~1)
Q2_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
reviewed_manifest TASK-001 IN_PROGRESS "$Q2_BASE" "$Q2_HEAD" > "$TEST_DIR/nazgul/tasks/TASK-001.md"
reviewed_manifest TASK-002 READY "$Q2_BASE" "$Q2_HEAD" > "$TEST_DIR/nazgul/tasks/TASK-002.md"
run_hook
run_cmd transition TASK-001 IN_PROGRESS IMPLEMENTED
assert_exit_code "Q2: sanctioned command applies the edge" "$CMD_EC" 0
sed -i.bak 's/^status: READY/status: IN_PROGRESS/' "$TEST_DIR/nazgul/tasks/TASK-002.md" \
  && rm -f "$TEST_DIR/nazgul/tasks/TASK-002.md.bak"
run_hook
assert_eq "Q2: completed-edge authority is honored" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "IMPLEMENTED"
assert_not_contains "Q2: an honored edge gains no quarantine typing" \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")" "Blocked kind"
assert_eq "Q2: same-window write by another route is quarantined" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "BLOCKED"
assert_eq "Q2: the quarantined task is the one that is typed" \
  "$(manifest_field TASK-002 'Blocked kind')" "reconciliation"
Q2_TS=$(jq -r 'select(.task_id == "TASK-001") | .timestamp' "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl" | tail -1)
if ttg_transition_is_guarded "$TEST_DIR/nazgul" TASK-001 READY IMPLEMENTED "$Q2_TS"; then
  _fail "Q2: matching only the endpoint is not authority" "READY -> IMPLEMENTED matched an IN_PROGRESS edge"
else
  _pass "Q2: matching only the endpoint is not authority"
fi
teardown_temp_dir

# === AC2: evidence-gated, non-reimplementing repair ===

quarantine_fixture
run_cmd repair TASK-001
assert_exit_code "R1: a valid reviewed quarantine repairs" "$CMD_EC" 0
assert_eq "R1: repair lands on DONE" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "DONE"
assert_contains "R1: repair reports what it checked, not just that it passed" \
  "$CMD_OUT" "5 evidence checks run, 0 findings"
LEDGER="$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
assert_eq "R1: BLOCKED -> IN_REVIEW is recorded as a completed edge" \
  "$(jq -sr '[.[] | select(.task_id == "TASK-001" and .from == "BLOCKED" and .to == "IN_REVIEW")] | length' "$LEDGER")" "1"
assert_eq "R1: IN_REVIEW -> DONE is recorded as a completed edge" \
  "$(jq -sr '[.[] | select(.task_id == "TASK-001" and .from == "IN_REVIEW" and .to == "DONE")] | length' "$LEDGER")" "1"
assert_eq "R1: repair never routes through READY" \
  "$(jq -sr '[.[] | select(.task_id == "TASK-001" and .to == "READY")] | length' "$LEDGER")" "0"
assert_eq "R1: repair never redispatches implementation" \
  "$(jq -sr '[.[] | select(.task_id == "TASK-001" and .to == "IN_PROGRESS")] | length' "$LEDGER")" "0"
assert_contains "R1: the quarantine is marked repaired, not left open" \
  "$(manifest_field TASK-001 'Blocked kind')" "reconciliation (repaired"
assert_contains "R1: a reconciliation_repair event records the outcome" \
  "$(events_for reconciliation_repair)" '"action":"repaired"'
run_cmd repair TASK-001
assert_exit_code "R1: a repaired task cannot be repaired again" "$CMD_EC" 1
assert_contains "R1: the second refusal names the live status" "$CMD_OUT" "not BLOCKED"
teardown_temp_dir

# --- R2: incomplete evidence is denied, and the denial names WHICH evidence ---
quarantine_fixture
rm -f "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
run_cmd repair TASK-001
assert_exit_code "R2: missing reviewer verdict denies repair" "$CMD_EC" 1
assert_contains "R2: denial names the failing check" "$CMD_OUT" "review-verdicts"
assert_eq "R2: a denied repair preserves the quarantine" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_eq "R2: a denied repair leaves the quarantine typed and repairable" \
  "$(manifest_field TASK-001 'Blocked kind')" "reconciliation"
assert_contains "R2: denial is recorded as an event, not only on stderr" \
  "$(events_for reconciliation_repair)" '"reason":"incomplete_evidence"'
teardown_temp_dir

quarantine_fixture
awk '!/^- [0-9a-f]{7,64} /' "$TEST_DIR/nazgul/tasks/TASK-001.md" > "$TEST_DIR/stripped.md"
cp "$TEST_DIR/stripped.md" "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_cmd repair TASK-001
assert_exit_code "R3: missing commit evidence denies repair" "$CMD_EC" 1
assert_contains "R3: denial names the commit check" "$CMD_OUT" "commit-evidence"
assert_eq "R3: a denied repair preserves the quarantine" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
teardown_temp_dir

# === AC3: blocker-class routing ===

# --- B1: an ordinary typed blocker cannot use repair, and keeps its own route ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file TASK-001 BLOCKED none "review evidence missing (code-reviewer) — run /nazgul:review --materialize TASK-001"
printf -- '- **Blocked kind**: review-evidence\n' >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_cmd repair TASK-001
assert_exit_code "B1: a review-evidence blocker cannot use repair" "$CMD_EC" 1
assert_contains "B1: refusal names the actual blocker kind" "$CMD_OUT" "review-evidence"
assert_contains "B1: refusal routes the operator to the ordinary path" "$CMD_OUT" "/nazgul:task unblock"
assert_contains "B1: refusal is typed for telemetry" \
  "$(events_for reconciliation_repair)" '"reason":"wrong_blocker_kind"'
run_cmd transition TASK-001 BLOCKED READY
assert_exit_code "B1: the ordinary unblock route still works for it" "$CMD_EC" 0
assert_eq "B1: ordinary blocker returns to READY" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "READY"
teardown_temp_dir

# --- B2: "found no kind" and "found another kind" are distinct refusals ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file TASK-001 BLOCKED none "3 consecutive test failures"
run_cmd repair TASK-001
assert_exit_code "B2: an untyped blocker cannot use repair" "$CMD_EC" 1
assert_contains "B2: refusal says the kind is absent, not wrong" "$CMD_OUT" "no 'Blocked kind'"
assert_contains "B2: absence is its own telemetry reason" \
  "$(events_for reconciliation_repair)" '"reason":"untyped_blocker"'

# --- B3: forged/incoherent quarantine metadata fails closed ---
printf -- '- **Blocked kind**: reconciliation\n' >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_cmd repair TASK-001
assert_exit_code "B3: reconciliation kind without endpoints is refused" "$CMD_EC" 1
assert_contains "B3: refusal names the incomplete metadata" "$CMD_OUT" "quarantine metadata is incomplete"
printf -- '- **Blocked from**: IN_PROGRESS\n- **Blocked observed**: IMPLEMENTED\n' \
  >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_cmd repair TASK-001
assert_exit_code "B3: repair is closed to work that was never reviewed" "$CMD_EC" 1
assert_contains "B3: refusal names the unreviewed observed status" "$CMD_OUT" "not reviewed work"
assert_eq "B3: every refusal preserves the blocked status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
teardown_temp_dir

# --- B4: an already-repaired quarantine cannot re-open BLOCKED -> IN_REVIEW ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_review_dir TASK-001
create_task_file TASK-001 BLOCKED none "reconciliation quarantine"
printf -- '- **Blocked kind**: reconciliation (repaired 2026-01-01T00:00:00Z)\n' \
  >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_cmd transition TASK-001 BLOCKED IN_REVIEW
assert_exit_code "B4: a spent quarantine marker does not re-authorize the repair edge" "$CMD_EC" 1
assert_contains "B4: refusal names both authorized repair classes" \
  "$CMD_OUT" "review-evidence repair and typed reconciliation repair"
teardown_temp_dir

# === AC5: the READY dependency gate must be satisfiable at every granularity ===

# TASK-002 depends on TASK-001. Both call sites (the command's gate and the
# stop-hook's auto-promote) must agree, so each case drives both.
dep_fixture() { # <granularity> <dep-status>
  setup_temp_dir
  setup_git_repo
  setup_nazgul_dir
  create_config '.agents.reviewers = ["code-reviewer"]' \
    ".review_gate.granularity = \"$1\"" '.afk.yolo = true' \
    '.learning.auto_distill_post_loop = false' '.docs.verify_comments = false' \
    '.self_audit.enabled = false'
  create_plan
  create_task_file TASK-001 "$2"
  create_task_file TASK-002 PLANNED TASK-001
}

dep_fixture task IMPLEMENTED
run_cmd transition TASK-002 PLANNED READY
assert_exit_code "D1: task granularity still requires a reviewed dependency" "$CMD_EC" 1
assert_contains "D1: refusal names the task-granularity requirement" "$CMD_OUT" "not APPROVED/DONE"
run_hook
assert_eq "D1: auto-promote agrees with the command and declines" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "PLANNED"
teardown_temp_dir

dep_fixture task DONE
run_cmd transition TASK-002 PLANNED READY
assert_exit_code "D2: task granularity admits a DONE dependency" "$CMD_EC" 0
assert_eq "D2: dependent task reaches READY" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "READY"
teardown_temp_dir

dep_fixture group IMPLEMENTED
run_cmd transition TASK-002 PLANNED READY
assert_exit_code "D3: group granularity admits an IMPLEMENTED dependency" "$CMD_EC" 0
assert_eq "D3: dependent task reaches READY" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "READY"
teardown_temp_dir

dep_fixture feature IMPLEMENTED
run_cmd transition TASK-002 PLANNED READY
assert_exit_code "D4: feature granularity admits an IMPLEMENTED dependency" "$CMD_EC" 0
assert_eq "D4: dependent task reaches READY through the command" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "READY"
teardown_temp_dir

dep_fixture feature IMPLEMENTED
run_hook
assert_eq "D5: auto-promote admits the same dependency the command admits" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "READY"
teardown_temp_dir

dep_fixture feature PLANNED
run_cmd transition TASK-002 PLANNED READY
assert_exit_code "D6: an unimplemented dependency still refuses under feature" "$CMD_EC" 1
assert_contains "D6: refusal names the relaxed-but-real requirement" \
  "$CMD_OUT" "not IMPLEMENTED or later (review_gate.granularity=feature)"
run_hook
assert_eq "D6: auto-promote also declines an unimplemented dependency" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "PLANNED"
teardown_temp_dir

# === AC4: caller wiring is pinned in the two remaining prompt files ===

PIN_FILES="agents/review-gate.md
skills/task/SKILL.md"
PIN_FORBIDDEN='Use sed
sed -i
[Ss]et task status to
[Ss]et the task status to
[Ss]et task (back )?to (PLANNED|READY|IN_PROGRESS|IMPLEMENTED|IN_REVIEW|APPROVED|CHANGES_REQUESTED|DONE|BLOCKED)
[Mm]ark task (as )?(DONE|BLOCKED|APPROVED|IN_REVIEW|CHANGES_REQUESTED)
Update .Status:?. (field )?to
promote its status'

PIN_SCANNED=0
PIN_CHECKED=0
PIN_FINDINGS=0
while IFS= read -r pin_file; do
  [ -n "$pin_file" ] || continue
  PIN_SCANNED=$((PIN_SCANNED + 1))
  if [ ! -f "$REPO_ROOT/$pin_file" ]; then
    _fail "pin: $pin_file exists" "declared caller file is missing"
    continue
  fi
  PIN_CHECKED=$((PIN_CHECKED + 1))
  while IFS= read -r pin_pattern; do
    [ -n "$pin_pattern" ] || continue
    pin_hits=$(grep -nE "$pin_pattern" "$REPO_ROOT/$pin_file" || true)
    if [ -n "$pin_hits" ]; then
      PIN_FINDINGS=$((PIN_FINDINGS + 1))
      _fail "pin: $pin_file has no '$pin_pattern' status-write instruction" "$pin_hits"
    else
      _pass "pin: $pin_file has no '$pin_pattern' status-write instruction"
    fi
  done <<< "$PIN_FORBIDDEN"
  assert_contains "pin: $pin_file names the canonical transition command" \
    "$(cat "$REPO_ROOT/$pin_file")" "scripts/task-transition.sh"
done <<< "$PIN_FILES"

echo "  pin-scan: ${PIN_SCANNED} scanned, $((PIN_SCANNED - PIN_CHECKED)) skipped, ${PIN_CHECKED} checked, ${PIN_FINDINGS} findings"
assert_eq "pin: every declared caller file was actually scanned" "$PIN_CHECKED" "$PIN_SCANNED"

REVIEW_GATE_TEXT=$(cat "$REPO_ROOT/agents/review-gate.md")
assert_contains "pin: review-gate opens the unit through the command" \
  "$REVIEW_GATE_TEXT" "transition [TASK-ID] IMPLEMENTED IN_REVIEW"
assert_contains "pin: review-gate completes through the command" \
  "$REVIEW_GATE_TEXT" "transition TASK-NNN IN_REVIEW DONE"
assert_contains "pin: review-gate blocks through the command with a reason" \
  "$REVIEW_GATE_TEXT" 'IN_REVIEW BLOCKED --reason'
assert_contains "pin: review-gate is told not to forge a reconciliation quarantine" \
  "$REVIEW_GATE_TEXT" "Never write \`- **Blocked kind**: reconciliation\`"

TASK_SKILL_TEXT=$(cat "$REPO_ROOT/skills/task/SKILL.md")
assert_contains "pin: task skill routes a reconciliation blocker to repair" \
  "$TASK_SKILL_TEXT" "repair TASK-NNN"
assert_contains "pin: task skill unblocks ordinary blockers through the command" \
  "$TASK_SKILL_TEXT" "transition TASK-NNN BLOCKED READY"
assert_contains "pin: task skill explains why SKIPPED is not written" \
  "$TASK_SKILL_TEXT" "VALID_STATUSES"

report_results
