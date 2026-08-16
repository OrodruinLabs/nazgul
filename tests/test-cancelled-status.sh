#!/usr/bin/env bash
set -uo pipefail
# NOT set -e: exit codes of the code under test are asserted.

# Test: the CANCELLED terminal status (ADR-022) — vocabulary, edge set, quarantine
# refusal, dependency gate, shared counter, loop completion, and /nazgul:task skip.
TEST_NAME="test-cancelled-status"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/task-transition-guard.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# FIRST assertion deliberately: at the pre-change base this edge falls through to
# `*) return 1`, which reads honestly as "the token did not exist".
if ttg_valid_transition READY CANCELLED; then
  _pass "ttg_valid_transition: READY -> CANCELLED allowed"
else
  _fail "ttg_valid_transition: READY -> CANCELLED allowed" "expected: 0" "  actual: nonzero"
fi

for from in PLANNED IN_PROGRESS IMPLEMENTED IN_REVIEW APPROVED CHANGES_REQUESTED BLOCKED; do
  if ttg_valid_transition "$from" CANCELLED; then
    _pass "ttg_valid_transition: ${from} -> CANCELLED allowed"
  else
    _fail "ttg_valid_transition: ${from} -> CANCELLED allowed" "expected: 0" "  actual: nonzero"
  fi
done

# CANCELLED is terminal: no out-edge, and DONE has no edge into it.
for to in PLANNED READY IN_PROGRESS IMPLEMENTED IN_REVIEW APPROVED CHANGES_REQUESTED DONE BLOCKED CANCELLED; do
  if ttg_valid_transition CANCELLED "$to"; then
    _fail "ttg_valid_transition: CANCELLED -> ${to} refused" "expected: nonzero" "  actual: 0"
  else
    _pass "ttg_valid_transition: CANCELLED -> ${to} refused"
  fi
done
if ttg_valid_transition DONE CANCELLED; then
  _fail "ttg_valid_transition: DONE -> CANCELLED refused" "expected: nonzero" "  actual: 0"
else
  _pass "ttg_valid_transition: DONE -> CANCELLED refused"
fi

# One token, one meaning: the status vocabulary gains it, the verdict one must not.
if _in_list CANCELLED "$VALID_STATUSES"; then
  _pass "VALID_STATUSES: CANCELLED is a member"
else
  _fail "VALID_STATUSES: CANCELLED is a member" "expected: 0" "  actual: nonzero"
fi
if _in_list CANCELLED "$VALID_VERDICTS"; then
  _fail "VALID_VERDICTS: CANCELLED does not collide with a verdict" "expected: nonzero" "  actual: 0"
else
  _pass "VALID_VERDICTS: CANCELLED does not collide with a verdict"
fi
if _in_list SKIPPED "$VALID_VERDICTS"; then
  _pass "VALID_VERDICTS: SKIPPED still means a skipped review"
else
  _fail "VALID_VERDICTS: SKIPPED still means a skipped review" "expected: 0" "  actual: nonzero"
fi

setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "CANCELLED"
assert_eq "get_task_status: CANCELLED manifest resolves to CANCELLED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md" "PLANNED")" "CANCELLED"
teardown_temp_dir

# Shared counter: its own bucket, never the off-vocabulary arm.
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "BLOCKED" "none" "skipped by operator — mentions skip in free text"
count_tasks_and_find_active "$TEST_DIR/nazgul/tasks" 2>"$TEST_DIR/count.err" >/dev/null
COUNT_ERR=$(cat "$TEST_DIR/count.err")
assert_eq "count_tasks_and_find_active: CANCELLED_COUNT is 1" "${CANCELLED_COUNT:-unset}" "1"
assert_eq "count_tasks_and_find_active: INVALID_COUNT is 0" "${INVALID_COUNT:-unset}" "0"
assert_eq "count_tasks_and_find_active: BLOCKED_COUNT is 1" "${BLOCKED_COUNT:-unset}" "1"
assert_eq "count_tasks_and_find_active: TOTAL_COUNT is 3" "${TOTAL_COUNT:-unset}" "3"
assert_eq "count_tasks_and_find_active: INVALID_TASKS is empty" "${INVALID_TASKS-unset}" ""
assert_not_contains "count_tasks_and_find_active: no off-vocabulary diagnostic for CANCELLED" \
  "$COUNT_ERR" "off-vocabulary"
teardown_temp_dir

