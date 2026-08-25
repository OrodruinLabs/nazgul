#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: stop-hook.sh loop engine, state machine, checkpoints, promotions
TEST_NAME="test-stop-hook"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
# get_task_status: frontmatter-first status reader (matches production, unlike a
# raw legacy-list-item grep) — used below to read back manifests the hook wrote.
source "$REPO_ROOT/scripts/lib/task-utils.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

# Helper: run hook capturing output and exit code
# Sets: HOOK_OUTPUT, HOOK_EC
run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# Probe that does NOT call the code under test, so a base-tree replay measures
# the defect rather than the absence of a helper this patch introduces.
file_mode_probe() {
  nz_file_mode "$1"
}

# === EXIT CONDITIONS (exit 0) ===

# --- Test 1: No config — exit 0 ---
setup_temp_dir
run_hook
assert_exit_code "no config: exit 0" "$HOOK_EC" 0
teardown_temp_dir

# --- Test 2: Paused — exit 0, paused STAYS true (sticky pause) ---
# Regression: an earlier stop-hook cleared .paused on the first Stop, so a pause
# never held past one iteration. Pause is now sticky — only /nazgul:start clears it.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.paused = true'
create_plan
run_hook
assert_exit_code "paused: exit 0" "$HOOK_EC" 0
val=$(jq -r '.paused' "$TEST_DIR/nazgul/config.json")
assert_eq "paused stays true (sticky)" "$val" "true"
# A second Stop must also stay paused (pause holds across iterations)
run_hook
assert_exit_code "paused (2nd Stop): exit 0" "$HOOK_EC" 0
val=$(jq -r '.paused' "$TEST_DIR/nazgul/config.json")
assert_eq "paused still true after 2nd Stop" "$val" "true"
teardown_temp_dir

# --- Test 3: All tasks DONE (learning opted out) — exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
create_review_dir "TASK-003"
run_hook
assert_exit_code "all tasks done (learning off): exit 0" "$HOOK_EC" 0
assert_file_contains "objective_complete emitted" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"objective_complete"'
assert_file_contains "objective_complete has total_tasks" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"total_tasks"'
assert_file_contains "objective_complete has done_count" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"done_count"'
assert_file_contains "objective_complete has iterations_used" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"iterations_used"'
teardown_temp_dir

# --- Test 3b: All DONE + learning on + not distilled — gate BLOCKS (exit 2) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-007"'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_exit_code "learning gate blocks completion: exit 2" "$HOOK_EC" 2
assert_contains "gate names the learner" "$HOOK_OUTPUT" "nazgul:learner"
assert_contains "gate names the marker" "$HOOK_OUTPUT" "nazgul/learning/.distilled"
# Attempt counter is created and scoped to the objective
assert_file_exists "attempts file created" "$TEST_DIR/nazgul/learning/.distill-attempts"
assert_contains "attempts scoped to objective" "$(cat "$TEST_DIR/nazgul/learning/.distill-attempts")" "FEAT-007"
teardown_temp_dir

# --- Test 3c: All DONE + marker matches objective — exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-007"' \
  '.docs.verify_comments = false' '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/learning"
echo "FEAT-007" > "$TEST_DIR/nazgul/learning/.distilled"
run_hook
assert_exit_code "distilled marker present: exit 0" "$HOOK_EC" 0
teardown_temp_dir

# --- Test 3d: Stale marker (different objective) still gates — exit 2 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-008"'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/learning"
echo "FEAT-007" > "$TEST_DIR/nazgul/learning/.distilled"
run_hook
assert_exit_code "stale marker re-gates new objective: exit 2" "$HOOK_EC" 2
teardown_temp_dir

# --- Test 3e: Backstop — after 3 attempts the gate gives up — exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-009"' \
  '.docs.verify_comments = false' '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/learning"
echo "FEAT-009 3" > "$TEST_DIR/nazgul/learning/.distill-attempts"
run_hook
assert_exit_code "learning gate backstop completes: exit 0" "$HOOK_EC" 0
assert_contains "backstop warns" "$HOOK_OUTPUT" "gave up"
teardown_temp_dir

# --- Test 4: Max iterations — exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 39' '.max_iterations = 40'
create_plan
create_task_file "TASK-001" "READY"
run_hook
assert_exit_code "max iterations: exit 0" "$HOOK_EC" 0
assert_contains "max iterations stderr" "$HOOK_OUTPUT" "Max iterations"
teardown_temp_dir

# --- Test 5: Consecutive failures exceeded — exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.safety.consecutive_failures = 4' '.safety.max_consecutive_failures = 5' '.safety._prev_done_count = 0'
create_plan
create_task_file "TASK-001" "READY"
run_hook
assert_exit_code "consecutive failures: exit 0" "$HOOK_EC" 0
assert_contains "consecutive failures stderr" "$HOOK_OUTPUT" "consecutive"
teardown_temp_dir

