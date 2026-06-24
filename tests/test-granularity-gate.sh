#!/usr/bin/env bash
set -uo pipefail

TEST_NAME="test-granularity-gate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"

run_hook() {
  HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# --- BLOCK mode: violation blocks completion ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG1"' \
  '.review_gate.granularity = "group"' \
  '.review_gate.enforce_granularity = "block"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
# Coverage file: task reviewed at "task" granularity but config is "group" — violation
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' '{"sv":1,"ts":"2026-06-24T00:00:00Z","task_id":"TASK-001","review_unit":"TASK-001","granularity_used":"task","iteration":1}' \
  > "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
run_hook
assert_exit_code "violation + block mode: exit 2" "$HOOK_EC" 2
assert_contains "violation names offending task" "$HOOK_OUTPUT" "TASK-001"
assert_contains "violation references configured granularity" "$HOOK_OUTPUT" "group"
assert_contains "decision block JSON emitted" "$HOOK_OUTPUT" '"decision"'
assert_file_exists "attempts file created" "$TEST_DIR/nazgul/logs/.granularity-attempts"
assert_contains "attempts scoped to objective" "$(cat "$TEST_DIR/nazgul/logs/.granularity-attempts")" "FEAT-GG1"
teardown_temp_dir

# --- BLOCK mode: compliant coverage passes ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG2"' \
  '.review_gate.granularity = "group"' \
  '.review_gate.enforce_granularity = "block"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' '{"sv":1,"ts":"2026-06-24T00:00:00Z","task_id":"TASK-001","review_unit":"GROUP-1","granularity_used":"group","iteration":1}' \
  > "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
run_hook
assert_exit_code "compliant coverage: exit 0" "$HOOK_EC" 0
assert_file_exists "marker written on clean pass" "$TEST_DIR/nazgul/logs/.granularity-checked"
assert_contains "marker scoped to objective" "$(cat "$TEST_DIR/nazgul/logs/.granularity-checked")" "FEAT-GG2"
teardown_temp_dir

# --- Missing coverage file degrades to allow ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG3"' \
  '.review_gate.granularity = "group"' \
  '.review_gate.enforce_granularity = "block"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
# No review-coverage.jsonl — gate must degrade to allow
run_hook
assert_exit_code "missing coverage file: exit 0 (degrade)" "$HOOK_EC" 0
teardown_temp_dir

# --- WARN mode: violation warns but allows ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG4"' \
  '.review_gate.granularity = "group"' \
  '.review_gate.enforce_granularity = "warn"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' '{"sv":1,"ts":"2026-06-24T00:00:00Z","task_id":"TASK-001","review_unit":"TASK-001","granularity_used":"task","iteration":1}' \
  > "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
run_hook
assert_exit_code "warn mode + violation: exit 0" "$HOOK_EC" 0
assert_contains "warn mode emits warning text" "$HOOK_OUTPUT" "GRANULARITY WARNING"
assert_file_exists "warn mode writes marker" "$TEST_DIR/nazgul/logs/.granularity-checked"
teardown_temp_dir

# --- Backstop: 3 recorded attempts allows through ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG5"' \
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
printf '%s %s\n' "FEAT-GG5" "3" > "$TEST_DIR/nazgul/logs/.granularity-attempts"
run_hook
assert_exit_code "backstop exhausted: exit 0" "$HOOK_EC" 0
assert_contains "backstop emits warning" "$HOOK_OUTPUT" "gave up"
assert_file_exists "backstop writes marker" "$TEST_DIR/nazgul/logs/.granularity-checked"
teardown_temp_dir

# --- Marker present for same objective: gate skips ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG6"' \
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
printf '%s\n' "FEAT-GG6" > "$TEST_DIR/nazgul/logs/.granularity-checked"
run_hook
assert_exit_code "marker present: gate skips, exit 0" "$HOOK_EC" 0
assert_not_contains "marker present: no block JSON" "$HOOK_OUTPUT" '"decision"'
teardown_temp_dir

# --- Stale marker (different objective) re-gates ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG7"' \
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
printf '%s\n' "FEAT-STALE" > "$TEST_DIR/nazgul/logs/.granularity-checked"
run_hook
assert_exit_code "stale marker: re-gates, exit 2" "$HOOK_EC" 2
assert_contains "stale marker: decision block emitted" "$HOOK_OUTPUT" '"decision"'
teardown_temp_dir

# --- Default (absent enforce_granularity): treated as block ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG8"' \
  '.review_gate.granularity = "group"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]'
# Remove enforce_granularity so it falls back to default "block"
jq 'del(.review_gate.enforce_granularity)' "$TEST_DIR/nazgul/config.json" \
  > "$TEST_DIR/nazgul/config.json.tmp" \
  && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
printf '%s\n' '{"sv":1,"ts":"2026-06-24T00:00:00Z","task_id":"TASK-001","review_unit":"TASK-001","granularity_used":"task","iteration":1}' \
  > "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
run_hook
assert_exit_code "absent enforce_granularity defaults to block: exit 2" "$HOOK_EC" 2
teardown_temp_dir

# --- Stale record from ANOTHER objective must NOT block this one ---
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.feat_id = "FEAT-GG9"' \
  '.review_gate.granularity = "group"' \
  '.review_gate.enforce_granularity = "block"' \
  '.learning.auto_distill_post_loop = false' \
  '.agents.reviewers = ["code-reviewer"]'
create_plan
create_task_file "TASK-001" "DONE"
create_review_dir "TASK-001"
mkdir -p "$TEST_DIR/nazgul/logs"
# A violating record, but stamped with a DIFFERENT objective's feat_id — the
# gate must ignore it and complete cleanly (no false block).
printf '%s\n' '{"sv":1,"ts":"2026-06-24T00:00:00Z","feat_id":"FEAT-OTHER","task_id":"TASK-001","review_unit":"TASK-001","granularity_used":"task","iteration":1}' \
  > "$TEST_DIR/nazgul/logs/review-coverage.jsonl"
run_hook
assert_exit_code "foreign-objective coverage record does not block: exit 0" "$HOOK_EC" 0
teardown_temp_dir

report_results
