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

# Probe that does NOT call the code under test, so a base-tree replay measures
# the defect rather than the absence of a helper this patch introduces.
file_mode_probe() {
  nz_file_mode "$1"
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
# PR #86 suppressed finding: a bare relative path does not resolve from a project-root
# shell — the plugin lives under the plugin cache, so the operator got an unrunnable cmd.
assert_contains "Q1: repair route is rooted at the plugin, not the caller's cwd" \
  "$HOOK_OUTPUT" 'with: ${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh repair TASK-001'
assert_not_contains "Q1: no bare-relative repair command survives in the advisory" \
  "$HOOK_OUTPUT" "with: scripts/task-transition.sh"

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

# --- Q1b (PR #86 review): every reader of the typed quarantine fields is
# `^`-anchored, so appending to a newline-less manifest would hide the first one.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' \
  '.learning.auto_distill_post_loop = false' '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_review_dir "TASK-001"
Q1B_BASE=$(git -C "$TEST_DIR" rev-parse HEAD~1)
Q1B_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
reviewed_manifest TASK-001 IN_REVIEW "$Q1B_BASE" "$Q1B_HEAD" \
  > "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_hook
sed -i.bak 's/^status: IN_REVIEW/status: DONE/' "$TEST_DIR/nazgul/tasks/TASK-001.md" \
  && rm -f "$TEST_DIR/nazgul/tasks/TASK-001.md.bak"
printf '%s' "$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")" \
  > "$TEST_DIR/nazgul/tasks/TASK-001.md.nonl" \
  && mv "$TEST_DIR/nazgul/tasks/TASK-001.md.nonl" "$TEST_DIR/nazgul/tasks/TASK-001.md"
assert_eq "Q1b: the fixture manifest really has no trailing newline" \
  "$(tail -c 1 "$TEST_DIR/nazgul/tasks/TASK-001.md" | od -An -c | tr -d ' ')" "k"
run_hook
assert_eq "Q1b: a newline-less manifest is still quarantined" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_eq "Q1b: the first appended field is visible to its anchored reader" \
  "$(manifest_field TASK-001 'Blocked kind')" "reconciliation"
assert_eq "Q1b: the later appended fields are anchored too" \
  "$(manifest_field TASK-001 'Blocked observed')" "DONE"
run_cmd repair TASK-001
assert_exit_code "Q1b: repair accepts the typed quarantine it can now read" "$CMD_EC" 0
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
assert_contains "R1: the reported walk names the edges actually traversed" \
  "$CMD_OUT" "BLOCKED -> IN_REVIEW -> DONE"
assert_not_contains "R1: the reported walk does not start from the pre-quarantine status" \
  "$CMD_OUT" "IMPLEMENTED -> IN_REVIEW"
assert_not_contains "R1: the two-edge walk does not advertise the task-PR APPROVED hop" \
  "$CMD_OUT" "APPROVED"
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

