#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: stop-hook.sh loop engine, state machine, checkpoints, promotions
TEST_NAME="test-stop-hook"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

# Helper: run hook capturing output and exit code
# Sets: HOOK_OUTPUT, HOOK_EC
run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
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
  '.docs.verify_comments = false'
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
  '.docs.verify_comments = false'
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
  '.docs.verify_comments = false'
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

# --- Test 6: AFK timeout — exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
past_ts=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$past_ts" ]; then
  create_config ".afk.enabled = true" ".afk.timeout_minutes = 90" ".objective_set_at = \"$past_ts\""
  create_plan
  create_task_file "TASK-001" "READY"
  run_hook
  assert_exit_code "AFK timeout: exit 0" "$HOOK_EC" 0
  assert_contains "AFK timeout stderr" "$HOOK_OUTPUT" "AFK timeout"
else
  _pass "AFK timeout: exit 0 (skipped — date format unavailable)"
  _pass "AFK timeout stderr (skipped)"
fi
teardown_temp_dir

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

# --- Test 16: Promote PLANNED -> READY (no deps) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
create_task_file "TASK-001" "PLANNED" "none"
run_hook
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md" | sed 's/.*: //')
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
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-002.md" | sed 's/.*: //')
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
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-002.md" | sed 's/.*: //')
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
  status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md" | sed 's/.*: //')
  assert_eq "git conflict blocks task" "$status" "BLOCKED"
  assert_file_contains "blocked event emitted on git conflict" \
    "$TEST_DIR/nazgul/logs/events.jsonl" '"event":"blocked"'
  assert_file_contains "blocked event names task" \
    "$TEST_DIR/nazgul/logs/events.jsonl" '"task_id":"TASK-001"'
else
  _pass "git conflict blocks task (skipped — no conflict produced)"
  _pass "blocked event emitted on git conflict (skipped — no conflict produced)"
  _pass "blocked event names task (skipped — no conflict produced)"
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
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md" | sed 's/.*: //')
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
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md" | sed 's/.*: //')
assert_eq "DONE with reviews stays DONE" "$status" "DONE"
teardown_temp_dir

# --- Test: YOLO without task-pr — all APPROVED exits cleanly ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.afk.yolo = true' '.afk.task_pr = false' '.current_iteration = 1' '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "APPROVED"
create_task_file "TASK-002" "APPROVED"
create_review_dir "TASK-001"
create_review_dir "TASK-002"
run_hook
assert_exit_code "YOLO no task-pr: all APPROVED exits 0" "$HOOK_EC" 0
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
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md" | sed 's/.*: //')
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
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md" | sed 's/.*: //')
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
status=$(grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/TASK-001.md" | sed 's/.*: //')
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
  _pass "AFK objective_set_at precedence (skipped — date format unavailable)"
fi
teardown_temp_dir

# AFK clock falls back to oldest checkpoint when objective_set_at absent
setup_temp_dir; setup_git_repo; setup_nazgul_dir
old_ts=$(date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "3 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$old_ts" ]; then
  create_config ".afk.enabled = true" ".afk.timeout_minutes = 90"
  jq 'del(.objective_set_at)' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
  create_plan; create_task_file "TASK-001" "READY"
  printf '{"iteration":1,"timestamp":"%s"}\n' "$old_ts" > "$TEST_DIR/nazgul/checkpoints/iteration-001.json"
  run_hook
  assert_exit_code "AFK: falls back to old checkpoint when objective_set_at absent → stop" "$HOOK_EC" 0
  assert_contains "AFK fallback stderr" "$HOOK_OUTPUT" "AFK timeout"
else
  _pass "AFK checkpoint fallback (skipped — date format unavailable)"
  _pass "AFK fallback stderr (skipped)"
fi
teardown_temp_dir

# AFK clock falls back to durable iterations.jsonl when objective_set_at absent
# (decoupled from pruning: fires even with no/recent checkpoints — covers migrated
# configs where migrate_4_to_5 deleted objective_set_at)
setup_temp_dir; setup_git_repo; setup_nazgul_dir
old_ts=$(date -u -v-3H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "3 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [ -n "$old_ts" ]; then
  create_config ".afk.enabled = true" ".afk.timeout_minutes = 90"
  jq 'del(.objective_set_at)' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
  create_plan; create_task_file "TASK-001" "READY"
  mkdir -p "$TEST_DIR/nazgul/logs"
  printf '{"iteration":1,"timestamp":"%s"}\n' "$old_ts" > "$TEST_DIR/nazgul/logs/iterations.jsonl"
  run_hook
  assert_exit_code "AFK: durable iterations.jsonl fallback fires → stop" "$HOOK_EC" 0
  assert_contains "AFK durable-log fallback stderr" "$HOOK_OUTPUT" "AFK timeout"
else
  _pass "AFK durable-log fallback (skipped — date format unavailable)"
  _pass "AFK durable-log fallback stderr (skipped)"
fi
teardown_temp_dir

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
teardown_temp_dir

# --- Granularity group, ORDERING: earlier group done, review the next group only ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
# Configure a reviewer so the DONE task's review evidence validates (otherwise the
# Layer-2 enforcement net would reset DONE → IMPLEMENTED and skew the scenario).
create_config '.review_gate.granularity = "group"' '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE";        set_task_group "TASK-001" 1
create_review_dir "TASK-001"
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
create_review_dir "TASK-001"
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
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
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
  '.docs.verify_comments = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
run_hook
assert_exit_code "gran gate integration: no coverage degrades: exit 0" "$HOOK_EC" 0
teardown_temp_dir

report_results