# --- Test 6: AFK timeout — exit 0, parameterised over TZ (regression: BSD
# `date -j -f` parsed the `Z` timestamp in LOCAL time while `date +%s` is
# absolute — inherited-TZ-only runs (CI=UTC, dev machine=Lisbon) stayed green
# while TZ=America/New_York deflates elapsed and the gate never fires) ---
# TZ is exported explicitly per iteration, never inherited from the shell.
past_ts=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
for tz in UTC "Europe/Lisbon" "America/New_York"; do
  setup_temp_dir
  setup_git_repo
  setup_nazgul_dir
  if [ -n "$past_ts" ]; then
    create_config ".afk.enabled = true" ".afk.timeout_minutes = 90" ".objective_set_at = \"$past_ts\""
    create_plan
    create_task_file "TASK-001" "READY"
    export TZ="$tz"
    run_hook
    unset TZ
    assert_exit_code "TZ=$tz AFK timeout: exit 0" "$HOOK_EC" 0
    assert_contains "TZ=$tz AFK timeout stderr" "$HOOK_OUTPUT" "AFK timeout"
    gate_line=$(grep '"event":"stop_gate"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null | tail -1)
    assert_contains "TZ=$tz stop_gate event emitted" "$gate_line" '"event":"stop_gate"'
    assert_contains "TZ=$tz stop_gate reason" "$gate_line" '"reason":"afk_timeout"'
    assert_eq "TZ=$tz stop_gate limit" "$(jq -r '.limit' <<<"$gate_line")" "90"
    computed=$(jq -r '.computed' <<<"$gate_line")
    assert_eq "TZ=$tz stop_gate computed >= limit" "$(( computed >= 90 ))" "1"
  else
    _skip "TZ=$tz AFK timeout: exit 0 (skipped — date format unavailable)"
    _skip "TZ=$tz AFK timeout stderr (skipped)"
    _skip "TZ=$tz stop_gate event emitted (skipped)"
    _skip "TZ=$tz stop_gate reason (skipped)"
    _skip "TZ=$tz stop_gate limit (skipped)"
    _skip "TZ=$tz stop_gate computed >= limit (skipped)"
  fi
  teardown_temp_dir
done

# --- AC7: parsed epoch for a fixed Z timestamp must be byte-identical across
# TZ values. Extracts the hook's own dialect-selection branch (the exact
# lines from the `if date -j ...` probe to its matching `fi`, with or
# without `-u`) so a regression in that snippet fails this test, not a
# hand-copied re-implementation of it. TZ is set explicitly per invocation,
# never inherited.
_dialect_snippet=$(awk '
  /^      if date -j/ { flag=1 }
  flag { print }
  flag && /^      fi$/ { exit }
' "$STOP_HOOK")
assert_contains "AC7: dialect snippet extraction found the branch" "$_dialect_snippet" "START_EPOCH="
_parse_dialect_epoch() {
  local ts="$1" tz="$2"
  SESSION_START="$ts" TZ="$tz" bash -c "$_dialect_snippet; echo \"\$START_EPOCH\""
}
fixed_ts="2026-06-15T12:00:00Z"
epoch_utc=$(_parse_dialect_epoch "$fixed_ts" "UTC")
epoch_lisbon=$(_parse_dialect_epoch "$fixed_ts" "Europe/Lisbon")
epoch_ny=$(_parse_dialect_epoch "$fixed_ts" "America/New_York")
assert_eq "AC7: parsed epoch identical UTC vs Europe/Lisbon" "$epoch_utc" "$epoch_lisbon"
assert_eq "AC7: parsed epoch identical UTC vs America/New_York" "$epoch_utc" "$epoch_ny"

# --- AC8: no-timeout-below-limit under a non-UTC TZ. elapsed=85m, limit=90m
# — close enough to the boundary that an unfixed east-of-UTC offset (Lisbon,
# +1h) crosses it and falsely fires; a west-of-UTC offset (New York) only
# deflates further and would not demonstrate the bug at this elapsed value. ---
near_limit_ts=$(date -u -v-85M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "85 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
for tz in "Europe/Lisbon" "America/New_York"; do
  setup_temp_dir
  setup_git_repo
  setup_nazgul_dir
  if [ -n "$near_limit_ts" ]; then
    create_config ".afk.enabled = true" ".afk.timeout_minutes = 90" ".objective_set_at = \"$near_limit_ts\""
    create_plan
    create_task_file "TASK-001" "READY"
    export TZ="$tz"
    run_hook
    unset TZ
    assert_exit_code "TZ=$tz AC8 below-limit: continues loop" "$HOOK_EC" 2
    assert_not_contains "TZ=$tz AC8 below-limit stderr" "$HOOK_OUTPUT" "AFK timeout"
  else
    _skip "TZ=$tz AC8 below-limit: continues loop (skipped — date format unavailable)"
    _skip "TZ=$tz AC8 below-limit stderr (skipped)"
  fi
  teardown_temp_dir
done

# === CONTINUE LOOP (exit 2) ===

# --- Test 7: READY tasks remain — exit 2 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
assert_exit_code "READY tasks: exit 2" "$HOOK_EC" 2
assert_contains "continue message" "$HOOK_OUTPUT" "Nazgul loop"
teardown_temp_dir

# --- Test 8: IN_PROGRESS task — exit 2 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
run_hook
assert_exit_code "IN_PROGRESS: exit 2" "$HOOK_EC" 2
assert_contains "active task in output" "$HOOK_OUTPUT" "TASK-001"
teardown_temp_dir

# --- Test 9: CHANGES_REQUESTED — exit 2 with warning ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "CHANGES_REQUESTED"
run_hook
assert_exit_code "CHANGES_REQUESTED: exit 2" "$HOOK_EC" 2
assert_contains "changes requested warning" "$HOOK_OUTPUT" "CHANGES_REQUESTED"
teardown_temp_dir

# --- Test 9b (RW-B, FEAT-031 rework): the per-iteration census must count
# CANCELLED and reconcile against TOTAL, as post-compact.sh:101 already does. ---
census_line() {
  printf '%s\n' "$HOOK_OUTPUT" | grep -m1 '^Tasks: ' || true
}

census_sum() {
  printf '%s\n' "$1" | sed 's/^Tasks: //; s/ | Total:.*//' \
    | tr ',' '\n' | awk '{s += $1} END {print s + 0}'
}

setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "CANCELLED"
create_task_file "TASK-003" "READY"
run_hook
assert_exit_code "census: loop continues with a cancelled task present" "$HOOK_EC" 2
CENSUS=$(census_line)
if [ -n "$CENSUS" ]; then
  _pass "census: the iteration status line was emitted (anchor matched)"
else
  _fail "census: the iteration status line was emitted (anchor matched)" \
    "no line starting 'Tasks: ' in the hook output — the assertions below would be vacuous"
fi
assert_contains "census: cancelled bucket is printed" "$CENSUS" "1 cancelled"
assert_contains "census: the total is printed" "$CENSUS" "| Total: 3"
assert_eq "census: printed buckets reconcile against TOTAL" "$(census_sum "$CENSUS")" "3"
teardown_temp_dir

# Control: with nothing cancelled the same line still reconciles, so the
# assertion above measures the cancelled bucket and not the sum by luck.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
CENSUS=$(census_line)
assert_contains "census control: zero cancelled is still printed" "$CENSUS" "0 cancelled"
assert_eq "census control: buckets reconcile with nothing cancelled" "$(census_sum "$CENSUS")" "2"
teardown_temp_dir

# === STATE MUTATIONS ===

# --- Test 10: Iteration incremented ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 5'
create_plan
create_task_file "TASK-001" "READY"
run_hook
val=$(jq -r '.current_iteration' "$TEST_DIR/nazgul/config.json")
assert_eq "iteration incremented to 6" "$val" "6"
teardown_temp_dir

# --- Test 11: Failures reset on progress ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.safety.consecutive_failures = 3' '.safety._prev_done_count = 1' '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
create_task_file "TASK-003" "READY"
run_hook
val=$(jq -r '.safety.consecutive_failures' "$TEST_DIR/nazgul/config.json")
assert_eq "failures reset to 0" "$val" "0"
teardown_temp_dir

# --- Test 12: Failures incremented on no progress ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.safety.consecutive_failures = 2' '.safety._prev_done_count = 1'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
val=$(jq -r '.safety.consecutive_failures' "$TEST_DIR/nazgul/config.json")
assert_eq "failures incremented to 3" "$val" "3"
teardown_temp_dir

# lean-comments: allow-run — the two counters disagreed about what finishing a task means.
# PATCH-007 item 14 — progress was DONE (+APPROVED in YOLO) while the completion condition is
# DONE + CANCELLED == TOTAL. An operator clearing backlog with /nazgul:task skip therefore shrank
# the outstanding set every iteration AND accrued a failure strike for it, stopping the run at
# max 5 with "no progress" on a loop measurably converging on its own completion condition.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.safety.consecutive_failures = 2' '.safety._prev_done_count = 0'
create_plan
create_task_file "TASK-001" "CANCELLED"
create_task_file "TASK-002" "READY"
run_hook
val=$(jq -r '.safety.consecutive_failures' "$TEST_DIR/nazgul/config.json")
assert_eq "a newly CANCELLED task is progress, not a consecutive-failure strike" "$val" "0"
val=$(jq -r '.safety._prev_done_count' "$TEST_DIR/nazgul/config.json")
assert_eq "and the recorded count includes it, so the next iteration compares like with like" \
  "$val" "1"
teardown_temp_dir

# --- Test 13: Checkpoint created ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 0'
create_plan
create_task_file "TASK-001" "READY"
run_hook
assert_file_exists "checkpoint created" "$TEST_DIR/nazgul/checkpoints/iteration-001.json"
teardown_temp_dir

# --- Test 14: Checkpoint has correct fields ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 0'
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
run_hook
cp_file="$TEST_DIR/nazgul/checkpoints/iteration-001.json"
assert_json_field "checkpoint iteration" "$cp_file" ".iteration" "1"
assert_json_field "checkpoint active task" "$cp_file" ".active_task.id" "TASK-001"
assert_json_field "checkpoint total tasks" "$cp_file" ".plan_snapshot.total_tasks" "1"
teardown_temp_dir

# --- Test 15: Recovery pointer updated in plan.md ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 0'
create_plan
create_task_file "TASK-002" "IN_PROGRESS"
run_hook
assert_file_contains "plan has TASK-002 in pointer" "$TEST_DIR/nazgul/plan.md" "TASK-002"
teardown_temp_dir

# --- Test 15b: Recovery Pointer updates a LIVE-format plan.md via label
# synonyms (MF-003 regression) ---
# The awk previously matched ONLY the pristine templates/plan.md bold-label
# format and silently no-op'd against real-world label variants — e.g. this
# repo's own FEAT-013 plan.md used "- **Active task**:" and
# "- **Last completed**:" instead of "- **Current Task:**" / "- **Last
# Action:**". Must actually rewrite the pointer (bytes change), not silently
# leave it stale.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 0'
cat > "$TEST_DIR/nazgul/plan.md" << 'LIVE_PLAN_EOF'
# Nazgul Plan

## Objective
Test objective

## Status Summary
- Total tasks: 0
- DONE: 0 | READY: 0 | IN_PROGRESS: 0

## Recovery Pointer
- **Last completed**: nothing yet
- **Active task**: none

## Tasks
LIVE_PLAN_EOF
create_task_file "TASK-003" "IN_PROGRESS"
run_hook
assert_file_contains "live-format plan gets TASK-003 via Active-task synonym" \
  "$TEST_DIR/nazgul/plan.md" "TASK-003"
assert_file_contains "live-format plan gets iteration text via Last-completed synonym" \
  "$TEST_DIR/nazgul/plan.md" "Iteration 1 completed"
assert_file_not_contains "live-format plan: stale 'nothing yet' value is gone" \
  "$TEST_DIR/nazgul/plan.md" "nothing yet"
teardown_temp_dir

# --- Test 15c: Recovery Pointer warns on stderr when NO label matches
# plan.md (MF-003 regression) ---
# When a plan.md's Recovery Pointer uses labels entirely outside the synonym
# allow-list, the awk must not silently no-op — it prints a loud warning to
# stderr naming the unmatched fields, and must NOT block the loop (exit 0).
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 0'
cat > "$TEST_DIR/nazgul/plan.md" << 'NOMATCH_PLAN_EOF'
# Nazgul Plan

## Objective
Test objective

## Status Summary
- Total tasks: 0
- DONE: 0 | READY: 0 | IN_PROGRESS: 0

## Recovery Pointer
- **Current phase**: Wave 2
- **Objective**: FEAT-XYZ
- **Blocked on**: nothing

## Tasks
NOMATCH_PLAN_EOF
BEFORE_POINTER=$(cat "$TEST_DIR/nazgul/plan.md")
create_task_file "TASK-004" "IN_PROGRESS"
run_hook
# Exit 2 here is the normal hitl "decision: block" continue-the-loop signal
# (unfinished tasks) — unrelated to the Recovery Pointer warning; the warning
# must not introduce any additional/different blocking behavior on top of it.
assert_exit_code "no-match plan: hook exits normally (2 = hitl continue, not a new block)" "$HOOK_EC" 2
assert_contains "no-match plan: warns Recovery Pointer was not updated" "$HOOK_OUTPUT" "no matching label found"
assert_contains "no-match plan: names Current Task as an unmatched field" "$HOOK_OUTPUT" "Current Task"
AFTER_POINTER=$(cat "$TEST_DIR/nazgul/plan.md")
assert_eq "no-match plan: file bytes unchanged (true no-op, correctly warned)" \
  "$AFTER_POINTER" "$BEFORE_POINTER"
teardown_temp_dir

# --- Test 15d: Recovery Pointer warns on a PARTIAL match (WD-04 / PR#66 review) ---
# A plan.md with SOME recognized labels (Current Task, Last Action) but MISSING
# others (Next Action, Last Checkpoint, Last Commit) must (a) update the present
# fields, and (b) still warn — naming the missing fields — instead of staying
# silent because at least one field matched. This is the partial-rewrite gap the
# old all-or-nothing `matched == 0` check missed.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 0'
cat > "$TEST_DIR/nazgul/plan.md" << 'PARTIAL_PLAN_EOF'
# Nazgul Plan

## Objective
Test objective

## Status Summary
- Total tasks: 1
- DONE: 0 | READY: 0 | IN_PROGRESS: 1

## Recovery Pointer
- **Current Task:** stale-value
- **Last Action:** stale-value

## Tasks
PARTIAL_PLAN_EOF
create_task_file "TASK-004" "IN_PROGRESS"
run_hook
assert_exit_code "partial plan: hook exits normally (2 = hitl continue)" "$HOOK_EC" 2
# Present fields were updated (Current Task no longer 'stale-value')
AFTER_PARTIAL=$(cat "$TEST_DIR/nazgul/plan.md")
assert_not_contains "partial plan: present Current Task field was updated" "$AFTER_PARTIAL" "Current Task:** stale-value"
# Warning fires naming a MISSING field, even though some fields matched
assert_contains "partial plan: warns despite a partial match" "$HOOK_OUTPUT" "no matching label found"
assert_contains "partial plan: names Last Commit as an unmatched field" "$HOOK_OUTPUT" "Last Commit"
# And does NOT name a field that WAS matched
assert_not_contains "partial plan: does not name the matched Current Task" "$HOOK_OUTPUT" "for:; Current Task"
teardown_temp_dir

# --- Test 16: Promote PLANNED -> READY (no deps) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "PLANNED" "none"
run_hook
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "PLANNED promoted to READY (no deps)" "$status" "READY"
teardown_temp_dir

# --- Test 17: Promote PLANNED -> READY (deps met) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "PLANNED" "TASK-001"
run_hook
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")
assert_eq "PLANNED promoted to READY (deps met)" "$status" "READY"
teardown_temp_dir

# --- Test 18: No promote when deps unmet ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "READY"
create_task_file "TASK-002" "PLANNED" "TASK-001"
run_hook
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")
assert_eq "PLANNED stays PLANNED (deps unmet)" "$status" "PLANNED"
teardown_temp_dir

# --- Test 19: Checkpoint rotation (keep last 2) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 12'
create_plan
create_task_file "TASK-001" "READY"
# Pre-create 12 checkpoint files
for i in $(seq 1 12); do
  printf '{"iteration": %d}\n' "$i" > "$TEST_DIR/nazgul/checkpoints/iteration-$(printf '%03d' "$i").json"
done
run_hook
# Now should have iteration-013.json + some survivors from rotation (keeps 2)
cp_count=$(ls -1 "$TEST_DIR/nazgul/checkpoints/iteration-"*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$cp_count" -le 2 ]; then
  _pass "checkpoint rotation keeps <= 2"
else
  _fail "checkpoint rotation keeps <= 2" "found $cp_count checkpoints"
fi
teardown_temp_dir

# --- Test 20: (removed — notification system removed) ---

# --- Test 21: Git conflict blocks task ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
# Create a merge conflict
git -C "$TEST_DIR" checkout -q -b conflict-branch
echo "conflict line A" > "$TEST_DIR/conflict.txt"
git -C "$TEST_DIR" add conflict.txt
git -C "$TEST_DIR" commit -q -m "branch A"
git -C "$TEST_DIR" checkout -q main 2>/dev/null || git -C "$TEST_DIR" checkout -q master
echo "conflict line B" > "$TEST_DIR/conflict.txt"
git -C "$TEST_DIR" add conflict.txt
git -C "$TEST_DIR" commit -q -m "branch B"
git -C "$TEST_DIR" merge conflict-branch --no-commit 2>/dev/null || true
# Now we should have unmerged files
porcelain=$(git -C "$TEST_DIR" status --porcelain 2>/dev/null || echo "")
if echo "$porcelain" | grep -qE '^(U.|.U|AA|DD) '; then
  run_hook
  status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
  assert_eq "git conflict blocks task" "$status" "BLOCKED"
  assert_file_contains "blocked event emitted on git conflict" \
    "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"blocked"'
  assert_file_contains "blocked event names task" \
    "$TEST_DIR/nazgul/logs/events.jsonl" '"task_id":"TASK-001"'
  # PR #86 suppressed finding: the reason used to be written only when a `Blocked
  # reason` line already existed, so this task landed a kind with no reason.
  conflict_field() { # <label>
    grep -m1 "^- \*\*$1\*\*:" "$TEST_DIR/nazgul/tasks/TASK-001.md" \
      | sed 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//'
  }
  assert_eq "git conflict quarantine is typed by kind" \
    "$(conflict_field 'Blocked kind')" "git-conflict"
  assert_eq "git conflict quarantine carries a reason, not just a kind" \
    "$(conflict_field 'Blocked reason')" "git conflict — unmerged files detected"
else
  _skip "git conflict blocks task (skipped — no conflict produced)"
  _skip "blocked event emitted on git conflict (skipped — no conflict produced)"
  _skip "blocked event names task (skipped — no conflict produced)"
  _skip "git conflict quarantine is typed by kind (skipped — no conflict produced)"
  _skip "git conflict quarantine carries a reason, not just a kind (skipped — no conflict produced)"
fi
teardown_temp_dir

# --- Test 21b (TASK-023): a failed ledger write must not abort the block half-applied —
# BLOCKED is written first, so aborting left a quarantine with no kind, reason or event ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
# A directory where the ledger file belongs: ttg_log_transition refuses a non-regular
# ledger and returns 1, the same rc a lock timeout produces.
mkdir "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
git -C "$TEST_DIR" checkout -q -b conflict-branch
echo "conflict line A" > "$TEST_DIR/conflict.txt"
git -C "$TEST_DIR" add conflict.txt
git -C "$TEST_DIR" commit -q -m "branch A"
git -C "$TEST_DIR" checkout -q main 2>/dev/null || git -C "$TEST_DIR" checkout -q master
echo "conflict line B" > "$TEST_DIR/conflict.txt"
git -C "$TEST_DIR" add conflict.txt
git -C "$TEST_DIR" commit -q -m "branch B"
git -C "$TEST_DIR" merge conflict-branch --no-commit 2>/dev/null || true
porcelain=$(git -C "$TEST_DIR" status --porcelain 2>/dev/null || echo "")
if echo "$porcelain" | grep -qE '^(U.|.U|AA|DD) '; then
  ledger_field() { # <label>
    grep -m1 "^- \*\*$1\*\*:" "$TEST_DIR/nazgul/tasks/TASK-001.md" \
      | sed 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*$//'
  }
  run_hook
  assert_contains "TASK-023: the ledger write really did fail (fixture is live)" \
    "$HOOK_OUTPUT" "ledger is not a regular non-symlink file"
  assert_eq "TASK-023: a failed ledger write still leaves BLOCKED" \
    "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
  assert_eq "TASK-023: the quarantine is still typed by kind" \
    "$(ledger_field 'Blocked kind')" "git-conflict"
  assert_eq "TASK-023: the quarantine still carries its reason" \
    "$(ledger_field 'Blocked reason')" "git conflict — unmerged files detected"
  assert_file_contains "TASK-023: the blocked event still fires" \
    "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"blocked"'
else
  _skip "TASK-023: the ledger write really did fail (skipped — no conflict produced)"
  _skip "TASK-023: a failed ledger write still leaves BLOCKED (skipped — no conflict produced)"
  _skip "TASK-023: the quarantine is still typed by kind (skipped — no conflict produced)"
  _skip "TASK-023: the quarantine still carries its reason (skipped — no conflict produced)"
  _skip "TASK-023: the blocked event still fires (skipped — no conflict produced)"
fi
teardown_temp_dir

# --- Test 22: Checkpoint is valid JSON ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 0'
create_plan
create_task_file "TASK-001" "READY"
run_hook
if jq empty "$TEST_DIR/nazgul/checkpoints/iteration-001.json" 2>/dev/null; then
  _pass "checkpoint is valid JSON"
else
  _fail "checkpoint is valid JSON"
fi
teardown_temp_dir

# --- Test 23: Review gate enforcement — DONE without reviews reset to IMPLEMENTED ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "DONE"
# Intentionally NO create_review_dir — simulate the violation
create_task_file "TASK-002" "READY"
run_hook
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "review gate violation resets DONE to IMPLEMENTED" "$status" "IMPLEMENTED"
assert_contains "review gate violation logged" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
teardown_temp_dir

# --- Test 24: Review gate — DONE with reviews stays DONE ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "DONE with reviews stays DONE" "$status" "DONE"
teardown_temp_dir

# Merge-closed DONE vs the REACTIVE gate (FEAT-031, ADR-023): a host-corroborated
# closure survives this pass, and a forged block with the SAME host answer does not.
MC_BIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-stop-gh-XXXXXX")
cat > "$MC_BIN/gh" << 'MC_GH_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  auth) exit 0 ;;
  pr)
    [ "${2:-}" = "view" ] || exit 1
    printf '{"baseRefName":"main","headRefName":"%s","mergeCommit":{"oid":"%s"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED","url":"https://github.com/OrodruinLabs/nazgul/pull/91"}\n' \
      "${NAZGUL_TEST_MERGE_BRANCH:-}" "${NAZGUL_TEST_MERGE_SHA:-}"
    exit 0 ;;
esac
exit 1
MC_GH_EOF
chmod +x "$MC_BIN/gh"

# Usage: mc_evidence <task-id> <recorded-by value, empty for the forged block>
mc_evidence() {
  local mf="$TEST_DIR/nazgul/tasks/${1}.md"
  {
    printf '\n## Merge Evidence\n'
    printf -- '- **host**: github.com\n'
    printf -- '- **pr**: 91\n'
    printf -- '- **merged-at**: 2026-08-14T23:16:50Z\n'
    printf -- '- **merge-commit**: %s\n' "$NAZGUL_TEST_MERGE_SHA"
    printf -- '- **head-ref**: %s\n' "$NAZGUL_TEST_MERGE_BRANCH"
    [ -z "$2" ] || printf -- '- **recorded-by**: %s\n' "$2"
  } >> "$mf"
}

mc_setup() {
  setup_temp_dir
  setup_git_repo
  setup_nazgul_dir
  git -C "$TEST_DIR" remote add origin "https://github.com/OrodruinLabs/nazgul.git"
  MC_BASE=$(git -C "$TEST_DIR" rev-parse --abbrev-ref HEAD)
  NAZGUL_TEST_MERGE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
  export NAZGUL_TEST_MERGE_SHA
  NAZGUL_TEST_MERGE_BRANCH="feat/FEAT-031-merge-closed"
  export NAZGUL_TEST_MERGE_BRANCH
  create_config '.agents.reviewers = ["code-reviewer"]' \
    ".branch.base = \"${MC_BASE}\"" '.review_gate.require_provenance = false' \
    '.feat_id = "FEAT-031"' ".branch.feature = \"${NAZGUL_TEST_MERGE_BRANCH}\"" "$@"
  create_plan
  # The merge route binds manifest->objective through plan.md, which create_plan writes
  # neither half of; a fixture missing them tests the refusal, not the closure.
  { printf -- '---\nfeat_id: FEAT-031\n---\n'; cat "$TEST_DIR/nazgul/plan.md"; printf -- '- TASK-001\n- TASK-002\n'; } \
    > "$TEST_DIR/nazgul/plan.md.new" && mv "$TEST_DIR/nazgul/plan.md.new" "$TEST_DIR/nazgul/plan.md"
  create_task_file "TASK-001" "DONE"    # deliberately NO review dir — merge route only
  create_task_file "TASK-002" "READY"   # keeps the loop alive (exit 2 path)
}

mc_setup
mc_evidence TASK-001 "scripts/close-objective.sh (host API, ok)"
HOOK_OUTPUT=$(PATH="$MC_BIN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "merge-closed DONE is NOT reverted by the reactive gate" "$status" "DONE"
assert_not_contains "merge-closed DONE: no review-gate violation" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_contains "merge-closed DONE: the admitting route is named" \
  "$HOOK_OUTPUT" "admitted via the merge-evidence route"
teardown_temp_dir

mc_setup
mc_evidence TASK-001 ""
HOOK_OUTPUT=$(PATH="$MC_BIN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "a forged merge block does NOT admit DONE — the review route is unweakened" \
  "$status" "IMPLEMENTED"
assert_contains "a forged merge block still logs the review-gate violation" \
  "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
teardown_temp_dir

# TASK-022 — an unreachable host must not REVOKE a closure it was never asked to admit:
# `unverifiable` is an absence of information, which may not move a status in EITHER direction.
MC_BIN_DOWN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-stop-gh-down-XXXXXX")
cat > "$MC_BIN_DOWN/gh" << 'MC_GH_DOWN_EOF'
#!/usr/bin/env bash
# Installed but unauthenticated, so `gh auth status` fails and the github arm reports
# provider_unavailable — the merge verdict is `unverifiable`, never `not_merged`.
exit 1
MC_GH_DOWN_EOF
chmod +x "$MC_BIN_DOWN/gh"

mc_setup
mc_evidence TASK-001 "scripts/close-objective.sh (host API, ok)"
HOOK_OUTPUT=$(PATH="$MC_BIN_DOWN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "TASK-022: an unverifiable host does NOT demote a merge-closed DONE" "$status" "DONE"
assert_not_contains "TASK-022: a deferral is not a review-gate violation" \
  "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_contains "TASK-022: the deferral names its reason" \
  "$HOOK_OUTPUT" "could not be verified this iteration [reason: unverifiable"
assert_contains "TASK-022: the deferral denies the review-evidence reading" \
  "$HOOK_OUTPUT" "NOT a review-evidence violation"
assert_file_contains "TASK-022: an undecided iteration is recorded, not silent" \
  "$TEST_DIR/nazgul/logs/events.jsonl" \
  '"reason":"merge_evidence_undecided","gate":"review_gate_reactive","task_id":"TASK-001"'
assert_file_contains "TASK-022: the deferral event names the host state it could not read" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"host_state":"provider_unavailable"'
assert_file_contains "TASK-022: the deferral event says it declined to act" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"action":"deferred"'
count=$(jq -r 'if (.safety._review_reset_counts | has("TASK-001")) then .safety._review_reset_counts["TASK-001"] else "absent" end' "$TEST_DIR/nazgul/config.json")
assert_eq "TASK-022: a deferral moves no strike counter" "$count" "absent"
# The second consecutive Stop is where the unfixed ladder landed on BLOCKED.
HOOK_OUTPUT=$(PATH="$MC_BIN_DOWN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "TASK-022: a second unverifiable iteration still leaves DONE in place" "$status" "DONE"
assert_not_contains "TASK-022: no escalation on a repeated deferral" \
  "$HOOK_OUTPUT" "escalated to BLOCKED"
teardown_temp_dir

# The boundary: `not_merged` is the host's ANSWER, not its silence, so the review-evidence
# ladder is untouched — widening the deferral to cover it would be the bypass, not the fix.
MC_BIN_OPEN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-stop-gh-open-XXXXXX")
cat > "$MC_BIN_OPEN/gh" << 'MC_GH_OPEN_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  auth) exit 0 ;;
  pr)
    [ "${2:-}" = "view" ] || exit 1
    printf '{"baseRefName":"main","headRefName":"%s","mergeCommit":null,"mergedAt":null,"state":"OPEN","url":"https://github.com/OrodruinLabs/nazgul/pull/91"}\n' \
      "${NAZGUL_TEST_MERGE_BRANCH:-}"
    exit 0 ;;
esac
exit 1
MC_GH_OPEN_EOF
chmod +x "$MC_BIN_OPEN/gh"

mc_setup
mc_evidence TASK-001 "scripts/close-objective.sh (host API, ok)"
HOOK_OUTPUT=$(PATH="$MC_BIN_OPEN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "TASK-022: a host answer of not_merged still resets DONE" "$status" "IMPLEMENTED"
assert_contains "TASK-022: not_merged is still a violation, not a deferral" \
  "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_not_contains "TASK-022: not_merged never reaches the deferral arm" \
  "$HOOK_OUTPUT" "could not be verified this iteration"
count=$(jq -r '.safety._review_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "TASK-022: not_merged records the first strike" "$count" "1"
teardown_temp_dir

mc_setup '.safety._review_reset_counts = {"TASK-001": 1}'
mc_evidence TASK-001 "scripts/close-objective.sh (host API, ok)"
HOOK_OUTPUT=$(PATH="$MC_BIN_OPEN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "TASK-022: a second not_merged iteration still escalates to BLOCKED" "$status" "BLOCKED"
assert_contains "TASK-022: the not_merged escalation is still named" \
  "$HOOK_OUTPUT" "escalated to BLOCKED"
teardown_temp_dir

# TASK-023 — the pre-filter matched the HEADING alone, and templates/task-manifest.md ships
# that heading with its whole block commented out, so EVERY template-born manifest was probed.
mc_setup
create_review_dir TASK-001
{ printf '\n'
  awk '/^## Merge Evidence/{f=1;print;next} f && /^## /{exit} f{print}' \
    "$REPO_ROOT/templates/task-manifest.md"
} >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
assert_file_contains "TASK-023: the fixture really carries the template's heading" \
  "$TEST_DIR/nazgul/tasks/TASK-001.md" "## Merge Evidence"
assert_file_contains "TASK-023: and the commented block beneath it, not an empty section" \
  "$TEST_DIR/nazgul/tasks/TASK-001.md" "\- \*\*host\*\*: example\.invalid"
assert_file_contains "TASK-023: with the comment still closed around it" \
  "$TEST_DIR/nazgul/tasks/TASK-001.md" "(host API, ok) -->"
HOOK_OUTPUT=$(PATH="$MC_BIN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
HOOK_OUTPUT=$(PATH="$MC_BIN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "TASK-023: a review-closed DONE still stands" "$status" "DONE"
me_events=$(grep -c '"event":"merge_evidence_missing"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || true)
assert_eq "TASK-023: the template's commented block is probed ZERO times in two iterations" \
  "${me_events:-0}" "0"
assert_not_contains "TASK-023: the verifier is never consulted for it at all" \
  "$HOOK_OUTPUT" "ttg_verify_merge_evidence:"
teardown_temp_dir

# The other half: an uncommented field line IS a closure attempt, so it still reaches the
# verifier and still refuses with its own token — the gate is unweakened, only the probe moved.
mc_setup
mc_evidence TASK-001 ""
HOOK_OUTPUT=$(PATH="$MC_BIN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
assert_file_contains "TASK-023: a half-written real block still reaches the verifier" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"merge_evidence_missing"'
assert_file_contains "TASK-023: with its refusal token unchanged" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"reason":"truncated"'
assert_contains "TASK-023: and its stderr refusal unchanged" \
  "$HOOK_OUTPUT" "ttg_verify_merge_evidence:"
teardown_temp_dir

# === PR-VIEW BUDGET (PR #240 finding #5) — the pre-filter must be the closure ROUTE, and
# one question about one PR must cost one host call however many manifests ask it ===
CT_BIN=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-stop-gh-count-XXXXXX")
CT_CALLS="$CT_BIN/pr-view.calls"
cat > "$CT_BIN/gh" << 'CT_GH_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  auth) exit 0 ;;
  pr)
    [ "${2:-}" = "view" ] || exit 1
    printf 'pr-view\n' >> "${NAZGUL_TEST_GH_CALLS:-/dev/null}"
    printf '{"baseRefName":"main","headRefName":"%s","mergeCommit":{"oid":"%s"},"mergedAt":"2026-08-14T23:16:50Z","state":"MERGED","url":"https://github.com/OrodruinLabs/nazgul/pull/91"}\n' \
      "${NAZGUL_TEST_MERGE_BRANCH:-}" "${NAZGUL_TEST_MERGE_SHA:-}"
    exit 0 ;;
esac
exit 1
CT_GH_EOF
chmod +x "$CT_BIN/gh"

# Usage: ct_setup <n DONE tasks, all closed against pr 91> <give them review dirs: true|false>
ct_setup() {
  local n="$1" reviews="$2" i id roster=""
  setup_temp_dir; setup_git_repo; setup_nazgul_dir
  git -C "$TEST_DIR" remote add origin "https://github.com/OrodruinLabs/nazgul.git"
  CT_BASE=$(git -C "$TEST_DIR" rev-parse --abbrev-ref HEAD)
  NAZGUL_TEST_MERGE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD); export NAZGUL_TEST_MERGE_SHA
  NAZGUL_TEST_MERGE_BRANCH="feat/FEAT-031-merge-closed"; export NAZGUL_TEST_MERGE_BRANCH
  create_config '.agents.reviewers = ["code-reviewer"]' \
    ".branch.base = \"${CT_BASE}\"" '.review_gate.require_provenance = false' \
    '.feat_id = "FEAT-031"' ".branch.feature = \"${NAZGUL_TEST_MERGE_BRANCH}\"" \
    '.learning.auto_distill_post_loop = false' '.docs.verify_comments = false' \
    '.self_audit.enabled = false'
  create_plan
  for i in $(seq 1 "$n"); do
    id=$(printf 'TASK-%03d' "$i")
    create_task_file "$id" "DONE"
    mc_evidence "$id" "scripts/close-objective.sh (host API, ok)"
    if [ "$reviews" = "true" ]; then create_review_dir "$id"; fi
    roster="${roster}- ${id}"$'\n'
  done
  id=$(printf 'TASK-%03d' "$((n + 1))")
  create_task_file "$id" "READY"
  roster="${roster}- ${id}"$'\n'
  { printf -- '---\nfeat_id: FEAT-031\n---\n'; cat "$TEST_DIR/nazgul/plan.md"; printf '%s' "$roster"; } \
    > "$TEST_DIR/nazgul/plan.md.new" && mv "$TEST_DIR/nazgul/plan.md.new" "$TEST_DIR/nazgul/plan.md"
  : > "$CT_CALLS"
}

# The workflow the feature exists to enable: /nazgul:complete writes ## Merge Evidence into
# EVERY task it closes, so a section-presence pre-filter probed all 21 on every iteration.
ct_setup 21 true
HOOK_OUTPUT=$(PATH="$CT_BIN:$PATH" NAZGUL_TEST_GH_CALLS="$CT_CALLS" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
ct_calls=$(wc -l < "$CT_CALLS" | tr -d ' ')
assert_eq "#5: 21 review-closed DONE tasks cost ZERO host calls" "${ct_calls:-0}" "0"
assert_eq "#5: and the review route still holds every one of them at DONE" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-021.md")" "DONE"
assert_not_contains "#5: the merge route is not the ACCEPTED route when review evidence is clean" \
  "$HOOK_OUTPUT" "admitted via the merge-evidence route"
teardown_temp_dir

# The other half: when the host genuinely has to be asked, N manifests share ONE pr and
# therefore ONE round trip — while each still gets its own independently computed verdict.
ct_setup 21 false
HOOK_OUTPUT=$(PATH="$CT_BIN:$PATH" NAZGUL_TEST_GH_CALLS="$CT_CALLS" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
ct_calls=$(wc -l < "$CT_CALLS" | tr -d ' ')
assert_eq "#5: 21 manifests sharing one pr cost exactly ONE host call" "${ct_calls:-0}" "1"
assert_eq "#5: the memo does not weaken the verdict — the merge route still admits" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-021.md")" "DONE"
ct_routes=$(printf '%s\n' "$HOOK_OUTPUT" | grep -c 'admitted via the merge-evidence route' || true)
assert_eq "#5: and all 21 still record WHICH route admitted them (memo is per-ANSWER, not per-verdict)" \
  "${ct_routes:-0}" "21"
teardown_temp_dir

# === DEFERRAL CEILING (PR #240 finding #6) — the REVOKE-side deferral is a kill switch on the
# same edge whose ADMIT side deliberately has none, and its trigger is manifest text ===
MC_BIN_404=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-stop-gh-404-XXXXXX")
cat > "$MC_BIN_404/gh" << 'MC_GH_404_EOF'
#!/usr/bin/env bash
# Authenticated and reachable; the PR number simply names nothing, which is what
# `gh pr view 999999999` does on a live repo — api_failure, reported as `unverifiable`.
case "${1:-}" in
  auth) exit 0 ;;
esac
exit 1
MC_GH_404_EOF
chmod +x "$MC_BIN_404/gh"

# A ceiling an operator could raise is the switch under another name, so these two config keys
# are decoys: neither exists, and the fall-through must land on the 4th iteration regardless.
mc_setup '.review_gate.merge_undecided_max = 99' '.safety.merge_defer_max = 99'
mc_evidence TASK-001 "scripts/close-objective.sh (host API, ok)"
sed -i.bak 's/^- \*\*pr\*\*: 91$/- **pr**: 999999999/' "$TEST_DIR/nazgul/tasks/TASK-001.md" \
  && rm -f "$TEST_DIR/nazgul/tasks/TASK-001.md.bak"
for defer_iter in 1 2 3; do
  HOOK_OUTPUT=$(PATH="$MC_BIN_404:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
  assert_eq "#6: iteration ${defer_iter} is inside the bound — DONE stands" \
    "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "DONE"
  assert_contains "#6: iteration ${defer_iter} names where it stands against the ceiling" \
    "$HOOK_OUTPUT" "(deferral ${defer_iter} of 3)"
  assert_eq "#6: iteration ${defer_iter} records NO review-evidence strike" \
    "$(jq -r 'if (.safety._review_reset_counts | has("TASK-001")) then "present" else "absent" end' "$TEST_DIR/nazgul/config.json")" \
    "absent"
  assert_eq "#6: the deferral is counted on its OWN key" \
    "$(jq -r '.safety._merge_undecided_counts["TASK-001"] // "absent"' "$TEST_DIR/nazgul/config.json")" \
    "$defer_iter"
done
HOOK_OUTPUT=$(PATH="$MC_BIN_404:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
assert_contains "#6: the 4th consecutive unverifiable iteration ENDS the deferral" \
  "$HOOK_OUTPUT" "merge-evidence deferral EXHAUSTED"
assert_contains "#6: and the exhaustion names the ceiling it reached" \
  "$HOOK_OUTPUT" "reached the limit of 3"
assert_file_contains "#6: 'deferred' and 'deferral exhausted' are distinguishable in telemetry" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"action":"deferral_exhausted"'
assert_file_contains "#6: the exhaustion event carries the count and the limit" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"deferrals":3,"limit":3'
assert_eq "#6: the suppressed ladder finally runs — the strike is recorded" \
  "$(jq -r '.safety._review_reset_counts["TASK-001"] // "absent"' "$TEST_DIR/nazgul/config.json")" "1"
assert_eq "#6: a DONE with no review evidence behind it can no longer be held DONE forever" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "IMPLEMENTED"
teardown_temp_dir

# The direction TASK-022 fixed, unweakened: an unreachable host inside the bound revokes
# nothing, and a host that comes back ENDS the run of consecutive deferrals.
mc_setup
mc_evidence TASK-001 "scripts/close-objective.sh (host API, ok)"
HOOK_OUTPUT=$(PATH="$MC_BIN_DOWN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
assert_eq "#6: one transient outage still moves no status" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "DONE"
assert_eq "#6: one transient outage still records no strike" \
  "$(jq -r 'if (.safety._review_reset_counts | has("TASK-001")) then "present" else "absent" end' "$TEST_DIR/nazgul/config.json")" \
  "absent"
assert_eq "#6: one transient outage costs exactly one deferral" \
  "$(jq -r '.safety._merge_undecided_counts["TASK-001"] // "absent"' "$TEST_DIR/nazgul/config.json")" "1"
HOOK_OUTPUT=$(PATH="$MC_BIN:$PATH" bash "$STOP_HOOK" </dev/null 2>&1) && HOOK_EC=0 || HOOK_EC=$?
assert_eq "#6: the host comes back and the closure is admitted" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "DONE"
assert_eq "#6: 'consecutive' really is consecutive — the counter is cleared" \
  "$(jq -r 'if (.safety._merge_undecided_counts | has("TASK-001")) then "present" else "absent" end' "$TEST_DIR/nazgul/config.json")" \
  "absent"
teardown_temp_dir

rm -rf "$CT_BIN" "$MC_BIN_404"

rm -rf "$MC_BIN" "$MC_BIN_DOWN" "$MC_BIN_OPEN"
unset NAZGUL_TEST_MERGE_SHA NAZGUL_TEST_MERGE_BRANCH

# --- Test: YOLO without task-pr — all APPROVED exits cleanly (MF-005 regression) ---
# Canonical-frontmatter fixtures (create_task_file). Proves the MF-001 fix (TASK-002,
# APPROVED added to VALID_STATUSES) and the MF-009 counting repoint (TASK-003/004) land
# together: APPROVED_COUNT + DONE_COUNT == TOTAL_COUNT drives completion on the real
# frontmatter path, and the transition registers as progress (consecutive_failures resets).
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.afk.yolo = true' '.afk.task_pr = false' '.current_iteration = 1' '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' '.self_audit.enabled = false' \
  '.safety.consecutive_failures = 3' '.safety._prev_done_count = 0'
create_plan
create_task_file "TASK-001" "APPROVED"
create_task_file "TASK-002" "APPROVED"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_exit_code "MF-005: YOLO no task-pr, all APPROVED exits 0 (canonical frontmatter)" "$HOOK_EC" 0
consec=$(jq -r '.safety.consecutive_failures' "$TEST_DIR/nazgul/config.json")
assert_eq "MF-005: all-APPROVED completion counts as progress (failures reset to 0)" "$consec" "0"
teardown_temp_dir

# --- Test: MF-004 — YOLO promotes PLANNED -> READY when dependency is APPROVED ---
# The dep-promotion gate (stop-hook.sh's auto-promote block) must accept APPROVED, not
# just DONE, as a satisfied dependency in YOLO mode. Canonical-frontmatter fixtures.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.afk.yolo = true'
create_plan
create_task_file "TASK-001" "APPROVED"
create_task_file "TASK-002" "PLANNED" "TASK-001"
run_hook
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")
assert_eq "MF-004: PLANNED promoted to READY when dep is APPROVED (YOLO)" "$status" "READY"
teardown_temp_dir

# --- Reset diagnostics: first violation names missing reviewers in output ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer", "qa-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"   # writes code-reviewer.md only — qa-reviewer missing
create_task_file "TASK-002" "READY"   # keeps the loop alive (exit 2 path)
run_hook
assert_exit_code "first violation: exit 2" "$HOOK_EC" 2
assert_contains "violation logged" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_contains "missing reviewer named" "$HOOK_OUTPUT" "qa-reviewer"
assert_contains "remediation named" "$HOOK_OUTPUT" "materialize"
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "first violation: reset to IMPLEMENTED" "$status" "IMPLEMENTED"
count=$(jq -r '.safety._review_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "first violation: reset count recorded" "$count" "1"
teardown_temp_dir

# --- Escalation: second violation sets BLOCKED with remediation reason ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer", "qa-reviewer"]' '.safety._review_reset_counts = {"TASK-001": 1}'
create_plan
create_task_file "TASK-001" "DONE" "none" "stale reason"   # pre-seeded Blocked reason exercises the awk update branch
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
assert_exit_code "second violation: exit 2" "$HOOK_EC" 2
assert_contains "escalation logged" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_contains "escalation names BLOCKED" "$HOOK_OUTPUT" "escalated to BLOCKED"
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "second violation: escalated to BLOCKED" "$status" "BLOCKED"
assert_contains "blocked reason written" "$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")" "review evidence missing"
assert_contains "blocked reason names command" "$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")" "/nazgul:review --materialize TASK-001"
count=$(jq -r '.safety._review_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "second violation: count cleared" "$count" "0"
teardown_temp_dir

# --- Valid evidence clears a stale reset count ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.safety._review_reset_counts = {"TASK-001": 1}'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"   # code-reviewer.md APPROVED — roster satisfied
create_task_file "TASK-002" "READY"
run_hook
assert_exit_code "valid evidence: exit 2" "$HOOK_EC" 2
assert_not_contains "valid evidence: no violation noise" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "valid evidence: stays DONE" "$status" "DONE"
count=$(jq -r '.safety._review_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "valid evidence: stale count cleared" "$count" "0"
teardown_temp_dir

# --- Reset count survives the repair path (IMPLEMENTED/IN_REVIEW) ---
# After a first-violation reset the task sits at IMPLEMENTED; the counter must
# NOT clear there, or a later bad DONE restarts at zero and never escalates.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer", "qa-reviewer"]' '.safety._review_reset_counts = {"TASK-001": 1, "TASK-003": 1}'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"   # repair path — counter must survive
create_task_file "TASK-003" "READY"         # left the repair path — counter clears
run_hook
count=$(jq -r '.safety._review_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "repair path: count survives IMPLEMENTED" "$count" "1"
count=$(jq -r '.safety._review_reset_counts["TASK-003"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "non-repair status: count cleared" "$count" "0"
teardown_temp_dir

# --- Budget governor ---
# Over ceiling → stop (exit 0) even though work remains
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode="afk"' '.budget.enabled=true' '.budget.max_usd=1' '.budget.spent_usd=0.9' '.budget.per_iteration_usd=0.5'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>"$TEST_DIR/err" || rc=$?
assert_exit_code "budget over ceiling → allow stop" "$rc" 0
assert_file_contains "budget stop message" "$TEST_DIR/err" "budget reached"
teardown_temp_dir

# Under ceiling → continue (exit 2) and accumulate spent_usd by per_iteration_usd
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode="afk"' '.budget.enabled=true' '.budget.max_usd=100' '.budget.spent_usd=0' '.budget.per_iteration_usd=0.5'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>/dev/null || rc=$?
assert_exit_code "budget under ceiling → continue" "$rc" 2
assert_eq "budget accumulates one iteration" "$(jq -r '.budget.spent_usd' "$TEST_DIR/nazgul/config.json")" "0.5"
teardown_temp_dir

# Disabled → no effect (continue), spent_usd untouched
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode="afk"' '.budget.enabled=false' '.budget.max_usd=1' '.budget.spent_usd=0.9'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>/dev/null || rc=$?
assert_exit_code "budget disabled → continue" "$rc" 2
assert_json_field "budget disabled → spent untouched" "$TEST_DIR/nazgul/config.json" ".budget.spent_usd" "0.9"
teardown_temp_dir

# Malformed (non-numeric) per_iteration_usd → coerces to default 0.30, never aborts mid-iteration
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode="afk"' '.budget.enabled=true' '.budget.max_usd=100' '.budget.spent_usd=0' '.budget.per_iteration_usd="cheap"'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>/dev/null || rc=$?
assert_exit_code "malformed per_iteration_usd → continue (no abort)" "$rc" 2
assert_eq "malformed per_iteration_usd → defaults to 0.30" "$(jq -r '.budget.spent_usd' "$TEST_DIR/nazgul/config.json")" "0.3"
teardown_temp_dir

# Malformed (non-numeric) max_usd → treated as no ceiling (inert), loop continues — must NOT fail closed
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode="afk"' '.budget.enabled=true' '.budget.max_usd="abc"' '.budget.spent_usd=0.9' '.budget.per_iteration_usd=0.5'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>/dev/null || rc=$?
assert_exit_code "malformed max_usd → continue (no fail-closed)" "$rc" 2
teardown_temp_dir

# Malformed spent_usd with budget DISABLED → checkpoint must not abort the hook
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode="afk"' '.budget.enabled=false' '.budget.spent_usd="garbage"'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>/dev/null || rc=$?
assert_exit_code "malformed spent_usd (disabled) → continue (no abort)" "$rc" 2
teardown_temp_dir

# Budget threshold: 50% crossing emits budget_threshold event with pct:50
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.budget.enabled=true' '.budget.max_usd=100' '.budget.spent_usd=49' '.budget.per_iteration_usd=2'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>/dev/null || rc=$?
assert_file_contains "50% budget_threshold emitted" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"budget_threshold"'
assert_file_contains "50% pct field correct" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"pct":50'
teardown_temp_dir

# Budget threshold: 90% crossing emits budget_threshold event with pct:90
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.budget.enabled=true' '.budget.max_usd=100' '.budget.spent_usd=89' '.budget.per_iteration_usd=2'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>/dev/null || rc=$?
assert_file_contains "90% budget_threshold emitted" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"budget_threshold"'
assert_file_contains "90% pct field correct" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"pct":90'
teardown_temp_dir

# Budget dedup: pre-seeded _budget_threshold_50_emitted suppresses 50% re-emit; 90% fires once
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.budget.enabled=true' '.budget.max_usd=100' '.budget.spent_usd=89' \
  '.budget.per_iteration_usd=2' '._budget_threshold_50_emitted="true"'
create_task_file TASK-001 READY
rc=0; echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" "$REPO_ROOT/scripts/stop-hook.sh" >/dev/null 2>/dev/null || rc=$?
count=$(grep -c '"event":"budget_threshold"' "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null || echo 0)
assert_eq "budget dedup: only one threshold emit" "$count" "1"
teardown_temp_dir

# AFK clock uses objective_set_at as PRIMARY (recent objective_set_at → no timeout even with an OLD checkpoint)
setup_temp_dir; setup_git_repo; setup_nazgul_dir
recent_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
old_ts=$(date -u -v-5H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "5 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$old_ts" ]; then
  create_config ".afk.enabled = true" ".afk.timeout_minutes = 90" ".objective_set_at = \"$recent_ts\""
  create_plan; create_task_file "TASK-001" "READY"
  printf '{"iteration":1,"timestamp":"%s"}\n' "$old_ts" > "$TEST_DIR/nazgul/checkpoints/iteration-001.json"
  run_hook
  assert_exit_code "AFK: recent objective_set_at overrides old checkpoint → continue" "$HOOK_EC" 2
else
  _skip "AFK objective_set_at precedence (skipped — date format unavailable)"
fi
teardown_temp_dir

# AFK clock falls back to oldest checkpoint when objective_set_at absent —
# parameterised over TZ (see Test 6 above for why).
old_ts=$(date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "3 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
for tz in UTC "Europe/Lisbon" "America/New_York"; do
  setup_temp_dir; setup_git_repo; setup_nazgul_dir
  if [ -n "$old_ts" ]; then
    create_config ".afk.enabled = true" ".afk.timeout_minutes = 90"
    jq 'del(.objective_set_at)' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
    create_plan; create_task_file "TASK-001" "READY"
    printf '{"iteration":1,"timestamp":"%s"}\n' "$old_ts" > "$TEST_DIR/nazgul/checkpoints/iteration-001.json"
    export TZ="$tz"
    run_hook
    unset TZ
    assert_exit_code "TZ=$tz AFK: falls back to old checkpoint when objective_set_at absent → stop" "$HOOK_EC" 0
    assert_contains "TZ=$tz AFK fallback stderr" "$HOOK_OUTPUT" "AFK timeout"
  else
    _skip "TZ=$tz AFK checkpoint fallback (skipped — date format unavailable)"
    _skip "TZ=$tz AFK fallback stderr (skipped)"
  fi
  teardown_temp_dir
done

# AFK clock falls back to durable iterations.jsonl when objective_set_at absent
# (decoupled from pruning: fires even with no/recent checkpoints — covers migrated
# configs where migrate_4_to_5 deleted objective_set_at). Parameterised over TZ.
old_ts=$(date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "3 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
for tz in UTC "Europe/Lisbon" "America/New_York"; do
  setup_temp_dir; setup_git_repo; setup_nazgul_dir
  if [ -n "$old_ts" ]; then
    create_config ".afk.enabled = true" ".afk.timeout_minutes = 90"
    jq 'del(.objective_set_at)' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
    create_plan; create_task_file "TASK-001" "READY"
    mkdir -p "$TEST_DIR/nazgul/logs"
    printf '{"iteration":1,"timestamp":"%s"}\n' "$old_ts" > "$TEST_DIR/nazgul/logs/iterations.jsonl"
    export TZ="$tz"
    run_hook
    unset TZ
    assert_exit_code "TZ=$tz AFK: durable iterations.jsonl fallback fires → stop" "$HOOK_EC" 0
    assert_contains "TZ=$tz AFK durable-log fallback stderr" "$HOOK_OUTPUT" "AFK timeout"
  else
    _skip "TZ=$tz AFK durable-log fallback (skipped — date format unavailable)"
    _skip "TZ=$tz AFK durable-log fallback stderr (skipped)"
  fi
  teardown_temp_dir
done

# === REVIEW GRANULARITY (review_gate.granularity) ===

# --- Granularity task (explicit): IMPLEMENTED task dispatches per-task review ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "task"'   # explicit task (v17 default is group)
create_plan
create_task_file "TASK-001" "IMPLEMENTED"
create_task_file_with_commits "TASK-001" "IMPLEMENTED" "abc1234"
run_hook
assert_exit_code "task granularity: exit 2" "$HOOK_EC" 2
assert_contains "task granularity: per-task review-gate dispatch" "$HOOK_OUTPUT" "Spawn review-gate agent (nazgul:review-gate) for TASK-001"
assert_contains "task granularity: shown in banner" "$HOOK_OUTPUT" "Review granularity: task"
# WS2 (LR-002 DELEGATE-text half): the per-task DELEGATE line restates the
# models.review_orchestrator tier as defense-in-depth for the Agent-Teams
# dispatch path, where a static frontmatter model: pin may not apply the
# same way a Task-tool model= parameter does.
assert_contains "task granularity: DELEGATE restates review_orchestrator tier" "$HOOK_OUTPUT" "models.review_orchestrator (default sonnet) — never inherit a lower tier from the calling context"
teardown_temp_dir

# --- Granularity group, unit INCOMPLETE: park IMPLEMENTED, keep implementing ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"; set_task_group "TASK-001" 1
create_task_file "TASK-002" "READY";       set_task_group "TASK-002" 1
run_hook
assert_exit_code "group granularity (incomplete): exit 2" "$HOOK_EC" 2
assert_contains "group incomplete: awaiting aggregate review marker" "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
assert_contains "group incomplete: parked task surfaced" "$HOOK_OUTPUT" "TASK-001"
assert_contains "group incomplete: keep implementing next task" "$HOOK_OUTPUT" "Spawn implementer agent (nazgul:implementer) for TASK-002"
assert_not_contains "group incomplete: NO per-task review dispatched" "$HOOK_OUTPUT" "Spawn review-gate agent (nazgul:review-gate) for TASK-001"
teardown_temp_dir

# --- Granularity group, unit COMPLETE: dispatch ONE aggregate review ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"; set_task_group "TASK-001" 1
create_task_file "TASK-002" "IMPLEMENTED"; set_task_group "TASK-002" 1
run_hook
assert_exit_code "group granularity (complete): exit 2" "$HOOK_EC" 2
assert_contains "group complete: aggregate review ready" "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
assert_contains "group complete: review unit scope group 1" "$HOOK_OUTPUT" "group 1"
assert_contains "group complete: aggregate review-gate dispatched" "$HOOK_OUTPUT" "AGGREGATE review unit"
assert_contains "group complete: covers both tasks" "$HOOK_OUTPUT" "TASK-001"
assert_contains "group complete: covers both tasks (002)" "$HOOK_OUTPUT" "TASK-002"
# WS2 (LR-002 DELEGATE-text half): the aggregate-review-variant DELEGATE line
# restates the same models.review_orchestrator tier requirement.
assert_contains "group complete: DELEGATE restates review_orchestrator tier" "$HOOK_OUTPUT" "models.review_orchestrator (default sonnet) — never inherit a lower tier from the calling context"
teardown_temp_dir

# --- Granularity group, ORDERING: earlier group done, review the next group only ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
# Configure a reviewer so the DONE task's review evidence validates (otherwise the
# Layer-2 enforcement net would reset DONE → IMPLEMENTED and skew the scenario).
create_config '.review_gate.granularity = "group"' '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE";        set_task_group "TASK-001" 1
create_review_dir "GROUP-1"   # MF-013: TASK-001 Group:1, granularity=group -> evidence lives at reviews/GROUP-1
create_task_file "TASK-002" "IMPLEMENTED";  set_task_group "TASK-002" 2
create_task_file "TASK-003" "IMPLEMENTED";  set_task_group "TASK-003" 2
run_hook
assert_exit_code "group ordering: exit 2" "$HOOK_EC" 2
assert_contains "group ordering: reviews group 2" "$HOOK_OUTPUT" "group 2"
assert_contains "group ordering: covers TASK-002" "$HOOK_OUTPUT" "TASK-002"
assert_contains "group ordering: covers TASK-003" "$HOOK_OUTPUT" "TASK-003"
teardown_temp_dir

# --- Granularity group, mixed groups: only current group counts toward readiness ---
# Group 1 fully IMPLEMENTED, group 2 still READY → review group 1 now (not blocked by group 2).
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"; set_task_group "TASK-001" 1
create_task_file "TASK-002" "READY";        set_task_group "TASK-002" 2
run_hook
assert_exit_code "group mixed: exit 2" "$HOOK_EC" 2
assert_contains "group mixed: group 1 ready for review" "$HOOK_OUTPUT" "group 1"
assert_contains "group mixed: aggregate dispatch" "$HOOK_OUTPUT" "AGGREGATE review unit"
teardown_temp_dir

# --- Granularity group, STALE IN_REVIEW from a mid-run switch: treat as parked ---
# A task reached IN_REVIEW under per-task mode, then granularity was switched to
# group mid-run. The unit is NOT review-ready (TASK-002 still READY), so the stale
# IN_REVIEW (the active task, selected first) must be treated as parked: keep
# implementing the rest of the unit, do NOT re-dispatch a per-task review for it.
# Regression for the PR #36 Copilot review.
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_plan
create_task_file "TASK-001" "IN_REVIEW";  set_task_group "TASK-001" 1
create_task_file "TASK-002" "READY";       set_task_group "TASK-002" 1
run_hook
assert_exit_code "group stale IN_REVIEW: exit 2" "$HOOK_EC" 2
assert_contains "group stale IN_REVIEW: awaiting aggregate review" "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
assert_contains "group stale IN_REVIEW: keep implementing TASK-002" "$HOOK_OUTPUT" "Spawn implementer agent (nazgul:implementer) for TASK-002"
assert_not_contains "group stale IN_REVIEW: NO per-task review for TASK-001" "$HOOK_OUTPUT" "Spawn review-gate agent (nazgul:review-gate) for TASK-001"
teardown_temp_dir

# --- Granularity group, BLOCKED unit: parked IMPLEMENTED must NOT trigger per-task review ---
# The unit is incomplete because a sibling is BLOCKED (nothing left to implement). The
# blocked-unit fallback surfaces the parked IMPLEMENTED task as the active task for
# recovery, but per-task review dispatch is gated to task mode — so only the awaiting
# marker shows, never a single-task review. Regression for the PR #36 CodeRabbit review.
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"; set_task_group "TASK-001" 1
create_task_file "TASK-002" "BLOCKED";      set_task_group "TASK-002" 1
run_hook
assert_exit_code "group blocked unit: exit 2" "$HOOK_EC" 2
assert_contains "group blocked unit: awaiting aggregate review" "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
assert_not_contains "group blocked unit: NO per-task review for TASK-001" "$HOOK_OUTPUT" "Spawn review-gate agent (nazgul:review-gate) for TASK-001"
# FEAT-031/ADR-022: BLOCKED means "needs human help, will resume", so it keeps vetoing
# the board; only CANCELLED is carried out of the unit.
assert_not_contains "group blocked unit: NO aggregate board while a sibling is BLOCKED" "$HOOK_OUTPUT" "AGGREGATE review unit"
teardown_temp_dir

# === AGGREGATE CARVE-OUT (board #90): CANCELLED leaves the unit, BLOCKED holds it ===
# Each row builds a fixture and runs the hook; an unbuildable one is skipped, not passed.
CO_SCANNED=0; CO_CHECKED=0; CO_SKIPPED=0; CO_UNBUILDABLE=0; CO_FINDINGS=0
CO_FAILED_AT_ENTRY=0
EVENTS=""

co_fixture() {
  # Usage: co_fixture <name> <granularity> <STATUS:group>...
  local name="$1" gran="$2"; shift 2
  local i=0 spec status group id
  CO_SCANNED=$((CO_SCANNED + 1))
  CO_FAILED_AT_ENTRY=$TESTS_FAILED
  setup_temp_dir; setup_git_repo; setup_nazgul_dir
  create_config ".review_gate.granularity = \"${gran}\"" \
    '.agents.reviewers = ["code-reviewer"]' '.learning.auto_distill_post_loop = false' \
    '.docs.verify_comments = false' '.self_audit.enabled = false'
  create_plan
  for spec in "$@"; do
    i=$((i + 1))
    status="${spec%%:*}"; group="${spec##*:}"
    id=$(printf 'TASK-%03d' "$i")
    create_task_file "$id" "$status"
    set_task_group "$id" "$group"
  done
  EVENTS="$TEST_DIR/nazgul/logs/events.jsonl"
  if [ ! -s "$TEST_DIR/nazgul/config.json" ] || [ "$i" -eq 0 ]; then
    CO_SKIPPED=$((CO_SKIPPED + 1)); CO_UNBUILDABLE=$((CO_UNBUILDABLE + 1))
    _skip "carve-out [${name}]: fixture unbuildable — not checked"
    return 1
  fi
  CO_CHECKED=$((CO_CHECKED + 1))
  run_hook
  return 0
}

co_close() {
  if [ "$TESTS_FAILED" -gt "$CO_FAILED_AT_ENTRY" ]; then
    CO_FINDINGS=$((CO_FINDINGS + 1))
  fi
  teardown_temp_dir
}

# --- 1/9: the headline defect — a task that ships nothing no longer deadlocks the unit ---
if co_fixture "group carve-out" group IMPLEMENTED:1 IMPLEMENTED:1 CANCELLED:1; then
  assert_exit_code "carve-out group: exit 2" "$HOOK_EC" 2
  assert_contains "carve-out group: board fires" "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
  assert_contains "carve-out group: board covers ONLY the implemented pair" \
    "$HOOK_OUTPUT" "covering tasks: TASK-001 TASK-002."
  assert_contains "carve-out group: names the carried-out task" \
    "$HOOK_OUTPUT" "carried out CANCELLED (TASK-003)"
  assert_contains "carve-out group: reports the partial count" \
    "$HOOK_OUTPUT" "2 of 3 unit tasks reviewed"
  assert_file_contains "carve-out group: event emitted" "$EVENTS" \
    '"event":"aggregate_board_cancelled_carveout"'
  assert_file_contains "carve-out group: event names the unit" "$EVENTS" '"unit":"group 1"'
  assert_file_contains "carve-out group: event carries the carried-out ids" \
    "$EVENTS" '"cancelled_tasks":"TASK-003"'
  assert_file_contains "carve-out group: event carries implemented" "$EVENTS" '"implemented":2'
  assert_file_contains "carve-out group: event carries total" "$EVENTS" '"total":3'
  assert_dir_not_exists "carve-out group: cancelled task acquires no review dir" \
    "$TEST_DIR/nazgul/reviews/TASK-003"
fi
co_close

# --- 2/9: one granularity up, where the unit spans every group ---
if co_fixture "feature carve-out" feature IMPLEMENTED:1 IMPLEMENTED:2 CANCELLED:3; then
  assert_exit_code "carve-out feature: exit 2" "$HOOK_EC" 2
  assert_contains "carve-out feature: board fires" "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
  assert_contains "carve-out feature: board covers ONLY the implemented pair" \
    "$HOOK_OUTPUT" "covering tasks: TASK-001 TASK-002."
  assert_contains "carve-out feature: names the carried-out task" \
    "$HOOK_OUTPUT" "carried out CANCELLED (TASK-003)"
  assert_file_contains "carve-out feature: event names the unit" "$EVENTS" '"unit":"feature"'
  assert_file_contains "carve-out feature: event carries total" "$EVENTS" '"total":3'
fi
co_close

# --- 3/9: the half that proves the check was not simply deleted ---
if co_fixture "blocked veto" group IMPLEMENTED:1 IMPLEMENTED:1 BLOCKED:1; then
  assert_exit_code "blocked veto: exit 2" "$HOOK_EC" 2
  assert_contains "blocked veto: unit stays parked" "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
  assert_not_contains "blocked veto: NO aggregate board" "$HOOK_OUTPUT" "AGGREGATE review unit"
  assert_not_contains "blocked veto: nothing is carried out" "$HOOK_OUTPUT" "CARVE-OUT"
  assert_file_not_contains "blocked veto: no carve-out event" "$EVENTS" \
    '"event":"aggregate_board_cancelled_carveout"'
fi
co_close

# --- 4/9: an empty board is not a clean one ---
if co_fixture "all cancelled" feature CANCELLED:1 CANCELLED:1; then
  assert_exit_code "all cancelled: exit 0" "$HOOK_EC" 0
  assert_contains "all cancelled: the no-dispatch path is reported" \
    "$HOOK_OUTPUT" "has nothing to review"
  assert_not_contains "all cancelled: no board readiness" "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
  assert_not_contains "all cancelled: no board dispatched" "$HOOK_OUTPUT" "AGGREGATE review unit"
  # The carve-out event is bound to a dispatch, and this arm dispatches nothing; the named
  # stderr line above is this case's record (RULES.md §1.15's own wording for it).
  assert_file_not_contains "all cancelled: no board means no carve-out event" "$EVENTS" \
    '"event":"aggregate_board_cancelled_carveout"'
fi
co_close

# --- 5/9: which unit is "active" must not be decided by a task that ships nothing ---
if co_fixture "active-group scan" group CANCELLED:1 CANCELLED:1 IMPLEMENTED:2; then
  assert_exit_code "active-group scan: exit 2" "$HOOK_EC" 2
  assert_contains "active-group scan: unit resolves to group 2" "$HOOK_OUTPUT" "group 2"
  assert_contains "active-group scan: board fires" "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
  assert_contains "active-group scan: board covers TASK-003" \
    "$HOOK_OUTPUT" "covering tasks: TASK-003."
  assert_not_contains "active-group scan: group 1's cancelled pair is not this unit's carve-out" \
    "$HOOK_OUTPUT" "CARVE-OUT"
fi
co_close

# --- 6/9 (TASK-023): bound to the DISPATCH, not the iteration — the scan reaches an unready
# unit on EVERY Stop, so "fires when it should" cannot catch an event that fires always ---
if co_fixture "unready across two Stops" feature READY:1 IMPLEMENTED:1 CANCELLED:1; then
  assert_exit_code "unready carve-out: exit 2" "$HOOK_EC" 2
  assert_contains "unready carve-out: the unit is NOT ready" \
    "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
  assert_not_contains "unready carve-out: no board is dispatched" \
    "$HOOK_OUTPUT" "AGGREGATE review unit"
  assert_contains "unready carve-out: the NOTE is still computed where it always was" \
    "$HOOK_OUTPUT" "carried out CANCELLED (TASK-003)"
  run_hook
  assert_contains "unready carve-out: still unready on the 2nd Stop" \
    "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
  co_events=$(grep -c '"event":"aggregate_board_cancelled_carveout"' "$EVENTS" 2>/dev/null || true)
  assert_eq "unready carve-out: ZERO events across two no-dispatch iterations" \
    "${co_events:-0}" "0"
fi
co_close

# --- 7/9 (PR #240 finding #11): a unit held by BLOCKED must not emit the marker of a unit
# that is merely mid-flight. Same shape as 8/9 below except for the second task's status, so
# the ONLY thing that can distinguish the two markers is the record this row demands ---
AGG_MARKER_HELD=""
AGG_MARKER_MIDFLIGHT=""
if co_fixture "blocked hold" group IMPLEMENTED:1 BLOCKED:1; then
  AGG_MARKER_HELD=$(printf '%s\n' "$HOOK_OUTPUT" | grep -m1 'AWAITING AGGREGATE REVIEW (' || true)
  assert_exit_code "blocked hold: exit 2" "$HOOK_EC" 2
  assert_contains "blocked hold: the unit is still parked, not carried out" \
    "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
  assert_contains "blocked hold: the held count is named" \
    "$HOOK_OUTPUT" "HELD: 1 of 2 unit task(s) BLOCKED"
  assert_contains "blocked hold: and the id that is holding it" "$HOOK_OUTPUT" "BLOCKED (TASK-002)"
  assert_contains "blocked hold: the instruction is followable — implementing will not release it" \
    "$HOOK_OUTPUT" "CANNOT reach review readiness"
  assert_not_contains "blocked hold: BLOCKED is NOT carried out of the unit" \
    "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
  assert_not_contains "blocked hold: and it is not a carve-out" "$HOOK_OUTPUT" "CARVE-OUT"
  assert_file_contains "blocked hold: the held iteration is recorded, not silent" "$EVENTS" \
    '"event":"aggregate_unit_blocked_hold"'
  assert_file_contains "blocked hold: the event carries the holding ids" "$EVENTS" \
    '"blocked_tasks":"TASK-002"'
  assert_file_contains "blocked hold: the event carries the counts" "$EVENTS" \
    '"blocked":1,"implemented":1,"total":2'
fi
co_close

# --- 8/9: a diagnostic that always fires is not a diagnostic ---
if co_fixture "no hold without blocked" group IMPLEMENTED:1 READY:1; then
  AGG_MARKER_MIDFLIGHT=$(printf '%s\n' "$HOOK_OUTPUT" | grep -m1 'AWAITING AGGREGATE REVIEW (' || true)
  assert_exit_code "unheld unit: exit 2" "$HOOK_EC" 2
  assert_contains "unheld unit: still mid-flight" "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
  assert_not_contains "unheld unit: a unit with zero BLOCKED tasks gains no note" \
    "$HOOK_OUTPUT" "HELD:"
  assert_file_not_contains "unheld unit: and no held-unit event" "$EVENTS" \
    '"event":"aggregate_unit_blocked_hold"'
fi
co_close

# Both markers were non-empty and differ: the deadlock is now distinguishable from progress.
assert_contains "markers: the mid-flight case really produced one" "$AGG_MARKER_MIDFLIGHT" "AWAITING"
assert_eq "the held marker and the mid-flight marker are NOT byte-identical" \
  "$([ "$AGG_MARKER_HELD" = "$AGG_MARKER_MIDFLIGHT" ] && echo identical || echo distinguishable)" \
  "distinguishable"

# --- 9/9: nothing parked at all — CONTINUE_MSG's mid-flight marker never fires here, so the
# deadlock would otherwise reach the operator as no aggregate output whatsoever ---
if co_fixture "blocked with nothing parked" feature BLOCKED:1 READY:2; then
  assert_exit_code "held-empty unit: exit 2" "$HOOK_EC" 2
  assert_contains "held-empty unit: the scan says the unit cannot reach readiness" \
    "$HOOK_OUTPUT" "cannot reach review readiness"
  assert_contains "held-empty unit: the marker says there is nothing to keep implementing" \
    "$HOOK_OUTPUT" "AGGREGATE REVIEW HELD"
  assert_not_contains "held-empty unit: it is not reported as mid-flight" \
    "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
  assert_file_contains "held-empty unit: recorded" "$EVENTS" '"event":"aggregate_unit_blocked_hold"'
fi
co_close

echo "  carve-out scan: ${CO_SCANNED} scanned, ${CO_SKIPPED} skipped (unbuildable=${CO_UNBUILDABLE}), ${CO_CHECKED} checked, ${CO_FINDINGS} findings"
assert_eq "carve-out scan: scanned == skipped + checked" \
  "$CO_SCANNED" "$((CO_SKIPPED + CO_CHECKED))"
assert_eq "carve-out scan: every scenario was checked" "$CO_CHECKED" "9"

# --- TASK-023: readiness is not dispatch — the HITL hold WITHDRAWS the board, and a
# withdrawn dispatch is one more iteration that must record no carve-out ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "feature"' '.mode = "hitl"' \
  '.agents.reviewers = ["code-reviewer"]' '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"; set_task_group TASK-001 1
create_task_file "TASK-002" "CANCELLED"; set_task_group TASK-002 1
touch "$TEST_DIR/nazgul/.hitl-pending"
run_hook
assert_contains "hitl hold: the gate replaces the board dispatch" "$HOOK_OUTPUT" "GATE hitl_pending"
assert_not_contains "hitl hold: no board goes out" "$HOOK_OUTPUT" "AGGREGATE review unit"
assert_contains "hitl hold: the readiness marker still reports the carve-out" \
  "$HOOK_OUTPUT" "carried out CANCELLED (TASK-002)"
assert_file_not_contains "hitl hold: a withdrawn dispatch records no carve-out event" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"aggregate_board_cancelled_carveout"'
teardown_temp_dir

# --- Granularity feature, INCOMPLETE: park IMPLEMENTED across groups, keep building ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "feature"'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"; set_task_group "TASK-001" 1
create_task_file "TASK-002" "READY";        set_task_group "TASK-002" 2
run_hook
assert_exit_code "feature granularity (incomplete): exit 2" "$HOOK_EC" 2
assert_contains "feature incomplete: awaiting aggregate review" "$HOOK_OUTPUT" "AWAITING AGGREGATE REVIEW"
assert_contains "feature incomplete: keep implementing" "$HOOK_OUTPUT" "Spawn implementer agent (nazgul:implementer) for TASK-002"
assert_not_contains "feature incomplete: NO per-task review" "$HOOK_OUTPUT" "Spawn review-gate agent (nazgul:review-gate) for TASK-001"
teardown_temp_dir

# --- Granularity feature, COMPLETE: ONE review over base..HEAD ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.review_gate.granularity = "feature"'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"; set_task_group "TASK-001" 1
create_task_file "TASK-002" "IMPLEMENTED"; set_task_group "TASK-002" 2
create_task_file "TASK-003" "IMPLEMENTED"; set_task_group "TASK-003" 3
run_hook
assert_exit_code "feature granularity (complete): exit 2" "$HOOK_EC" 2
assert_contains "feature complete: aggregate review ready" "$HOOK_OUTPUT" "AGGREGATE REVIEW READY"
assert_contains "feature complete: scope feature" "$HOOK_OUTPUT" "feature"
assert_contains "feature complete: base..HEAD scope" "$HOOK_OUTPUT" "base..HEAD"
assert_contains "feature complete: covers all tasks" "$HOOK_OUTPUT" "TASK-003"
teardown_temp_dir

# --- Legacy/absent granularity falls back to task behavior ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config 'del(.review_gate.granularity)'
create_plan
create_task_file "TASK-001" "IMPLEMENTED"
run_hook
assert_exit_code "absent granularity: exit 2" "$HOOK_EC" 2
assert_contains "absent granularity: defaults to task review" "$HOOK_OUTPUT" "Spawn review-gate agent (nazgul:review-gate) for TASK-001"
teardown_temp_dir

# === GRANULARITY RECONCILIATION GATE (integration) ===

# --- All DONE + coverage violation blocks completion ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-INT1"' \
  '.review_gate.granularity = "group"' \
  '.review_gate.enforce_granularity = "block"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "GROUP-1"   # MF-013: TASK-001 Group:1 (default), granularity=group -> reviews/GROUP-1
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' '{"sv":1,"ts":"2026-06-24T00:00:00Z","task_id":"TASK-001","review_unit":"TASK-001","granularity_used":"task","iteration":1}' \
  > "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
run_hook
assert_exit_code "gran gate integration: violation blocks: exit 2" "$HOOK_EC" 2
assert_contains "gran gate integration: names gate" "$HOOK_OUTPUT" "GRANULARITY GATE"
assert_contains "gran gate integration: emits decision-block JSON" "$HOOK_OUTPUT" '"decision"'
teardown_temp_dir

# --- All DONE + compliant coverage exits cleanly ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-INT2"' \
  '.review_gate.granularity = "group"' \
  '.review_gate.enforce_granularity = "block"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]' \
  '.docs.verify_comments = false' '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "GROUP-1"   # MF-013: TASK-001 Group:1 (default), granularity=group -> reviews/GROUP-1
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' '{"sv":1,"ts":"2026-06-24T00:00:00Z","task_id":"TASK-001","review_unit":"GROUP-1","granularity_used":"group","iteration":1}' \
  > "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
run_hook
assert_exit_code "gran gate integration: compliant passes: exit 0" "$HOOK_EC" 0
assert_file_contains "gran gate integration: objective_complete emitted on pass" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"objective_complete"'
teardown_temp_dir

# --- All DONE + no coverage file degrades to allow ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-INT3"' \
  '.review_gate.granularity = "group"' \
  '.review_gate.enforce_granularity = "block"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]' \
  '.docs.verify_comments = false' '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "GROUP-1"   # MF-013: TASK-001 Group:1 (default), granularity=group -> reviews/GROUP-1
run_hook
assert_exit_code "gran gate integration: no coverage degrades: exit 0" "$HOOK_EC" 0
teardown_temp_dir

# === SELF-AUDIT GATE (self_audit.enabled) ===

# --- SA-1: opt-out (self_audit.enabled=false) — no-op, exit 0, no marker ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-SA1"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
run_hook
assert_exit_code "SA-1: opt-out → exit 0" "$HOOK_EC" 0
assert_file_not_exists "SA-1: no marker when opted out" "$TEST_DIR/nazgul/logs/.self-audited"
assert_not_contains "SA-1: no decision JSON when opted out" "$HOOK_OUTPUT" '"decision"'
teardown_temp_dir

# --- SA-2: marker absent — block, exit 2, DELEGATE on stderr ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-SA2"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
run_hook
assert_exit_code "SA-2: marker absent → exit 2" "$HOOK_EC" 2
assert_contains "SA-2: decision block in stdout" "$HOOK_OUTPUT" '"decision": "block"'
assert_contains "SA-2: reason mentions feat_id" "$HOOK_OUTPUT" "FEAT-SA2"
assert_contains "SA-2: DELEGATE instruction emitted" "$HOOK_OUTPUT" "nazgul:self-audit"
assert_file_exists "SA-2: attempts file created" "$TEST_DIR/nazgul/logs/.self-audit-attempts"
assert_contains "SA-2: attempts scoped to feat_id" "$(cat "$TEST_DIR/nazgul/logs/.self-audit-attempts")" "FEAT-SA2"
teardown_temp_dir

# --- SA-3: marker matches feat_id — pass immediately, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-SA3"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-SA3" > "$TEST_DIR/nazgul/logs/.self-audited"
run_hook
assert_exit_code "SA-3: marker matches → exit 0" "$HOOK_EC" 0
assert_not_contains "SA-3: no block when marker matches" "$HOOK_OUTPUT" '"decision": "block"'
teardown_temp_dir

# --- SA-4: stale marker (different feat_id) — re-gates, exit 2 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-SA4"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-STALE" > "$TEST_DIR/nazgul/logs/.self-audited"
run_hook
assert_exit_code "SA-4: stale marker → exit 2" "$HOOK_EC" 2
assert_contains "SA-4: decision block for stale marker" "$HOOK_OUTPUT" '"decision": "block"'
teardown_temp_dir

# --- SA-5: attempts increment 0→1→2 (still blocking) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-SA5"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-SA5" "2" > "$TEST_DIR/nazgul/logs/.self-audit-attempts"
run_hook
assert_exit_code "SA-5: attempts=2 → still exit 2" "$HOOK_EC" 2
assert_eq "SA-5: attempts incremented to 3" \
  "$(awk '{print $2}' "$TEST_DIR/nazgul/logs/.self-audit-attempts")" "3"
teardown_temp_dir

# --- SA-6: backstop (attempts≥3) — completes with warning, exit 0, marker written ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-SA6"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-SA6" "3" > "$TEST_DIR/nazgul/logs/.self-audit-attempts"
run_hook
assert_exit_code "SA-6: backstop → exit 0" "$HOOK_EC" 0
assert_contains "SA-6: backstop warns" "$HOOK_OUTPUT" "gave up"
assert_file_exists "SA-6: backstop writes marker" "$TEST_DIR/nazgul/logs/.self-audited"
assert_eq "SA-6: backstop marker contains feat_id" \
  "$(cat "$TEST_DIR/nazgul/logs/.self-audited")" "FEAT-SA6"
teardown_temp_dir

# --- SA-7: attempts reset when feat_id changes ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-SA7"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
# attempts file belongs to a different objective
printf '%s %s\n' "FEAT-OLD" "3" > "$TEST_DIR/nazgul/logs/.self-audit-attempts"
run_hook
# Old attempts (3) belonged to different obj — counter resets to 0, so this attempt = 1 → still blocks
assert_exit_code "SA-7: reset attempts on new feat_id → exit 2" "$HOOK_EC" 2
assert_eq "SA-7: attempts written as 1 after reset" \
  "$(awk '{print $2}' "$TEST_DIR/nazgul/logs/.self-audit-attempts")" "1"
assert_eq "SA-7: attempts scoped to new feat_id" \
  "$(awk '{print $1}' "$TEST_DIR/nazgul/logs/.self-audit-attempts")" "FEAT-SA7"
teardown_temp_dir

# --- RECON-1: Bash-write bypass (status flipped by direct file rewrite, not
# through task-state-guard.sh) is flagged BLOCKED at the next iteration
# (MF-022) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
run_hook
sed -i.bak 's/^status: IN_PROGRESS/status: DONE/' "$TEST_DIR/nazgul/tasks/TASK-001.md" && rm -f "$TEST_DIR/nazgul/tasks/TASK-001.md.bak"
run_hook
assert_eq "recon: forged status flagged BLOCKED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_contains "recon: diagnostic names the task id" "$HOOK_OUTPUT" "TASK-001"
assert_contains "recon: diagnostic names outside guarded path" "$HOOK_OUTPUT" "outside the guarded Write/Edit/MultiEdit path"
assert_contains "recon: blocked reason recorded on manifest" \
  "$(grep -m1 '^\- \*\*Blocked reason\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md")" "outside the guarded"
teardown_temp_dir

# --- RECON-2: kill switch off — same forged write is NOT reconciled ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.guards.bash_write_reconciliation = false'
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
run_hook
sed -i.bak 's/^status: IN_PROGRESS/status: IMPLEMENTED/' "$TEST_DIR/nazgul/tasks/TASK-001.md" && rm -f "$TEST_DIR/nazgul/tasks/TASK-001.md.bak"
run_hook
assert_eq "recon: kill switch off — forged status left untouched" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "IMPLEMENTED"
teardown_temp_dir

# --- RECON-3: authority is the completed-write ledger (ADR-020). An edge
# applied by scripts/task-transition.sh is NOT reconciled to BLOCKED; a status
# reached by any other route in the same window still is. Both directions are
# asserted from one fixture so neither can pass vacuously. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
RECON_BASE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD~1)
RECON_HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)

# Scope is deliberately outside scripts/** and tests/**, so this fixture
# exercises the commit gate without needing captured red-run evidence.
recon_cycle_manifest() { # <task-id> <status>
  printf -- '---\nstatus: %s\n---\n# %s: Test task\n\n## Metadata\n- **Depends on**: none\n- **Group**: 1\n- **Retry count**: 0/3\n- **Files modified**: ["docs/foo.md"]\n- **Base SHA**: %s\n\n## Commits\n- %s — feat: work\n' \
    "$2" "$1" "$RECON_BASE_SHA" "$RECON_HEAD_SHA"
}
run_transition_cmd() { # <task-id> <from> <to>
  TRANSITION_EC=0
  CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$REPO_ROOT/scripts/task-transition.sh" \
    transition "$1" "$2" "$3" >/dev/null 2>"$TEST_DIR/transition.err" || TRANSITION_EC=$?
}

recon_cycle_manifest TASK-001 IN_PROGRESS > "$TEST_DIR/nazgul/tasks/TASK-001.md"
recon_cycle_manifest TASK-002 READY > "$TEST_DIR/nazgul/tasks/TASK-002.md"
run_hook
run_transition_cmd TASK-001 IN_PROGRESS IMPLEMENTED
assert_exit_code "recon: sanctioned command applies the implementer's own edge" "$TRANSITION_EC" 0
sed -i.bak 's/^status: READY/status: IN_PROGRESS/' "$TEST_DIR/nazgul/tasks/TASK-002.md" \
  && rm -f "$TEST_DIR/nazgul/tasks/TASK-002.md.bak"
run_hook
assert_eq "recon: command-applied transition not reconciled to BLOCKED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "IMPLEMENTED"
assert_eq "recon: same-window write by another route is still reconciled to BLOCKED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "BLOCKED"
assert_contains "recon: diagnostic names the completed-write authority" \
  "$HOOK_OUTPUT" 'no completed transition recorded by ${CLAUDE_PLUGIN_ROOT}/scripts/task-transition.sh'
teardown_temp_dir

# --- RECON-4: the stop-hook's OWN auto-promote (PLANNED -> READY) runs after
# the iteration's checkpoint snapshot; it must ledger-log the write so the
# NEXT iteration's reconciliation doesn't flag the hook's legitimate
# promotion as a bash-write forgery ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "PLANNED"
run_hook
assert_eq "recon: auto-promote flipped PLANNED to READY" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "READY"
run_hook
assert_eq "recon: hook's own auto-promote not reconciled to BLOCKED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "READY"
teardown_temp_dir

# --- PROMOTE-1 (PR #86 review): a dependency whose manifest is ABSENT is "could
# not look", not "looked and found it satisfied" — the arm must fail closed. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-002" "PLANNED" "TASK-001"   # TASK-001.md is never created
create_task_file "TASK-003" "READY"                # keeps the loop alive
run_hook
assert_eq "promote: a missing dependency manifest does NOT auto-promote" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "PLANNED"
assert_contains "promote: the hold names the dependency that could not be read" \
  "$HOOK_OUTPUT" "dependency TASK-001 has no canonical manifest"
teardown_temp_dir

# --- PROMOTE-2: the promotion goes through the ADR-020 sanctioned path, so its
# ledger entry carries the before/after content hashes only that path computes. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "PLANNED"
run_hook
assert_eq "promote: a dependency-free task still reaches READY" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "READY"
PROMOTE_LEDGER="$TEST_DIR/nazgul/logs/guarded-transitions.jsonl"
PROMOTE_ENTRY=$(jq -c 'select(.task_id=="TASK-001" and .from=="PLANNED" and .to=="READY")' \
  "$PROMOTE_LEDGER" 2>/dev/null | tail -1)
assert_contains "promote: the edge is recorded in the completed-write ledger" \
  "$PROMOTE_ENTRY" '"to":"READY"'
assert_contains "promote: the ledger entry carries the source hash" \
  "$PROMOTE_ENTRY" "before_sha256"
assert_contains "promote: the ledger entry carries the verified target hash" \
  "$PROMOTE_ENTRY" "after_sha256"
teardown_temp_dir

# --- PROMOTE-3: a dependency present but NOT satisfied still holds the task, and
# a satisfied one still promotes — the pre-filter did not become a blanket deny. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
create_task_file "TASK-002" "PLANNED" "TASK-001"
create_task_file "TASK-004" "DONE"
create_review_dir "TASK-004"   # else the review gate resets DONE and moots the case
create_task_file "TASK-005" "PLANNED" "TASK-004"
run_hook
assert_eq "promote: an unsatisfied dependency holds the task at PLANNED" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-002.md")" "PLANNED"
assert_eq "promote: a satisfied dependency still promotes to READY" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-005.md")" "READY"
teardown_temp_dir

# --- FIELD-1 (PR #86 review): set_manifest_field staged through a PREDICTABLE
# `${file}.field.tmp` that a pre-created symlink could aim at another file. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
# Seeded with a Blocked reason so the git-conflict upsert takes the REPLACE
# branch — the only one that ever staged through `${file}.field.tmp`.
create_task_file "TASK-001" "IN_PROGRESS" "none" "seed reason"
FIELD_CANARY="$TEST_DIR/field-canary.txt"
printf 'do-not-truncate\n' > "$FIELD_CANARY"
chmod 600 "$FIELD_CANARY"
ln -s "$FIELD_CANARY" "$TEST_DIR/nazgul/tasks/TASK-001.md.field.tmp"
git -C "$TEST_DIR" checkout -q -b field-conflict-branch
echo "conflict line A" > "$TEST_DIR/conflict.txt"
git -C "$TEST_DIR" add conflict.txt
git -C "$TEST_DIR" commit -q -m "branch A"
git -C "$TEST_DIR" checkout -q main 2>/dev/null || git -C "$TEST_DIR" checkout -q master
echo "conflict line B" > "$TEST_DIR/conflict.txt"
git -C "$TEST_DIR" add conflict.txt
git -C "$TEST_DIR" commit -q -m "branch B"
git -C "$TEST_DIR" merge field-conflict-branch --no-commit 2>/dev/null || true
field_porcelain=$(git -C "$TEST_DIR" status --porcelain 2>/dev/null || echo "")
if echo "$field_porcelain" | grep -qE '^(U.|.U|AA|DD) '; then
  run_hook
  assert_eq "field: the upsert really took the replace branch" \
    "$(grep -c '^- \*\*Blocked reason\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md")" "1"
  assert_contains "field: the replaced value is the conflict reason" \
    "$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")" "git conflict — unmerged files detected"
  assert_eq "field: the symlink bait target is not truncated" \
    "$(cat "$FIELD_CANARY")" "do-not-truncate"
  assert_eq "field: the symlink bait target keeps its mode" \
    "$(file_mode_probe "$FIELD_CANARY")" "600"
  if [ -L "$TEST_DIR/nazgul/tasks/TASK-001.md" ]; then
    _fail "field: the manifest is not replaced by the pre-placed symlink"
  else
    _pass "field: the manifest is not replaced by the pre-placed symlink"
  fi
else
  _skip "field: the upsert really took the replace branch (skipped — no conflict produced)"
  _skip "field: the replaced value is the conflict reason (skipped — no conflict produced)"
  _skip "field: the symlink bait target is not truncated (skipped — no conflict produced)"
  _skip "field: the symlink bait target keeps its mode (skipped — no conflict produced)"
  _skip "field: the manifest is not replaced by the pre-placed symlink (skipped — no conflict produced)"
fi
teardown_temp_dir

# --- RECON-5: the loop must not wedge on its own change. Every routine edge —
# the implementer's claim and IMPLEMENTED, the review gate's IN_REVIEW and DONE
# — must still complete once direct status writes are denied, and several of
# them land inside ONE checkpoint window, so reconciliation has to resolve a
# chain of completed edges rather than a single entry. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' \
  '.learning.auto_distill_post_loop = false' '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_review_dir "TASK-001"
RECON_BASE_SHA=$(git -C "$TEST_DIR" rev-parse HEAD~1)
RECON_HEAD_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)
recon_cycle_manifest TASK-001 READY > "$TEST_DIR/nazgul/tasks/TASK-001.md"
run_hook
CYCLE_STEPS="READY:IN_PROGRESS IN_PROGRESS:IMPLEMENTED IMPLEMENTED:IN_REVIEW IN_REVIEW:DONE"
for cycle_step in $CYCLE_STEPS; do
  run_transition_cmd TASK-001 "${cycle_step%%:*}" "${cycle_step##*:}"
  assert_exit_code "cycle: ${cycle_step%%:*} -> ${cycle_step##*:} completes through the command" \
    "$TRANSITION_EC" 0
done
assert_eq "cycle: task reaches DONE entirely through the command" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "DONE"
run_hook
assert_eq "cycle: a multi-edge window is chained by the ledger, not quarantined" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "DONE"
teardown_temp_dir

# --- RECON-6: the quarantine must authorize its own BLOCKED in the ledger as its
# five siblings do; unlogged, the arm's own write reads as a forgery next pass. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
run_hook
sed -i.bak 's/^status: IN_PROGRESS/status: DONE/' "$TEST_DIR/nazgul/tasks/TASK-001.md" && rm -f "$TEST_DIR/nazgul/tasks/TASK-001.md.bak"
run_hook
assert_eq "recon-ledger: forged status quarantined" \
  "$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")" "BLOCKED"
assert_eq "recon-ledger: quarantine edge recorded with stop-hook attribution" \
  "$(jq -r 'select(.task_id == "TASK-001" and .from == "DONE" and .to == "BLOCKED" and .writer == "stop-hook") | .to' \
     "$TEST_DIR/nazgul/logs/guarded-transitions.jsonl" 2>/dev/null | head -1)" "BLOCKED"
teardown_temp_dir

# --- RECON-7: re-entry (a crash between the status write and the checkpoint that
# records it) must not overwrite the first observation, which is what repair reads. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "IN_PROGRESS"
run_hook
sed -i.bak 's/^status: IN_PROGRESS/status: DONE/' "$TEST_DIR/nazgul/tasks/TASK-001.md" && rm -f "$TEST_DIR/nazgul/tasks/TASK-001.md.bak"
run_hook
recon_blocked_field() { grep -m1 "^\- \*\*$1\*\*:" "$TEST_DIR/nazgul/tasks/TASK-001.md" 2>/dev/null | sed 's/.*: //'; }
assert_eq "recon-reentry: first pass records the observed status" \
  "$(recon_blocked_field 'Blocked observed')" "DONE"
# Drop only the checkpoint that recorded the quarantine, leaving the stale one newest.
for recon_cp in "$TEST_DIR"/nazgul/checkpoints/iteration-*.json; do
  [ -f "$recon_cp" ] || continue
  if [ "$(jq -r '.task_statuses["TASK-001"] // ""' "$recon_cp" 2>/dev/null)" = "BLOCKED" ]; then rm -f "$recon_cp"; fi
done
run_hook
assert_eq "recon-reentry: the original observed status survives re-quarantine" \
  "$(recon_blocked_field 'Blocked observed')" "DONE"
assert_eq "recon-reentry: the original checkpoint status survives re-quarantine" \
  "$(recon_blocked_field 'Blocked from')" "IN_PROGRESS"
assert_contains "recon-reentry: re-entry is recorded, not silently skipped" \
  "$HOOK_OUTPUT" "is already quarantined"
teardown_temp_dir

# === MF-006: HITL pending-approval marker gates the DEFAULT sequential path ===
# nazgul/.hitl-pending, when present in mode=hitl, must suppress the DELEGATE
# line the default sequential DISPATCH_INSTR would otherwise emit — mirroring
# execution_should_pause's gate-check pattern (previously only reachable via
# the opt-in EXEC_PARALLEL=true approve_batch path). Clearing the marker
# restores normal dispatch.

# --- MF-006a: marker set + mode=hitl → no DELEGATE line, GATE message instead ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode = "hitl"'
create_plan
create_task_file "TASK-001" "READY"
touch "$TEST_DIR/nazgul/.hitl-pending"
run_hook
assert_exit_code "MF-006a: exit 2 (continue loop)" "$HOOK_EC" 2
assert_not_contains "MF-006a: no DELEGATE line while pending" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-001"
assert_contains "MF-006a: GATE hitl_pending message shown" "$HOOK_OUTPUT" "GATE hitl_pending"
assert_contains "MF-006a: GATE message names the marker" "$HOOK_OUTPUT" "nazgul/.hitl-pending"
teardown_temp_dir

# --- MF-006b: marker cleared → normal DELEGATE dispatch restored ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode = "hitl"'
create_plan
create_task_file "TASK-001" "READY"
run_hook
assert_exit_code "MF-006b: exit 2 (continue loop)" "$HOOK_EC" 2
assert_contains "MF-006b: DELEGATE line restored once marker cleared" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-001"
assert_not_contains "MF-006b: no GATE hitl_pending message" "$HOOK_OUTPUT" "GATE hitl_pending"
teardown_temp_dir

# --- MF-006c: marker set but mode != hitl (e.g. afk) → gate does not apply ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode = "afk"'
create_plan
create_task_file "TASK-001" "READY"
touch "$TEST_DIR/nazgul/.hitl-pending"
run_hook
assert_contains "MF-006c: non-hitl mode dispatches despite marker" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-001"
teardown_temp_dir

# --- 0-D: the session lock SURVIVES an allowed stop (exit-0 no longer unregisters) ---
setup_temp_dir
setup_nazgul_dir
create_config
printf 'sess-hold' > "$TEST_DIR/nazgul/.session_id"
mkdir -p "$TEST_DIR/nazgul/in-flight"
NOW=$(date +%s)
jq -cn --argjson e "$NOW" '{agent:"nazgul:implementer",unit:"TASK-001",dispatched_at:"x",dispatched_at_epoch:$e,prompt_hash:"0123456789abcdef",prompt_bytes:1,background:"true",named:"false"}' \
  > "$TEST_DIR/nazgul/in-flight/bg.json"
(cd "$TEST_DIR" && bash "$REPO_ROOT/scripts/stop-hook.sh" </dev/null >/dev/null 2>&1); EC=$?
assert_exit_code "0-D: hold path exits 0" "$EC" 0
LOCKS=$(ls "$TEST_DIR"/nazgul/sessions/*.lock 2>/dev/null | wc -l | tr -d ' ')
assert_eq "0-D: session lock persists through the allowed stop" "$LOCKS" "1"
teardown_temp_dir

# --- P8c (FEAT-034 TASK-005, ADR-028 D5.5): a mixed-version marker is consumed exactly like its
# new-shape twin. CONTROL, not a red pin — it passes at the Base SHA too, where old is the only shape.
_p8c_arm() {
  setup_temp_dir
  setup_nazgul_dir
  create_config
  printf 'sess-p8c' > "$TEST_DIR/nazgul/.session_id"
  mkdir -p "$TEST_DIR/nazgul/in-flight"
  jq -cn --argjson e "$(date +%s)" --arg bg "$1" --argjson digest "$2" \
    '{agent:"nazgul:implementer",unit:"TASK-901",dispatched_at:"x",dispatched_at_epoch:$e,background:$bg,named:"false"} * $digest' \
    > "$TEST_DIR/nazgul/in-flight/mv.json"
  (cd "$TEST_DIR" && bash "$STOP_HOOK" </dev/null >/dev/null 2>"$TEST_DIR/mv.err"); P8C_EC=$?
  P8C_WHERE=$([ -f "$TEST_DIR/nazgul/in-flight/quarantine/mv.json" ] && echo quarantine || echo in-flight)
  P8C_ERR=$(cat "$TEST_DIR/mv.err")
  teardown_temp_dir
}
P8C_OLD_SHAPE='{"prompt_head":"legacy prompt text that used to reach disk"}'
P8C_NEW_SHAPE='{"prompt_hash":"0123456789abcdef","prompt_bytes":42}'

_p8c_arm "false" "$P8C_OLD_SHAPE"
P8C_A_EC="$P8C_EC"; P8C_A_WHERE="$P8C_WHERE"; P8C_A_ERR="$P8C_ERR"
_p8c_arm "false" "$P8C_NEW_SHAPE"
P8C_B_EC="$P8C_EC"; P8C_B_WHERE="$P8C_WHERE"; P8C_B_ERR="$P8C_ERR"
assert_eq "P8c: an old-shape foreground marker is still quarantined by the consumer" "$P8C_A_WHERE" "quarantine"
assert_contains "P8c: and the consumer still reads the unit out of it" "$P8C_A_ERR" "ORPHAN in-flight marker for TASK-901"
assert_eq "P8c: old and new shapes get a byte-identical quarantine disposition" "$P8C_A_EC|$P8C_A_WHERE|$P8C_A_ERR" "$P8C_B_EC|$P8C_B_WHERE|$P8C_B_ERR"

_p8c_arm "true" "$P8C_OLD_SHAPE"
P8C_C_EC="$P8C_EC"; P8C_C_WHERE="$P8C_WHERE"; P8C_C_ERR="$P8C_ERR"
_p8c_arm "true" "$P8C_NEW_SHAPE"
P8C_D_EC="$P8C_EC"; P8C_D_WHERE="$P8C_WHERE"; P8C_D_ERR="$P8C_ERR"
assert_eq "P8c: an old-shape background marker is still held on, not quarantined" "$P8C_C_WHERE" "in-flight"
assert_contains "P8c: and the hold still names the unit it read from the old shape" "$P8C_C_ERR" "in-flight hold — waiting on 1 BACKGROUND dispatch(es): TASK-901"
assert_eq "P8c: old and new shapes get a byte-identical hold disposition" "$P8C_C_EC|$P8C_C_WHERE|$P8C_C_ERR" "$P8C_D_EC|$P8C_D_WHERE|$P8C_D_ERR"
# --- TASK-043 (AC2): a validator-defect-only evidence pass — every reviewer authorized-
# skipped, only paperwork left — is a checker malfunction, not a task strike. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["qa-reviewer"]' '.review_gate.conditional_dispatch = true'
create_plan
create_task_file "TASK-001" "DONE"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- 'diff --git a/src/app.py b/src/app.py\n--- a/src/app.py\n+++ b/src/app.py\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/diff.patch"
jq -n '{unit:"TASK-001", skipped:[{name:"qa-reviewer", reason:"no tests changed"}]}' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/.dispatch.json"
printf '# summary\n' > "$TEST_DIR/nazgul/reviews/TASK-001/summary.md"
create_task_file "TASK-002" "READY"
run_hook
assert_exit_code "defect-only: exit 2 (loop continues)" "$HOOK_EC" 2
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "defect-only: DONE left in place" "$status" "DONE"
assert_not_contains "defect-only: not a review-gate violation" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_not_contains "defect-only: never suggests materialize" "$HOOK_OUTPUT" "materialize"
assert_contains "defect-only: names the mechanism, not the task" "$HOOK_OUTPUT" \
  "review-evidence reported a validator defect (NOTHING_CHECKED)"
assert_file_contains "defect-only: stop_gate event fires" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"reason":"review_validator_defect"'
assert_file_contains "defect-only: event names the validator" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"validator":"review-evidence"'
count=$(jq -r '.safety._review_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "defect-only: no strike recorded" "$count" "0"
teardown_temp_dir

# --- TASK-043 (AC2 converse): a genuine MISSING problem with no validator defect present
# still takes the ordinary two-strike ladder — the fix must not weaken the real case. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer", "qa-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_task_file "TASK-002" "READY"
run_hook
assert_contains "converse: genuine problem still takes the ladder" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_not_contains "converse: no validator-defect noise on a genuine-only problem" \
  "$HOOK_OUTPUT" "validator defect"
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "converse: first violation still resets to IMPLEMENTED" "$status" "IMPLEMENTED"
teardown_temp_dir

# --- TASK-043 (defect ALONGSIDE genuine): a defect arriving next to a real MISSING problem
# does not swallow the real problem — the ladder still runs on it. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf '# BOARD-2-OUTCOME\n' > "$TEST_DIR/nazgul/reviews/TASK-001/BOARD-2-OUTCOME.md"
printf '# adversarial\n' > "$TEST_DIR/nazgul/reviews/TASK-001/adversarial-SEC-1.md"
create_task_file "TASK-002" "READY"
run_hook
assert_contains "alongside: still takes the ladder" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_contains "alongside: real reviewer named in the violation" "$HOOK_OUTPUT" "code-reviewer"
assert_contains "alongside: the defect is ALSO surfaced, separately" "$HOOK_OUTPUT" \
  "review-evidence reported a validator defect (NOTHING_CHECKED)"
assert_file_contains "alongside: stop_gate event still fires" \
  "$TEST_DIR/nazgul/logs/events.jsonl" '"reason":"review_validator_defect"'
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "alongside: first violation still resets to IMPLEMENTED" "$status" "IMPLEMENTED"
teardown_temp_dir

report_results
