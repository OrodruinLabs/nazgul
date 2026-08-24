#!/usr/bin/env bash
set -euo pipefail

# Test: session-context.sh reads state and outputs context
TEST_NAME="test-session-context"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

SESSION_SCRIPT="$REPO_ROOT/scripts/session-context.sh"

# --- Test 1: No config — exit 0, no output ---
setup_temp_dir
ec=0
output=$(bash "$SESSION_SCRIPT" 2>&1) || ec=$?
assert_exit_code "no config: exit 0" "$ec" 0
teardown_temp_dir

# --- Test 2: Basic output with iteration and mode ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.current_iteration = 7' '.max_iterations = 40' '.mode = "hitl"'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "shows iteration" "$output" "7/40"
assert_contains "shows mode" "$output" "hitl"
teardown_temp_dir

# --- Test 3: Task counts ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "READY"
create_task_file "TASK-004" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "done count" "$output" "2 done"
assert_contains "ready count" "$output" "1 ready"
assert_contains "in progress count" "$output" "1 in progress"
teardown_temp_dir

# --- Test 4: Active task shown ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-003" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "active task shown" "$output" "Active task: TASK-003"
teardown_temp_dir

# --- Test 5: Objective shown ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.objective = "Build X"'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "objective shown" "$output" "Objective: Build X"
teardown_temp_dir

# --- Test 6: Recovery pointer output ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_plan
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "recovery pointer" "$output" "Recovery Pointer"
teardown_temp_dir

# --- Test 7: Reviewers listed ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.agents.reviewers = ["architect-reviewer", "code-reviewer"]'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "reviewer names" "$output" "architect-reviewer"
teardown_temp_dir

# --- Test 8: CHANGES_REQUESTED warning ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
create_task_file "TASK-001" "CHANGES_REQUESTED"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "changes requested warning" "$output" "WARNING"
teardown_temp_dir

# --- Test 9: Compact event increments counter (no prior file) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
export CLAUDE_HOOK_EVENT="compact"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
assert_file_exists "compaction_count created" "$TEST_DIR/nazgul/.compaction_count"
val=$(jq -r '.count' "$TEST_DIR/nazgul/.compaction_count")
assert_eq "compact count is 1" "$val" "1"
unset CLAUDE_HOOK_EVENT
teardown_temp_dir

# --- Test 10: Compact preserves and increments count ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
printf '{"count": 3, "last_compaction_iteration": 5}\n' > "$TEST_DIR/nazgul/.compaction_count"
export CLAUDE_HOOK_EVENT="compact"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
val=$(jq -r '.count' "$TEST_DIR/nazgul/.compaction_count")
assert_eq "compact count incremented to 4" "$val" "4"
unset CLAUDE_HOOK_EVENT
teardown_temp_dir

# --- Test 11: Telemetry-dark — stale plan.md Status Summary fires (MF-060) ---
# plan.md claims all 3 tasks are still PLANNED (0 done, 0 in progress) while the
# actual task manifests show 2 DONE + 1 IN_PROGRESS — the live MF-060 symptom
# (an Agent-Team/SendMessage-driven objective bypassing stop-hook.sh's recompute).
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
cat > "$TEST_DIR/nazgul/plan.md" << 'PLAN_EOF'
# Nazgul Plan

## Objective
Test objective

## Status Summary
- Total tasks: 3
- DONE: 0 | READY: 0 | IN_PROGRESS: 0 | IN_REVIEW: 0 | IMPLEMENTED: 0 | CHANGES_REQUESTED: 0 | BLOCKED: 0 | PLANNED: 3

## Recovery Pointer
- **Current Task:** none
- **Last Action:** Plan created, no tasks started
- **Next Action:** Run discovery, then begin task execution
- **Last Checkpoint:** none
- **Last Commit:** none

## Tasks
PLAN_EOF
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "stale plan.md is flagged" "$output" "Status Summary is stale"
assert_contains "stale warning cites MF-060" "$output" "MF-060"
teardown_temp_dir

# --- Test 12: Telemetry-dark — matching plan.md Status Summary stays quiet ---
# Declared counts agree with the actual manifests, so no diagnostic should fire.
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
cat > "$TEST_DIR/nazgul/plan.md" << 'PLAN_EOF'
# Nazgul Plan

## Objective
Test objective

## Status Summary
- Total tasks: 3
- DONE: 2 | READY: 0 | IN_PROGRESS: 1 | IN_REVIEW: 0 | IMPLEMENTED: 0 | CHANGES_REQUESTED: 0 | BLOCKED: 0 | PLANNED: 0

## Recovery Pointer
- **Current Task:** none
- **Last Action:** none
- **Next Action:** none
- **Last Checkpoint:** none
- **Last Commit:** none

## Tasks
PLAN_EOF
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "DONE"
create_task_file "TASK-003" "IN_PROGRESS"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_not_contains "matching plan.md stays quiet" "$output" "Status Summary is stale"
teardown_temp_dir

