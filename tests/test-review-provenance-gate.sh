#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: stop-hook.sh DONE-gate wiring for validate_review_provenance (Gap A)
TEST_NAME="test-review-provenance-gate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/lib/review-provenance.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

task_status() {
  grep -m1 '^\- \*\*Status\*\*:' "$TEST_DIR/nazgul/tasks/$1.md" | sed 's/.*: //'
}

# Helper: reviewer file stamped with a review_token (mirrors review-gate's persist step)
# Usage: write_review_token TASK-001 code-reviewer <token>
write_review_token() {
  local unit="$1" name="$2" token="$3"
  mkdir -p "$TEST_DIR/nazgul/reviews/$unit"
  printf -- '---\nverdict: APPROVE\nreview_token: %s\n---\nLooks good.\n' "$token" \
    > "$TEST_DIR/nazgul/reviews/$unit/$name.md"
}

# --- PG-1: valid manifest + matching stamped token → stays DONE ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-PG1"'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
DIFF="$TEST_DIR/nazgul/reviews/TASK-001/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
TOKEN=$(write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "$DIFF" "FEAT-PG1" "1" -- code-reviewer)
write_review_token "TASK-001" "code-reviewer" "$TOKEN"
run_hook
assert_eq "PG-1: valid provenance stays DONE" "$(task_status TASK-001)" "DONE"
assert_not_contains "PG-1: no violation noise" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
teardown_temp_dir

# --- PG-2: stamped token but manifest missing, require_provenance=true → reset then BLOCKED ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-PG2"' '.review_gate.require_provenance = true'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
write_review_token "TASK-001" "code-reviewer" "deadbeefdeadbeef"
run_hook
assert_exit_code "PG-2 first violation: exit 2" "$HOOK_EC" 2
assert_contains "PG-2 first violation: logged" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
assert_contains "PG-2 first violation: names provenance" "$HOOK_OUTPUT" "review provenance invalid"
assert_eq "PG-2 first violation: reset to IMPLEMENTED" "$(task_status TASK-001)" "IMPLEMENTED"
count=$(jq -r '.safety._review_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "PG-2 first violation: reset count recorded" "$count" "1"

# Second consecutive run: task is back at DONE (simulating a re-completion without fixing
# provenance) with the reset counter still set — escalates to BLOCKED.
set_task_status_helper() {
  sed -i.bak "s/^- \*\*Status\*\*:.*/- **Status**: $2/" "$TEST_DIR/nazgul/tasks/$1.md" \
    && rm -f "$TEST_DIR/nazgul/tasks/$1.md.bak"
}
set_task_status_helper "TASK-001" "DONE"
run_hook
assert_exit_code "PG-2 second violation: exit 2" "$HOOK_EC" 2
assert_contains "PG-2 second violation: escalated" "$HOOK_OUTPUT" "escalated to BLOCKED"
assert_eq "PG-2 second violation: escalated to BLOCKED" "$(task_status TASK-001)" "BLOCKED"
assert_contains "PG-2 second violation: blocked reason names remedy" \
  "$(cat "$TEST_DIR/nazgul/tasks/TASK-001.md")" "re-run review-gate"
count=$(jq -r '.safety._review_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "PG-2 second violation: count cleared" "$count" "0"
teardown_temp_dir

# --- PG-3: require_provenance=false → invalid provenance ignored, DONE preserved ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-PG3"' '.review_gate.require_provenance = false'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
write_review_token "TASK-001" "code-reviewer" "deadbeefdeadbeef"
run_hook
assert_eq "PG-3 opt-out: stays DONE" "$(task_status TASK-001)" "DONE"
assert_not_contains "PG-3 opt-out: no violation noise" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
teardown_temp_dir

# --- PG-4: legacy review (no token, no manifest) → degrade-to-allow, DONE preserved ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-PG4"'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
create_review_dir "TASK-001"
run_hook
assert_eq "PG-4 legacy: stays DONE" "$(task_status TASK-001)" "DONE"
assert_not_contains "PG-4 legacy: no violation noise" "$HOOK_OUTPUT" "REVIEW GATE VIOLATION"
teardown_temp_dir

# --- PG-5: DIFF_HASH_STALE (diff mutated after the manifest was written) → reset then BLOCKED ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-PG5"'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
DIFF="$TEST_DIR/nazgul/reviews/TASK-001/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'original diff\n' > "$DIFF"
TOKEN=$(write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "$DIFF" "FEAT-PG5" "1" -- code-reviewer)
write_review_token "TASK-001" "code-reviewer" "$TOKEN"
printf 'mutated diff after review\n' > "$DIFF"
run_hook
assert_exit_code "PG-5 first violation: exit 2" "$HOOK_EC" 2
assert_contains "PG-5 first violation: names provenance" "$HOOK_OUTPUT" "review provenance invalid"
assert_eq "PG-5 first violation: reset to IMPLEMENTED" "$(task_status TASK-001)" "IMPLEMENTED"

set_task_status_helper "TASK-001" "DONE"
run_hook
assert_eq "PG-5 second violation: escalated to BLOCKED" "$(task_status TASK-001)" "BLOCKED"
teardown_temp_dir

# --- PG-6: group-mode co-location — task-keyed dir works identically under granularity=group ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-PG6"' '.review_gate.granularity = "group"'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
DIFF="$TEST_DIR/nazgul/reviews/TASK-001/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
TOKEN=$(write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "$DIFF" "FEAT-PG6" "1" -- code-reviewer)
write_review_token "TASK-001" "code-reviewer" "$TOKEN"
run_hook
assert_eq "PG-6 group co-located manifest: stays DONE" "$(task_status TASK-001)" "DONE"
teardown_temp_dir

setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.agents.reviewers = ["code-reviewer"]' '.feat_id = "FEAT-PG6B"' '.review_gate.granularity = "group"'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
write_review_token "TASK-001" "code-reviewer" "deadbeefdeadbeef"   # token, no manifest
run_hook
assert_eq "PG-6 group manifest absent: resets to IMPLEMENTED" "$(task_status TASK-001)" "IMPLEMENTED"
teardown_temp_dir

report_results
