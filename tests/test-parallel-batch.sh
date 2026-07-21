#!/usr/bin/env bash
set -uo pipefail
# Test: parallel-batch.sh — batch selection, gates, hard stops (spec §2)

TEST_NAME="test-parallel-batch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/parallel-batch.sh"

# Helper: manifest with Files modified + optional deps
make_task() { # id status deps files
  create_task_file "$1" "$2" "${3:-none}"
  printf -- '- **Files modified**: %s\n' "$4" >> "$TEST_DIR/nazgul/tasks/$1.md"
}

# Helper: plan.md with a Wave Groups section
make_plan_waves() { # lines...
  mkdir -p "$TEST_DIR/nazgul"
  { echo "# Plan"; echo; echo "## Wave Groups"; echo;
    for l in "$@"; do echo "$l"; done; echo; echo "## Other"; } \
    > "$TEST_DIR/nazgul/plan.md"
}

# --- 1: no candidates -> empty, sequential ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 DONE none "a.sh"
make_plan_waves "### Wave 1" "- TASK-001"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "no candidates: empty tasks" "$(jq -r '.tasks|length' <<< "$OUT")" "0"
assert_eq "no candidates: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 2: single READY -> batch of one ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "a.sh"
make_plan_waves "### Wave 1" "- TASK-001"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "single: one task" "$(jq -r '.tasks[0]' <<< "$OUT")" "TASK-001"
assert_eq "single: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 3: dep gating — READY task with non-DONE dep is not a candidate ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 IN_PROGRESS none "a.sh"
make_task TASK-002 READY "TASK-001" "b.sh"
make_task TASK-003 READY none "c.sh"
make_plan_waves "### Wave 1" "- TASK-002, TASK-003 (independent)"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "dep gate: only TASK-003" "$(jq -r '.tasks|join(",")' <<< "$OUT")" "TASK-003"
assert_eq "dep gate: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 4: happy path — 2 grouped candidates, disjoint scopes -> parallel ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh, src/a2.sh"
make_task TASK-002 READY none "src/b.sh"
make_plan_waves "### Wave 1" "- TASK-001, TASK-002 (independent, no file overlap)"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "happy: parallel true" "$(jq -r '.parallel' <<< "$OUT")" "true"
assert_eq "happy: both tasks in order" "$(jq -r '.tasks|join(",")' <<< "$OUT")" "TASK-001,TASK-002"
teardown_temp_dir

# --- 5: overlap -> fallback to single ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh, src/shared.sh"
make_task TASK-002 READY none "src/shared.sh"
make_plan_waves "### Wave 1" "- TASK-001, TASK-002"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "overlap: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
assert_eq "overlap: single task" "$(jq -r '.tasks|length' <<< "$OUT")" "1"
assert_contains "overlap: reason says overlap" "$OUT" "overlap"
teardown_temp_dir

# --- 6: missing Files modified -> fallback to single ---
setup_temp_dir; setup_nazgul_dir
create_task_file TASK-001 READY   # no Files modified
make_task TASK-002 READY none "src/b.sh"
make_plan_waves "### Wave 1" "- TASK-001, TASK-002"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "no scope: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 7: no Wave Groups section -> fallback to single ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh"
make_task TASK-002 READY none "src/b.sh"
echo "# Plan (no waves)" > "$TEST_DIR/nazgul/plan.md"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "no waves: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 8: candidates on DIFFERENT wave lines are never batched together ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh"
make_task TASK-002 READY none "src/b.sh"
make_plan_waves "### Wave 1" "- TASK-001" "### Wave 2" "- TASK-002"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 3)
assert_eq "separate lines: not parallel" "$(jq -r '.parallel' <<< "$OUT")" "false"
teardown_temp_dir