# --- Test 13: Telemetry-dark — plan.md with no Status Summary is flagged, non-fatal ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
cat > "$TEST_DIR/nazgul/plan.md" << 'PLAN_EOF'
# Nazgul Plan

## Objective
Test objective, no Status Summary section at all

## Recovery Pointer
- **Current Task:** none
- **Last Action:** none
- **Next Action:** none
- **Last Checkpoint:** none
- **Last Commit:** none

## Tasks
PLAN_EOF
create_task_file "TASK-001" "DONE"
ec=0
output=$(bash "$SESSION_SCRIPT" 2>&1) || ec=$?
assert_exit_code "unparseable Status Summary: exit 0 (non-blocking)" "$ec" 0
assert_contains "unparseable Status Summary is flagged" "$output" "no parseable"
teardown_temp_dir

# --- Test 14 (MF-008): group granularity defers the single-task review-gate
# dispatch suggestion to the aggregate review path instead of suggesting a
# premature single-task dispatch for a parked IMPLEMENTED task. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_task_file "TASK-001" "IMPLEMENTED"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_not_contains "MF-008: no single-task review-gate DELEGATE in group mode" \
  "$output" "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for TASK-001"
assert_contains "MF-008: defers to aggregate review path" "$output" "review granularity is group"
teardown_temp_dir

# --- Test 15 (MF-008): task granularity (default) still dispatches per-task ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.review_gate.granularity = "task"'
create_task_file "TASK-001" "IMPLEMENTED"
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "MF-008: task granularity still dispatches per-task review-gate" \
  "$output" "DELEGATE: Spawn review-gate agent (nazgul:review-gate) for TASK-001"
teardown_temp_dir

# --- Test 16 (MF-012): compaction-count lock already claimed (post-compact.sh
# ran first for this event) — SessionStart[compact] must NOT double-increment. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
printf '{"count": 3, "last_compaction_iteration": 5}\n' > "$TEST_DIR/nazgul/.compaction_count"
mkdir -p "$TEST_DIR/nazgul/.compaction_count.lock"
export CLAUDE_HOOK_EVENT="compact"
bash "$SESSION_SCRIPT" >/dev/null 2>&1
val=$(jq -r '.count' "$TEST_DIR/nazgul/.compaction_count")
assert_eq "MF-012: count NOT incremented when lock already claimed" "$val" "3"
unset CLAUDE_HOOK_EVENT
teardown_temp_dir

# --- Test 17 (TASK-006): SessionStart hook JSON payload on stdin resolves the
# real session id — no CLAUDE_SESSION_ID and no prior persisted id, so the
# payload is the only source. Asserted via the persisted .session_id file and
# the session lock filename (both must reflect the payload's real id, not a
# synthetic epoch-pid fallback). ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
PAYLOAD_SID="29ebbe09-4aff-4dfc-b566-e9c9cd41f359"
output=$(printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$PAYLOAD_SID" | bash "$SESSION_SCRIPT" 2>&1)
assert_eq "stdin payload: persisted .session_id is the payload's real id" \
  "$(cat "$TEST_DIR/nazgul/.session_id")" "$PAYLOAD_SID"
assert_file_exists "stdin payload: session lock filed under the real id" \
  "$TEST_DIR/nazgul/sessions/${PAYLOAD_SID}_.lock"
teardown_temp_dir

# --- Test 18 (TASK-006): no payload, no CLAUDE_SESSION_ID, no persisted id —
# the sweep cannot identify the current session, so it is SKIPPED with a
# loud diagnostic and a `skipped`/`unresolved_session_id` JSONL record; the
# hook still exits 0 (never blocks session start on this). ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
unset CLAUDE_SESSION_ID 2>/dev/null || true
ec=0
output=$(bash "$SESSION_SCRIPT" < /dev/null 2>&1) || ec=$?
assert_exit_code "unresolved session id: hook still exits 0" "$ec" 0
assert_contains "unresolved session id: sweep-skipped diagnostic shown" \
  "$output" "Skipped orphaned-team sweep"
assert_eq "unresolved session id: JSONL action is skipped" \
  "$(jq -r '.action' "$TEST_DIR/nazgul/logs/team-sweep.jsonl")" "skipped"
assert_eq "unresolved session id: JSONL reason is unresolved_session_id" \
  "$(jq -r '.reason' "$TEST_DIR/nazgul/logs/team-sweep.jsonl")" "unresolved_session_id"
teardown_temp_dir

# --- Test 19 (TASK-010): stacking disabled + no layers — no stack line ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_not_contains "stacking disabled: no Stack line" "$output" "Stack:"
teardown_temp_dir

# --- Test 20 (TASK-010): old-schema config with no `stack` key at all —
# regression: must still render with no error and no Stack line. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config
jq 'del(.stack) | del(.execution.stacking)' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
  && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
ec=0
output=$(bash "$SESSION_SCRIPT" 2>&1) || ec=$?
assert_exit_code "old-schema stack key: exit 0" "$ec" 0
assert_not_contains "old-schema stack key: no Stack line" "$output" "Stack:"
teardown_temp_dir

# --- Test 21 (TASK-010): stacking enabled, populated registry — Stack line
# present with open count / cap / tip branch / PR number. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.execution.stacking.enabled = true' \
  '.execution.stacking.max_unmerged = 3' \
  '.stack.layers = [
     {"feat_id":"FEAT-026","branch":"feat/FEAT-026","pr":"https://github.com/o/r/pull/79","base":"main","state":"merged","opened_at":"2026-08-01T00:00:00Z","merged_at":"2026-08-02T00:00:00Z"},
     {"feat_id":"FEAT-027","branch":"feat/FEAT-027-stacked-pr","pr":"https://github.com/o/r/pull/80","base":"feat/FEAT-026","state":"open","opened_at":"2026-08-02T00:00:00Z","merged_at":null}
   ]'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "populated registry: Stack line present" "$output" "Stack: 1 open / cap 3"