# Dependency gate (ADR-022 veto site 5), in every granularity.
setup_temp_dir
setup_nazgul_dir
create_config
NAZ="$TEST_DIR/nazgul"
for gran in task group feature; do
  jq --arg g "$gran" '.review_gate.granularity = $g' "$NAZ/config.json" > "$NAZ/config.tmp" \
    && mv "$NAZ/config.tmp" "$NAZ/config.json"
  if ttg_dependency_satisfied "$NAZ" "CANCELLED"; then
    _pass "ttg_dependency_satisfied: CANCELLED satisfies at granularity=${gran}"
  else
    _fail "ttg_dependency_satisfied: CANCELLED satisfies at granularity=${gran}" \
      "expected: 0" "  actual: nonzero (expected set: ${TTG_DEP_EXPECTED})"
  fi
  if ttg_dependency_satisfied "$NAZ" "BLOCKED"; then
    _fail "ttg_dependency_satisfied: BLOCKED does not satisfy at granularity=${gran}" \
      "expected: nonzero" "  actual: 0"
  else
    _pass "ttg_dependency_satisfied: BLOCKED does not satisfy at granularity=${gran}"
  fi
  assert_contains "ttg_dependency_satisfied: diagnostic names CANCELLED at granularity=${gran}" \
    "$TTG_DEP_EXPECTED" "CANCELLED"
done
jq '.review_gate.granularity = "task" | .afk.yolo = true' "$NAZ/config.json" > "$NAZ/config.tmp" \
  && mv "$NAZ/config.tmp" "$NAZ/config.json"
if ttg_dependency_satisfied "$NAZ" "CANCELLED"; then
  _pass "ttg_dependency_satisfied: CANCELLED satisfies in YOLO"
else
  _fail "ttg_dependency_satisfied: CANCELLED satisfies in YOLO" "expected: 0" "  actual: nonzero"
fi
teardown_temp_dir

# The distinction is mechanical: a CANCELLED dependency promotes its dependent, a
# BLOCKED one whose free-text reason says "skipped" does not.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "BLOCKED" "none" "skipped by operator via /nazgul:task skip"
create_task_file "TASK-003" "PLANNED" "TASK-001"
create_task_file "TASK-004" "PLANNED" "TASK-002"
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-003" PLANNED READY \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-003.md")" 2>/dev/null; then
  _pass "ttg_validate_transition: PLANNED -> READY promotes behind a CANCELLED dependency"
else
  _fail "ttg_validate_transition: PLANNED -> READY promotes behind a CANCELLED dependency" \
    "expected: 0" "  actual: nonzero"
fi
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-004" PLANNED READY \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-004.md")" 2>/dev/null; then
  _fail "ttg_validate_transition: a BLOCKED dependency whose reason says 'skipped' still holds" \
    "expected: nonzero" "  actual: 0"
else
  _pass "ttg_validate_transition: a BLOCKED dependency whose reason says 'skipped' still holds"
fi
teardown_temp_dir

# BLOCKED -> CANCELLED must not become a second exit from the ADR-020 quarantine.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "BLOCKED"
QUARANTINED="$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")
- **Blocked kind**: reconciliation
- **Blocked reason**: status changed outside a completed transition"
LAUNDER_ERR=$(ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-001" BLOCKED CANCELLED \
  "$QUARANTINED" 2>&1) && LAUNDER_EC=0 || LAUNDER_EC=$?
assert_eq "ttg_validate_transition: reconciliation quarantine refuses BLOCKED -> CANCELLED" \
  "$LAUNDER_EC" "1"
assert_contains "ttg_validate_transition: the refusal names repair" "$LAUNDER_ERR" "repair"

ORDINARY="$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")
- **Blocked reason**: skipped by operator via /nazgul:task skip"
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-001" BLOCKED CANCELLED \
  "$ORDINARY" 2>/dev/null; then
  _pass "ttg_validate_transition: an ordinary BLOCKED task may be cancelled"
else
  _fail "ttg_validate_transition: an ordinary BLOCKED task may be cancelled" \
    "expected: 0" "  actual: nonzero"
fi

# Anchored like its sibling check: an already-repaired kind is not in quarantine.
REPAIRED="$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")
- **Blocked kind**: reconciliation (repaired 2026-08-15T00:00:00Z)"
if ttg_validate_transition "$TEST_DIR/nazgul" "$TEST_DIR" "TASK-001" BLOCKED CANCELLED \
  "$REPAIRED" 2>/dev/null; then
  _pass "ttg_validate_transition: an already-repaired kind does not re-qualify as quarantine"
else
  _fail "ttg_validate_transition: an already-repaired kind does not re-qualify as quarantine" \
    "expected: 0" "  actual: nonzero"
fi
teardown_temp_dir

COMPLETION_CONFIG=('.agents.reviewers = ["code-reviewer"]' '.learning.auto_distill_post_loop = false'
  '.docs.verify_comments = false' '.self_audit.enabled = false')

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "CANCELLED"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_exit_code "completion: DONE + CANCELLED completes the loop" "$HOOK_EC" 0
assert_file_contains "completion: objective_complete emitted" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"objective_complete"'
assert_file_contains "completion: objective_complete carries cancelled_count" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"cancelled_count"'
assert_contains "completion: reports the done/cancelled split" "$HOOK_OUTPUT" "2/3 done, 1 cancelled"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "CANCELLED"
run_hook
assert_exit_code "completion: an all-cancelled objective completes" "$HOOK_EC" 0
assert_contains "completion: an objective that shipped nothing says so" \
  "$HOOK_OUTPUT" "0/3 done, 3 cancelled — no task shipped"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