# --- 9: max_parallel caps the batch ---
setup_temp_dir; setup_nazgul_dir
make_task TASK-001 READY none "src/a.sh"
make_task TASK-002 READY none "src/b.sh"
make_task TASK-003 READY none "src/c.sh"
make_plan_waves "### Wave 1" "- TASK-001, TASK-002, TASK-003 (independent)"
OUT=$(compute_dispatch_batch "$TEST_DIR/nazgul/tasks" "$TEST_DIR/nazgul/plan.md" 2)
assert_eq "cap: batch of 2" "$(jq -r '.tasks|length' <<< "$OUT")" "2"
assert_eq "cap: still parallel" "$(jq -r '.parallel' <<< "$OUT")" "true"
teardown_temp_dir

# --- 10: gates — defaults + hitl flip for approve_plan only ---
setup_temp_dir; setup_nazgul_dir; create_config
CONFIG="$TEST_DIR/nazgul/config.json"
assert_eq "gate default: approve_batch false" "$(execution_gate_stored "$CONFIG" approve_batch)" "false"
assert_eq "gate hitl: approve_plan effective true" "$(execution_gate_effective "$CONFIG" approve_plan hitl)" "true"
assert_eq "gate hitl: approve_batch stays false" "$(execution_gate_effective "$CONFIG" approve_batch hitl)" "false"
assert_eq "parallel default: false" "$(execution_parallel_enabled "$CONFIG")" "false"
assert_eq "max_parallel default: 3" "$(execution_max_parallel "$CONFIG")" "3"
teardown_temp_dir

# --- 11: hard stops — BLOCKED task halts ---
setup_temp_dir; setup_nazgul_dir
create_task_file TASK-001 BLOCKED
if OUT=$(execution_should_halt "$TEST_DIR/nazgul"); then
  _fail "hard stop: should return non-zero on BLOCKED"
else
  _pass "hard stop: non-zero on BLOCKED"
fi
assert_contains "hard stop: names task" "$OUT" "BLOCKED_TASK TASK-001"
teardown_temp_dir

# --- 12: compute_waves moved — Kahn layering works from tasks dir ---
setup_temp_dir; setup_nazgul_dir
create_task_file TASK-001 READY
create_task_file TASK-002 READY "TASK-001"
WAVES=$(compute_waves "$TEST_DIR/nazgul/tasks")
assert_eq "waves: TASK-001 in wave 1" "$(jq -r '.[0].units[0]' <<< "$WAVES")" "TASK-001"
assert_eq "waves: TASK-002 in wave 2" "$(jq -r '.[1].units[0]' <<< "$WAVES")" "TASK-002"
teardown_temp_dir

# --- 13: compute_waves rejects a cycle rather than looping (ported from the
# deleted tests/test-conductor-waves.sh Test 6) ---
setup_temp_dir; setup_nazgul_dir
create_task_file TASK-001 READY TASK-002
create_task_file TASK-002 READY TASK-001
WAVES_ERRFILE=$(mktemp)
WAVES_OUT=$(compute_waves "$TEST_DIR/nazgul/tasks" 2>"$WAVES_ERRFILE") && WAVES_EC=0 || WAVES_EC=$?
WAVES_ERR=$(cat "$WAVES_ERRFILE" 2>/dev/null); rm -f "$WAVES_ERRFILE"
assert_exit_code "cycle: non-zero exit" "$WAVES_EC" 1
assert_contains "cycle: stderr mentions cycle" "$WAVES_ERR" "cycle"
teardown_temp_dir

# --- 14: compute_waves rejects an unknown dependency id rather than dropping
# it silently (ported from the deleted tests/test-conductor-waves.sh Test 9) ---
setup_temp_dir; setup_nazgul_dir
create_task_file TASK-001 READY TASK-999
WAVES_ERRFILE=$(mktemp)
WAVES_OUT=$(compute_waves "$TEST_DIR/nazgul/tasks" 2>"$WAVES_ERRFILE") && WAVES_EC=0 || WAVES_EC=$?
WAVES_ERR=$(cat "$WAVES_ERRFILE" 2>/dev/null); rm -f "$WAVES_ERRFILE"
assert_exit_code "unknown dep: non-zero exit" "$WAVES_EC" 1
assert_contains "unknown dep: stderr names unknown dependency" "$WAVES_ERR" "unknown dependency"
teardown_temp_dir

report_results