assert_contains "populated registry: tip branch shown" "$output" "tip: feat/FEAT-027-stacked-pr"
assert_contains "populated registry: tip PR number shown" "$output" "PR #80 open"
teardown_temp_dir

# --- Test 22 (TASK-010): layers present but stacking disabled — line still
# renders (per manifest: enabled OR layers non-empty). ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.execution.stacking.enabled = false' \
  '.stack.layers = [{"feat_id":"FEAT-026","branch":"feat/FEAT-026","pr":null,"base":"main","state":"open","opened_at":"2026-08-01T00:00:00Z","merged_at":null}]'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "layers without enabled: Stack line still present" "$output" "Stack: 1 open"
assert_contains "layer with no PR yet: rendered honestly" "$output" "no PR yet"
teardown_temp_dir

# --- Test 23 (TASK-010): stacking enabled, empty layers — line present
# with zero open count, no tip segment. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.execution.stacking.enabled = true'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "enabled, no layers: Stack line present" "$output" "Stack: 0 open / cap 3"
assert_not_contains "enabled, no layers: no tip segment" "$output" "tip:"
teardown_temp_dir

# --- Test 24 (TASK-010): malformed `.stack` (non-object, e.g. a string) —
# no crash, no Stack line (jq's runtime type error falls through to the
# same fallback path old-schema configs already use). ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.execution.stacking.enabled = true' '.stack = "corrupt"'
ec=0
output=$(bash "$SESSION_SCRIPT" 2>&1) || ec=$?
assert_exit_code "malformed stack: exit 0" "$ec" 0
assert_contains "malformed stack: line present via enabled flag, count falls back to 0" "$output" "Stack: 0 open / cap 3"
teardown_temp_dir

# --- Test 25 (TASK-010): halted flag set — surfaced on the Stack line. ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.execution.stacking.enabled = true' \
  '.execution.stacking.halted = true' \
  '.execution.stacking.halt_reason = "conflict"'
output=$(bash "$SESSION_SCRIPT" 2>&1)
assert_contains "halted: flag surfaced on Stack line" "$output" "HALTED: conflict"
teardown_temp_dir

# --- Test 26 (TASK-005): #104 fix direction (c): over-age in-flight markers quarantined at SessionStart ---
setup_temp_dir
setup_nazgul_dir
create_config
mkdir -p "$TEST_DIR/nazgul/in-flight"
jq -cn '{agent:"nazgul:implementer", unit:"TASK-001", dispatched_at:"2026-08-01T00:00:00Z", dispatched_at_epoch:1000, prompt_hash:"0123456789abcdef", prompt_bytes:1, background:"true", named:"false"}' \
  > "$TEST_DIR/nazgul/in-flight/ancient.json"
NOW=$(date +%s)
jq -cn --argjson e "$NOW" '{agent:"nazgul:implementer", unit:"TASK-002", dispatched_at:"x", dispatched_at_epoch:$e, prompt_hash:"0123456789abcdef", prompt_bytes:1, background:"true", named:"false"}' \
  > "$TEST_DIR/nazgul/in-flight/fresh.json"
(cd "$TEST_DIR" && bash "$SESSION_SCRIPT" </dev/null >/dev/null 2>&1) || true
assert_file_exists "sweep: over-age marker quarantined" "$TEST_DIR/nazgul/in-flight/quarantine/ancient.json"
assert_file_exists "sweep: fresh marker untouched" "$TEST_DIR/nazgul/in-flight/fresh.json"
assert_contains "sweep: in_flight_swept event carries source" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" "session_start_sweep"
assert_contains "sweep: emits in_flight_swept, NOT the proven-class in_flight_orphan (PR #223 review #2)" \
  "$(cat "$TEST_DIR/nazgul/logs/events.jsonl" 2>/dev/null)" '"event":"in_flight_swept"'
teardown_temp_dir

report_results