# --- R1b (PR #86 review): the repaired-marker rewrite goes through a temp file,
# which takes the umask mode unless the manifest's own mode is carried over. ---
quarantine_fixture
chmod 640 "$TEST_DIR/nazgul/tasks/TASK-001.md"
R1B_MODE_BEFORE=$(_ttg_file_mode "$TEST_DIR/nazgul/tasks/TASK-001.md")
run_cmd repair TASK-001
assert_exit_code "R1b: repair succeeds on a non-default-mode manifest" "$CMD_EC" 0
R1B_MODE_AFTER=$(_ttg_file_mode "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "R1b: the probe reads back the fixture's own 640, not any octal string" \
  "${R1B_MODE_BEFORE#0}" "640"
assert_eq "R1b: the repaired-marker rewrite preserves the manifest mode" \
  "$R1B_MODE_AFTER" "$R1B_MODE_BEFORE"
assert_file_not_exists "R1b: no repair temp file is left on disk" \
  "$TEST_DIR/nazgul/tasks/TASK-001.md.repair.tmp"
teardown_temp_dir

# --- R1c (PR #86 review): the repaired-marker rewrite no longer uses a PREDICTABLE
# `.repair.tmp`, so a symlink pre-created there cannot be aimed at another file. ---
quarantine_fixture
R1C_CANARY="$TEST_DIR/canary.txt"
printf 'do-not-truncate\n' > "$R1C_CANARY"
chmod 600 "$R1C_CANARY"
ln -s "$R1C_CANARY" "$TEST_DIR/nazgul/tasks/TASK-001.md.repair.tmp"
run_cmd repair TASK-001
assert_exit_code "R1c: repair succeeds despite a pre-placed .repair.tmp symlink" "$CMD_EC" 0
assert_eq "R1c: the symlink target is not truncated" \
  "$(cat "$R1C_CANARY")" "do-not-truncate"
assert_eq "R1c: the symlink target is not re-moded to the manifest mode" \
  "$(file_mode_probe "$R1C_CANARY")" "600"
if [ -L "$TEST_DIR/nazgul/tasks/TASK-001.md" ]; then
  _fail "R1c: the manifest is not replaced by the pre-placed symlink"
else
  _pass "R1c: the manifest is not replaced by the pre-placed symlink"
fi
assert_contains "R1c: the quarantine marker is still repaired in place" \
  "$(manifest_field TASK-001 'Blocked kind')" "repaired"
R1C_STRAY=$(find "$TEST_DIR/nazgul/tasks" -name '.nz-rewrite.*' | wc -l | tr -d ' ')
assert_eq "R1c: no colocated staging file is left behind" "$R1C_STRAY" "0"
teardown_temp_dir

# --- R1d: a rewrite that CANNOT proceed refuses loudly instead of following a
# symlinked destination, which is the state R1c's old temp-path check stood in for. ---
quarantine_fixture
R1D_CANARY="$TEST_DIR/other.txt"
printf 'untouched\n' > "$R1D_CANARY"
R1D_ERR=$(nz_rewrite_file "$TEST_DIR/link.md" cat "$R1D_CANARY" 2>&1) && R1D_EC=0 || R1D_EC=$?
assert_exit_code "R1d: a missing destination is refused" "$R1D_EC" 1
assert_contains "R1d: the refusal says why" "$R1D_ERR" "not a regular non-symlink file"
ln -s "$R1D_CANARY" "$TEST_DIR/link.md"
R1D_ERR=$(nz_rewrite_file "$TEST_DIR/link.md" printf 'clobbered\n' 2>&1) && R1D_EC=0 || R1D_EC=$?
assert_exit_code "R1d: a symlinked destination is refused" "$R1D_EC" 1
assert_eq "R1d: the refused symlink target is untouched" \
  "$(cat "$R1D_CANARY")" "untouched"
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

# R4: the ledger append runs after the manifest rename, so a broken ledger fails
# the edge with the new status already on disk — the real mid-walk case.
quarantine_fixture
rm -f "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
ln -s /dev/null "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
run_cmd repair TASK-001
assert_exit_code "R4: a mid-walk edge failure fails the repair" "$CMD_EC" 1
assert_eq "R4: the walk re-enters the quarantine it had already left" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_contains "R4: the message reports leaving and re-entering, not preservation" \
  "$CMD_OUT" "had already left the quarantine"
assert_not_contains "R4: the message does not claim the quarantine was untouched" \
  "$CMD_OUT" "the quarantine is preserved"
assert_contains "R4: the halt event types the disposition" \
  "$(events_for reconciliation_repair)" '"quarantine":"restored"'
assert_contains "R4: the halt event reports the true on-disk status" \
  "$(events_for reconciliation_repair)" '"live_status":"BLOCKED"'
assert_eq "R4: the restored quarantine is still typed and repairable" \
  "$(manifest_field TASK-001 'Blocked kind')" "reconciliation"
rm -f "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
run_cmd repair TASK-001
assert_exit_code "R4: repair is retryable after a restored halt" "$CMD_EC" 0
assert_eq "R4: the retry completes the walk" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "DONE"
teardown_temp_dir

# R5: a halt before the first write reports preservation, and truthfully.
quarantine_fixture
mkdir -p "$TEST_DIR/nazgul/locks"
: > "$TEST_DIR/nazgul/locks/task-transition-TASK-001.lock"
run_cmd repair TASK-001
assert_exit_code "R5: an unusable lock fails the repair" "$CMD_EC" 1
assert_eq "R5: nothing left the quarantine" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_contains "R5: preservation is claimed only when it is true" \
  "$CMD_OUT" "the quarantine is intact at BLOCKED"
assert_contains "R5: the halt event types the disposition" \
  "$(events_for reconciliation_repair)" '"quarantine":"preserved"'
teardown_temp_dir

# R6: YOLO task-PR reaches DONE through APPROVED instead of refusing.
quarantine_fixture
jq '.afk.yolo = true | .afk.task_pr = true' "$TEST_DIR/nazgul/config.json" \
  > "$TEST_DIR/config.tmp" && mv "$TEST_DIR/config.tmp" "$TEST_DIR/nazgul/config.json"
run_cmd repair TASK-001
assert_exit_code "R6: repair is not deterministically broken under task-PR review" "$CMD_EC" 0
assert_eq "R6: repair still lands on DONE" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "DONE"
LEDGER="$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
assert_eq "R6: the walk goes through APPROVED, as this mode requires" \
  "$(jq -sr '[.[] | select(.task_id == "TASK-001" and .from == "IN_REVIEW" and .to == "APPROVED")] | length' "$LEDGER")" "1"
assert_eq "R6: APPROVED -> DONE is the recorded completion edge" \
  "$(jq -sr '[.[] | select(.task_id == "TASK-001" and .from == "APPROVED" and .to == "DONE")] | length' "$LEDGER")" "1"
assert_eq "R6: the mode-illegal direct edge is never attempted" \
  "$(jq -sr '[.[] | select(.task_id == "TASK-001" and .from == "IN_REVIEW" and .to == "DONE")] | length' "$LEDGER")" "0"
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
