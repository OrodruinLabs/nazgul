#!/usr/bin/env bash
set -uo pipefail
TEST_NAME="test-stop-hook-parallel"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
echo "=== $TEST_NAME ==="
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"
run_hook() { HOOK_OUTPUT=$(bash "$STOP_HOOK" 2>&1) && HOOK_EC=0 || HOOK_EC=$?; }

make_parallel_pair() {
  create_task_file TASK-001 READY
  printf -- '- **Files modified**: src/a.sh\n' >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
  create_task_file TASK-002 READY
  printf -- '- **Files modified**: src/b.sh\n' >> "$TEST_DIR/nazgul/tasks/TASK-002.md"
  cat > "$TEST_DIR/nazgul/plan.md" << 'EOF'
# Plan

## Recovery Pointer
- test

## Wave Groups

### Wave 1
- TASK-001, TASK-002 (independent, no file overlap)
EOF
}

# --- 1: parallel on + eligible pair -> batch instruction, exit 2 ---
# NOTE: granularity forced to "task" — the batch-override block (stop-hook.sh)
# only fires for task-granularity READY dispatch (see its comment); the repo
# default (templates/config.json) is "group", so this must be explicit here.
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.execution.max_parallel = 3' '.mode = "afk"' \
  '.review_gate.granularity = "task"'
make_parallel_pair
run_hook
assert_exit_code "parallel: blocks stop" "$HOOK_EC" 2
assert_contains "parallel: batch instruction" "$HOOK_OUTPUT" "DELEGATE (PARALLEL BATCH"
assert_contains "parallel: both tasks named" "$HOOK_OUTPUT" "TASK-002"
assert_contains "parallel: NAZGUL_UNIT contract" "$HOOK_OUTPUT" "NAZGUL_UNIT"
assert_contains "parallel: worktree isolation" "$HOOK_OUTPUT" "worktree"
teardown_temp_dir

# --- 2: parallel off -> sequential instruction byte-identical (regression) ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode = "afk"'
make_parallel_pair
run_hook
assert_exit_code "sequential: blocks stop" "$HOOK_EC" 2
assert_contains "sequential: single-task delegate" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-001."
if printf '%s' "$HOOK_OUTPUT" | grep -q "PARALLEL BATCH"; then
  _fail "sequential: no batch instruction"
else
  _pass "sequential: no batch instruction"
fi
teardown_temp_dir

# --- 3: parallel on + BLOCKED task -> hard stop, exit 0 ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.mode = "afk"'
make_parallel_pair
create_task_file TASK-003 BLOCKED
run_hook
assert_exit_code "hard stop: allows stop" "$HOOK_EC" 0
assert_contains "hard stop: names blocked task" "$HOOK_OUTPUT" "BLOCKED_TASK TASK-003"
teardown_temp_dir

# --- 4: parallel on + approve_batch gate -> instruction carries the gate ---
# Same granularity note as case 1 — the gate text only appears inside the
# batch-override block, which requires task granularity.
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.execution.gates.approve_batch = true' '.mode = "afk"' \
  '.review_gate.granularity = "task"'
make_parallel_pair
run_hook
assert_exit_code "gate: still blocks stop" "$HOOK_EC" 2
assert_contains "gate: approval demanded before dispatch" "$HOOK_OUTPUT" "GATE approve_batch"
teardown_temp_dir

# --- 5: parallel on but overlap -> falls back to sequential instruction ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.mode = "afk"'
create_task_file TASK-001 READY
printf -- '- **Files modified**: src/shared.sh\n' >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
create_task_file TASK-002 READY
printf -- '- **Files modified**: src/shared.sh\n' >> "$TEST_DIR/nazgul/tasks/TASK-002.md"
cat > "$TEST_DIR/nazgul/plan.md" << 'EOF'
# Plan

## Wave Groups

### Wave 1
- TASK-001, TASK-002
EOF
run_hook
assert_exit_code "overlap: blocks stop" "$HOOK_EC" 2
assert_contains "overlap: sequential delegate" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent"
teardown_temp_dir

# --- 6: parallel on + group granularity (default template config) -> degrades
#        to sequential, never batches ---
# Pinned interaction: templates/config.json SHIPS review_gate.granularity =
# "group" (distinct from stop-hook.sh's own absent-key default of "task" — an
# unset key would resolve differently). This fixture sets '.review_gate.granularity
# = "group"' explicitly so it represents the actual default template config
# regardless of what the template ships later, not whatever the key happens to
# default to when omitted. The batch-override block only fires under "task"
# granularity (group/feature granularity owns its own aggregate-review cycle
# instead — see the batch-override comment in stop-hook.sh). A user who flips
# execution.parallel on a default (group-granularity) config should get the
# existing sequential single-task DELEGATE, not a silent no-op — this is
# intended behavior, not a surprise.
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.mode = "afk"' '.review_gate.granularity = "group"'
make_parallel_pair
run_hook
assert_exit_code "group granularity: blocks stop" "$HOOK_EC" 2
assert_contains "group granularity: sequential single-task delegate" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-001."
if printf '%s' "$HOOK_OUTPUT" | grep -q "PARALLEL BATCH"; then
  _fail "group granularity: no batch instruction"
else
  _pass "group granularity: no batch instruction"
fi
teardown_temp_dir

report_results
