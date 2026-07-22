#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

TEST_NAME="test-comment-verifier-gate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
# get_task_status: frontmatter-first status reader (matches production, unlike a
# raw legacy-list-item grep) — used below to read back manifests the hook wrote.
source "$REPO_ROOT/scripts/lib/task-utils.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# setup_git_repo leaves HEAD~1..HEAD non-empty (README.md added in 2nd commit),
# so the default fixture always has "source changed". Pin branch.base to HEAD to
# exercise the degrade-to-allow (no source changed) path deterministically.
pin_base_to_head() {
  local sha
  sha=$(git -C "$TEST_DIR" rev-parse HEAD)
  jq --arg b "$sha" '.branch.base = $b' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
    && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
}

# --- Test CV-1: opt-out (docs.verify_comments=false) — no-op, exit 0, no marker ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV1"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
run_hook
assert_exit_code "CV-1: opt-out → exit 0" "$HOOK_EC" 0
assert_file_not_exists "CV-1: no marker when opted out" "$TEST_DIR/nazgul/logs/.comments-verified"
assert_not_contains "CV-1: no decision JSON when opted out" "$HOOK_OUTPUT" "comment-verifier gate"
teardown_temp_dir

# --- Test CV-2: no source files changed — degrade-to-allow, marker written, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV2"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
pin_base_to_head
run_hook
assert_exit_code "CV-2: no source changed → degrade exit 0" "$HOOK_EC" 0
assert_file_exists "CV-2: marker written on degrade" "$TEST_DIR/nazgul/logs/.comments-verified"
assert_eq "CV-2: marker contains feat_id" "$(cat "$TEST_DIR/nazgul/logs/.comments-verified")" "FEAT-CV2"
teardown_temp_dir

# --- Test CV-3: only doc/config files changed — degrade-to-allow, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV3"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
pin_base_to_head
mkdir -p "$TEST_DIR/docs"
echo "notes" > "$TEST_DIR/docs/notes.md"
git -C "$TEST_DIR" add docs/notes.md
git -C "$TEST_DIR" commit -q -m "docs only"
run_hook
assert_exit_code "CV-3: doc-only change → degrade exit 0" "$HOOK_EC" 0
assert_file_exists "CV-3: marker written on degrade (doc-only)" "$TEST_DIR/nazgul/logs/.comments-verified"
teardown_temp_dir

# --- Test CV-4: source changed, marker absent — block, exit 2, DELEGATE on stderr ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV4"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
run_hook
assert_exit_code "CV-4: marker absent + source changed → exit 2" "$HOOK_EC" 2
assert_contains "CV-4: decision block in stdout" "$HOOK_OUTPUT" '"decision": "block"'
assert_contains "CV-4: reason mentions feat_id" "$HOOK_OUTPUT" "FEAT-CV4"
assert_contains "CV-4: DELEGATE instruction emitted" "$HOOK_OUTPUT" "nazgul:comment-verifier"
assert_file_exists "CV-4: attempts file created" "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
assert_contains "CV-4: attempts scoped to feat_id" "$(cat "$TEST_DIR/nazgul/logs/.comments-verify-attempts")" "FEAT-CV4"
teardown_temp_dir

# --- Test CV-5: marker matches feat_id — pass immediately, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV5"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-CV5" > "$TEST_DIR/nazgul/logs/.comments-verified"
run_hook
assert_exit_code "CV-5: marker matches → exit 0" "$HOOK_EC" 0
assert_not_contains "CV-5: no block when marker matches" "$HOOK_OUTPUT" "comment-verifier gate: comments not yet verified"
teardown_temp_dir

# --- Test CV-6: stale marker (different feat_id) — re-gates, exit 2 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV6"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-STALE" > "$TEST_DIR/nazgul/logs/.comments-verified"
run_hook
assert_exit_code "CV-6: stale marker → exit 2" "$HOOK_EC" 2
assert_contains "CV-6: decision block for stale marker" "$HOOK_OUTPUT" '"decision": "block"'
teardown_temp_dir

# --- Test CV-7: attempts increment 0→1→2 (still blocking) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV7"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-CV7" "2" > "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
run_hook
assert_exit_code "CV-7: attempts=2 → still exit 2" "$HOOK_EC" 2
assert_eq "CV-7: attempts incremented to 3" \
  "$(awk '{print $2}' "$TEST_DIR/nazgul/logs/.comments-verify-attempts")" "3"
teardown_temp_dir

# --- Test CV-8: backstop (attempts≥3) — completes with warning, exit 0, marker written ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV8"' \
  '.learning.auto_distill_post_loop = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-CV8" "3" > "$TEST_DIR/nazgul/logs/.comments-verify-attempts"
run_hook
assert_exit_code "CV-8: backstop → exit 0" "$HOOK_EC" 0
assert_contains "CV-8: backstop warns" "$HOOK_OUTPUT" "gave up"
assert_file_exists "CV-8: backstop writes marker" "$TEST_DIR/nazgul/logs/.comments-verified"
assert_eq "CV-8: backstop marker contains feat_id" \
  "$(cat "$TEST_DIR/nazgul/logs/.comments-verified")" "FEAT-CV8"
teardown_temp_dir

# --- Test CV-9: reset-counter split — provenance-only violation after an evidence
# violation gets its own grace reset instead of jumping straight to BLOCKED ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
source "$REPO_ROOT/scripts/lib/review-provenance.sh"
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-CV9"' \
  '.learning.auto_distill_post_loop = false' \
  '.safety._review_reset_counts = {"TASK-001": 1}'
create_plan
create_task_file "TASK-001" "DONE"
create_task_file "TASK-002" "READY"
DIFF="$TEST_DIR/nazgul/reviews/TASK-001/diff.patch"
mkdir -p "$(dirname "$DIFF")"
printf 'diff content\n' > "$DIFF"
# Manifest token is intentionally NOT stamped into the reviewer file below —
# this simulates a genuine TOKEN_MISMATCH provenance violation.
write_dispatch_manifest "$TEST_DIR/nazgul" "TASK-001" "$DIFF" "FEAT-CV9" "1" -- code-reviewer >/dev/null
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: APPROVE\nreview_token: %s\n---\nLooks good.\n' "deadbeef" \
  > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
run_hook
# Evidence is valid (token stamped, roster satisfied) but the token doesn't match the
# manifest's, so this is a genuinely-first PROVENANCE violation. A pre-existing stale
# evidence reset count (1) must not escalate it straight to BLOCKED.
assert_exit_code "CV-9: independent ladder → exit 2 (reset, not BLOCKED)" "$HOOK_EC" 2
assert_contains "CV-9: names provenance" "$HOOK_OUTPUT" "review provenance invalid"
status=$(get_task_status "$TEST_DIR/nazgul/tasks/TASK-001.md")
assert_eq "CV-9: reset to IMPLEMENTED, not escalated" "$status" "IMPLEMENTED"
prov_count=$(jq -r '.safety._provenance_reset_counts["TASK-001"] // 0' "$TEST_DIR/nazgul/config.json")
assert_eq "CV-9: provenance counter starts its own ladder at 1" "$prov_count" "1"
# Evidence passed to reach the provenance branch, so its stale counter must be
# cleared here — leaving it would over-escalate a later, genuinely-first evidence
# violation straight to BLOCKED.
evid_count=$(jq -r 'if (.safety._review_reset_counts | has("TASK-001")) then .safety._review_reset_counts["TASK-001"] else "absent" end' "$TEST_DIR/nazgul/config.json")
assert_eq "CV-9: stale evidence counter cleared on provenance branch" "$evid_count" "absent"
teardown_temp_dir

report_results
