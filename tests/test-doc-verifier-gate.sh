#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

TEST_NAME="test-doc-verifier-gate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# Helper: create a docs dir with at least one .md file
create_docs_with_md() {
  mkdir -p "$TEST_DIR/nazgul/docs"
  printf '# Doc\n' > "$TEST_DIR/nazgul/docs/TRD.md"
}

# --- Test DV-1: opt-out (docs.verify_post_loop=false) — no-op, exit 0, no marker ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV1"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs = {"verify_post_loop": false, "verify_comments": false}' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_docs_with_md
run_hook
assert_exit_code "DV-1: opt-out → exit 0" "$HOOK_EC" 0
assert_file_not_exists "DV-1: no marker when opted out" "$TEST_DIR/nazgul/logs/.docs-verified"
assert_not_contains "DV-1: no decision JSON when opted out" "$HOOK_OUTPUT" '"decision"'
teardown_temp_dir

# --- Test DV-2: docs dir absent — degrade-to-allow, marker written, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV2"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
rm -rf "$TEST_DIR/nazgul/docs"
run_hook
assert_exit_code "DV-2: no docs dir → degrade exit 0" "$HOOK_EC" 0
assert_file_exists "DV-2: marker written on degrade (absent dir)" "$TEST_DIR/nazgul/logs/.docs-verified"
assert_eq "DV-2: marker contains feat_id" "$(cat "$TEST_DIR/nazgul/logs/.docs-verified")" "FEAT-DV2"
teardown_temp_dir

# --- Test DV-3: docs dir present but no .md files — degrade-to-allow, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV3"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/docs"
printf 'placeholder\n' > "$TEST_DIR/nazgul/docs/notes.txt"
run_hook
assert_exit_code "DV-3: docs dir but no .md → degrade exit 0" "$HOOK_EC" 0
assert_file_exists "DV-3: marker written on degrade (no .md)" "$TEST_DIR/nazgul/logs/.docs-verified"
assert_eq "DV-3: marker contains feat_id" "$(cat "$TEST_DIR/nazgul/logs/.docs-verified")" "FEAT-DV3"
teardown_temp_dir

# --- Test DV-4: docs exist, marker absent — block, exit 2, DELEGATE on stderr ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV4"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_docs_with_md
run_hook
assert_exit_code "DV-4: marker absent + docs → exit 2" "$HOOK_EC" 2
assert_contains "DV-4: decision block in stdout" "$HOOK_OUTPUT" '"decision": "block"'
assert_contains "DV-4: reason mentions feat_id" "$HOOK_OUTPUT" "FEAT-DV4"
assert_contains "DV-4: DELEGATE instruction emitted" "$HOOK_OUTPUT" "nazgul:doc-verifier"
assert_file_exists "DV-4: attempts file created" "$TEST_DIR/nazgul/logs/.docs-verify-attempts"
assert_contains "DV-4: attempts scoped to feat_id" "$(cat "$TEST_DIR/nazgul/logs/.docs-verify-attempts")" "FEAT-DV4"
teardown_temp_dir

# --- Test DV-5: marker matches feat_id — pass immediately, exit 0 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV5"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_docs_with_md
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-DV5" > "$TEST_DIR/nazgul/logs/.docs-verified"
run_hook
assert_exit_code "DV-5: marker matches → exit 0" "$HOOK_EC" 0
# A passing run emits no decision-block JSON at all; match the actual jq output
# (pretty-printed with a space after the colon — the compact needle never matched).
assert_not_contains "DV-5: no block when marker matches" "$HOOK_OUTPUT" '"decision": "block"'
teardown_temp_dir

# --- Test DV-6: stale marker (different feat_id) — re-gates, exit 2 ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV6"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_docs_with_md
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' "FEAT-STALE" > "$TEST_DIR/nazgul/logs/.docs-verified"
run_hook
assert_exit_code "DV-6: stale marker → exit 2" "$HOOK_EC" 2
assert_contains "DV-6: decision block for stale marker" "$HOOK_OUTPUT" '"decision": "block"'
teardown_temp_dir

# --- Test DV-7: attempts increment 0→1→2 (still blocking) ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV7"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_docs_with_md
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-DV7" "2" > "$TEST_DIR/nazgul/logs/.docs-verify-attempts"
run_hook
assert_exit_code "DV-7: attempts=2 → still exit 2" "$HOOK_EC" 2
assert_eq "DV-7: attempts incremented to 3" \
  "$(awk '{print $2}' "$TEST_DIR/nazgul/logs/.docs-verify-attempts")" "3"
teardown_temp_dir

# --- Test DV-8: backstop (attempts≥3) — completes with warning, exit 0, marker written ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV8"' \
  '.learning.auto_distill_post_loop = false' \
  '.docs.verify_comments = false' \
  '.self_audit.enabled = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_docs_with_md
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s %s\n' "FEAT-DV8" "3" > "$TEST_DIR/nazgul/logs/.docs-verify-attempts"
run_hook
assert_exit_code "DV-8: backstop → exit 0" "$HOOK_EC" 0
assert_contains "DV-8: backstop warns" "$HOOK_OUTPUT" "gave up"
assert_file_exists "DV-8: backstop writes marker" "$TEST_DIR/nazgul/logs/.docs-verified"
assert_eq "DV-8: backstop marker contains feat_id" \
  "$(cat "$TEST_DIR/nazgul/logs/.docs-verified")" "FEAT-DV8"
teardown_temp_dir

# --- Test DV-9: attempts reset when feat_id changes ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config \
  '.agents.reviewers = ["code-reviewer"]' \
  '.feat_id = "FEAT-DV9"' \
  '.learning.auto_distill_post_loop = false'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
create_docs_with_md
mkdir -p "$TEST_DIR/nazgul/logs"
# attempts file belongs to a different objective
printf '%s %s\n' "FEAT-OLD" "3" > "$TEST_DIR/nazgul/logs/.docs-verify-attempts"
run_hook
# Old attempts (3) belonged to different obj — counter resets to 0, so this attempt = 1 → still blocks
assert_exit_code "DV-9: reset attempts on new feat_id → exit 2" "$HOOK_EC" 2
assert_eq "DV-9: attempts written as 1 after reset" \
  "$(awk '{print $2}' "$TEST_DIR/nazgul/logs/.docs-verify-attempts")" "1"
assert_eq "DV-9: attempts scoped to new feat_id" \
  "$(awk '{print $1}' "$TEST_DIR/nazgul/logs/.docs-verify-attempts")" "FEAT-DV9"
teardown_temp_dir

report_results