create_review_dir "TASK-003"
run_hook
assert_exit_code "completion: an all-done objective is unchanged" "$HOOK_EC" 0
assert_not_contains "completion: all-done reports no cancellation" "$HOOK_OUTPUT" "cancelled"
assert_file_contains "completion: all-done records cancelled_count 0" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"cancelled_count":0'
teardown_temp_dir

# The post-loop gates announce the same summary, so a cancelled task is named there too.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "CANCELLED"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_contains "completion: the learning gate names the done/cancelled split" \
  "$HOOK_OUTPUT" "2/3 done, 1 cancelled — POST-LOOP LEARNING GATE"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
create_review_dir "TASK-003"
run_hook
assert_contains "completion: an uncancelled objective keeps the original wording" \
  "$HOOK_OUTPUT" "all 3/3 tasks complete — POST-LOOP LEARNING GATE"
teardown_temp_dir

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config "${COMPLETION_CONFIG[@]}"
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "BLOCKED" "none" "skipped by operator via /nazgul:task skip"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_file_not_contains "completion: a BLOCKED task does not complete the loop" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"objective_complete"'
# RW-B: the per-iteration census now always prints a `N cancelled` bucket, so the
# original whole-output substring match hit its own zero. Count, then exclude it.
assert_contains "completion: the census counts the BLOCKED task as blocked, not cancelled" \
  "$HOOK_OUTPUT" "1 blocked, 0 planned, 0 cancelled"
assert_not_contains "completion: a 'skip'-worded BLOCKED reason is not read as cancellation" \
  "$(printf '%s\n' "$HOOK_OUTPUT" | grep -v '^Tasks: ')" "cancelled"
teardown_temp_dir

SKILL="$REPO_ROOT/skills/task/SKILL.md"
SKIP_SECTION=$(awk '/^#### `skip TASK-NNN`/{f=1} f && /^#### `unblock TASK-NNN`/{exit} f' "$SKILL")
UNBLOCK_SECTION=$(awk '/^#### `unblock TASK-NNN`/{f=1} f && /^#### `add /{exit} f' "$SKILL")

assert_contains "skip: transitions to CANCELLED" "$SKIP_SECTION" "<CURRENT_STATUS> CANCELLED"
assert_not_contains "skip: no longer records the skip as BLOCKED" "$SKIP_SECTION" "<CURRENT_STATUS> BLOCKED"
assert_not_contains "skip: no dependency-graph surgery" "$SKIP_SECTION" "edit that line to"
assert_not_contains "skip: does not report a removed dependency" \
  "$SKIP_SECTION" "had the dependency removed"
assert_contains "skip: reports the downstream auto-promotion count" "$SKIP_SECTION" "auto-promote"
assert_contains "skip: names the reconciliation refusal" "$SKIP_SECTION" "repair"
assert_contains "skip: treats DONE and CANCELLED as terminal" "$SKIP_SECTION" "\`DONE\` or \`CANCELLED\`"
assert_contains "unblock: refuses a terminal status" "$UNBLOCK_SECTION" "which is terminal"
assert_contains "unblock: still refuses a reconciliation quarantine" \
  "$UNBLOCK_SECTION" "\`reconciliation\` — do NOT unblock"

# "Looked and found none" must not print the same as "never looked" (RULES.md §15).
SURFACES="scripts/lib/structured-state.sh
scripts/lib/task-transition-guard.sh
scripts/lib/task-utils.sh
scripts/stop-hook.sh
skills/task/SKILL.md"
SURF_SCANNED=0; SURF_CHECKED=0; SURF_UNREADABLE=0; SURF_FINDINGS=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  SURF_SCANNED=$((SURF_SCANNED + 1))
  if [ ! -r "$REPO_ROOT/$rel" ]; then
    SURF_UNREADABLE=$((SURF_UNREADABLE + 1))
    _skip "surface-scan: $rel is unreadable — not checked"
    continue
  fi
  SURF_CHECKED=$((SURF_CHECKED + 1))
  if grep -q "CANCELLED" "$REPO_ROOT/$rel"; then
    _pass "surface-scan: $rel names CANCELLED"
  else
    SURF_FINDINGS=$((SURF_FINDINGS + 1))
    _fail "surface-scan: $rel names CANCELLED" "expected: at least one occurrence" "  actual: none"
  fi
done <<< "$SURFACES"
SURF_SKIPPED=$((SURF_SCANNED - SURF_CHECKED))
echo "  surface-scan: ${SURF_SCANNED} scanned, ${SURF_SKIPPED} skipped (unreadable=${SURF_UNREADABLE}), ${SURF_CHECKED} checked, ${SURF_FINDINGS} findings"
assert_eq "surface-scan: scanned == skipped + checked" \
  "$SURF_SCANNED" "$((SURF_SKIPPED + SURF_CHECKED))"
assert_eq "surface-scan: every surface was checked" "$SURF_CHECKED" "5"

report_results
