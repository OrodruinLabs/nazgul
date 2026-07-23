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
  printf -- '- **Files modified**: ["src/a.sh"]\n' >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
  create_task_file TASK-002 READY
  printf -- '- **Files modified**: ["src/b.sh"]\n' >> "$TEST_DIR/nazgul/tasks/TASK-002.md"
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
assert_contains "batch dispatch carries report contract" "$HOOK_OUTPUT" "Report Contract"
teardown_temp_dir

# --- 1b: WS3 reorder — DISPATCH_INSTR text places record-SHA+IMPLEMENTED and
#         the review-gate dispatch BEFORE any git merge --no-ff text, and the
#         merge step is explicitly gated on Status: DONE (FEAT-016 HIGH: the
#         old merge-first order left no manifest entry for the H2 guard to
#         match at merge time). Also asserts the WS2 (LR-002) DELEGATE-text
#         restatement of the models.review_orchestrator tier.
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.execution.max_parallel = 3' '.mode = "afk"' \
  '.review_gate.granularity = "task"'
make_parallel_pair
run_hook
OFFSET_IMPLEMENTED=$(grep -abo "set Status: IMPLEMENTED" <<<"$HOOK_OUTPUT" | head -1 | cut -d: -f1)
OFFSET_REVIEWGATE=$(grep -abo "Dispatch ONE review-gate agent (nazgul:review-gate) PER task" <<<"$HOOK_OUTPUT" | head -1 | cut -d: -f1)
OFFSET_MERGE=$(grep -abo "git merge --no-ff" <<<"$HOOK_OUTPUT" | head -1 | cut -d: -f1)
if [ -n "$OFFSET_IMPLEMENTED" ] && [ -n "$OFFSET_REVIEWGATE" ] && [ -n "$OFFSET_MERGE" ] \
   && [ "$OFFSET_IMPLEMENTED" -lt "$OFFSET_REVIEWGATE" ] && [ "$OFFSET_REVIEWGATE" -lt "$OFFSET_MERGE" ]; then
  _pass "WS3 reorder: record-SHA+IMPLEMENTED -> review-gate dispatch -> git merge --no-ff"
else
  _fail "WS3 reorder: record-SHA+IMPLEMENTED -> review-gate dispatch -> git merge --no-ff" \
    "offsets: IMPLEMENTED=$OFFSET_IMPLEMENTED review-gate=$OFFSET_REVIEWGATE merge=$OFFSET_MERGE"
fi
assert_contains "WS3 reorder: merge explicitly gated on Status: DONE" "$HOOK_OUTPUT" "ONLY a task whose manifest reaches Status: DONE"
assert_contains "WS3 reorder: CHANGES_REQUESTED/BLOCKED task gets no merge instruction" "$HOOK_OUTPUT" "A task at CHANGES_REQUESTED or BLOCKED is NOT merged"
assert_contains "WS2 (LR-002): batch review-gate dispatch restates review_orchestrator tier" "$HOOK_OUTPUT" "models.review_orchestrator (default sonnet) — never inherit a lower tier from the calling context"
teardown_temp_dir

# --- 2: parallel off -> sequential instruction byte-identical (regression) ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.mode = "afk"'
make_parallel_pair
run_hook
assert_exit_code "sequential: blocks stop" "$HOOK_EC" 2
assert_contains "sequential: single-task delegate" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent (nazgul:implementer) for TASK-001."
assert_contains "sequential: Active task line present" "$HOOK_OUTPUT" "Active task: nazgul/tasks/TASK-001.md (READY)"
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
# NOTE: granularity forced to "task" — without this GRANULARITY resolves to
# the template's "group" default, the batch-override block never runs, and
# this test would duplicate case 2 instead of exercising compute_dispatch_batch's
# overlap fallback through the stop-hook (same reasoning as cases 1/4).
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.mode = "afk"' '.review_gate.granularity = "task"'
create_task_file TASK-001 READY
printf -- '- **Files modified**: ["src/shared.sh"]\n' >> "$TEST_DIR/nazgul/tasks/TASK-001.md"
create_task_file TASK-002 READY
printf -- '- **Files modified**: ["src/shared.sh"]\n' >> "$TEST_DIR/nazgul/tasks/TASK-002.md"
cat > "$TEST_DIR/nazgul/plan.md" << 'EOF'
# Plan

## Wave Groups

### Wave 1
- TASK-001, TASK-002
EOF
run_hook
assert_exit_code "overlap: blocks stop" "$HOOK_EC" 2
assert_contains "overlap: sequential delegate" "$HOOK_OUTPUT" "DELEGATE: Spawn implementer agent"
if printf '%s' "$HOOK_OUTPUT" | grep -q "PARALLEL BATCH"; then
  _fail "overlap: no batch instruction"
else
  _pass "overlap: no batch instruction"
fi
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

# --- 7: parallel batch fires while an earlier-glob-order READY task exists
#        outside the batch's wave line -> Active task line must not name it,
#        and must instead reflect the batch (or be suppressed) ---
setup_temp_dir; setup_git_repo; setup_nazgul_dir
create_config '.execution.parallel = true' '.execution.max_parallel = 3' '.mode = "afk"' \
  '.review_gate.granularity = "task"'
create_task_file TASK-000 READY
printf -- '- **Files modified**: ["src/z.sh"]\n' >> "$TEST_DIR/nazgul/tasks/TASK-000.md"
make_parallel_pair
run_hook
assert_exit_code "batch+outsider: blocks stop" "$HOOK_EC" 2
assert_contains "batch+outsider: batch instruction fires" "$HOOK_OUTPUT" "DELEGATE (PARALLEL BATCH"
if printf '%s' "$HOOK_OUTPUT" | grep -q "Active task: nazgul/tasks/TASK-000.md"; then
  _fail "batch+outsider: active task line does not name the non-batch task"
else
  _pass "batch+outsider: active task line does not name the non-batch task"
fi
assert_contains "batch+outsider: message reflects the batch" "$HOOK_OUTPUT" "Batch tasks: TASK-001, TASK-002"
teardown_temp_dir

# --- 8: WS3 end-to-end — real git sandbox with the H2 pre-merge-commit guard
#        installed, driving the CORRECTED sequence by hand (record SHA +
#        IMPLEMENTED -> review verdict -> merge only if DONE), proving the
#        reorder actually restores the guard's precondition. Reuses the
#        sandbox-repo pattern from tests/test-git-hooks-premerge.sh (a
#        per-repo core.hooksPath install, not the shared repo's own hooks).
install_premerge_hook() {
  local repo="$1"
  mkdir -p "$repo/.githooks"
  cp "$REPO_ROOT/scripts/git-hooks/pre-merge-commit" "$repo/.githooks/pre-merge-commit"
  cp "$REPO_ROOT/scripts/git-hooks/_dispatch.sh" "$repo/.githooks/_dispatch.sh"
  chmod +x "$repo/.githooks/pre-merge-commit" "$repo/.githooks/_dispatch.sh"
  git -C "$repo" config core.hooksPath "$repo/.githooks"
}

setup_temp_dir
WS3_REPO="$TEST_DIR/repo"
mkdir -p "$WS3_REPO"
git -C "$WS3_REPO" init -q -b main
git -C "$WS3_REPO" config user.email "t@t.t"
git -C "$WS3_REPO" config user.name "t"
git -C "$WS3_REPO" commit -q --allow-empty -m "init"
install_premerge_hook "$WS3_REPO"
mkdir -p "$WS3_REPO/nazgul/tasks"
printf '{"execution":{"parallel":true},"guards":{"git_hooks":true}}' > "$WS3_REPO/nazgul/config.json"

# Step 1 (unchanged): one implementer per task, its own disjoint-scope branch.
git -C "$WS3_REPO" checkout -q -b feat/FEAT-999/TASK-001
echo a > "$WS3_REPO/a.txt"; git -C "$WS3_REPO" add a.txt; git -C "$WS3_REPO" commit -q -m "TASK-001 work"
WS3_TASK1_SHA=$(git -C "$WS3_REPO" rev-parse HEAD)
git -C "$WS3_REPO" checkout -q main

git -C "$WS3_REPO" checkout -q -b feat/FEAT-999/TASK-002
echo b > "$WS3_REPO/b.txt"; git -C "$WS3_REPO" add b.txt; git -C "$WS3_REPO" commit -q -m "TASK-002 work"
WS3_TASK2_SHA=$(git -C "$WS3_REPO" rev-parse HEAD)
git -C "$WS3_REPO" checkout -q main

# Step 2 (the reorder): record each branch-tip SHA + IMPLEMENTED BEFORE any
# merge — the precondition the H2 guard needs is now present at this point,
# not only after a merge that hasn't happened yet.
cat > "$WS3_REPO/nazgul/tasks/TASK-001.md" << EOF
---
status: IMPLEMENTED
---
# TASK-001

## Commits
- $WS3_TASK1_SHA
EOF
cat > "$WS3_REPO/nazgul/tasks/TASK-002.md" << EOF
---
status: IMPLEMENTED
---
# TASK-002

## Commits
- $WS3_TASK2_SHA
EOF

# Step 3 (the reorder): review-gate reviews each task's own unmerged branch
# diff and returns a verdict — simulated here as the resulting manifest
# status transition (no git action of its own). TASK-001 -> APPROVED -> DONE.
# TASK-002 -> CHANGES_REQUESTED.
sed -i.bak 's/^status: IMPLEMENTED/status: DONE/' "$WS3_REPO/nazgul/tasks/TASK-001.md" && rm -f "$WS3_REPO/nazgul/tasks/TASK-001.md.bak"
sed -i.bak 's/^status: IMPLEMENTED/status: CHANGES_REQUESTED/' "$WS3_REPO/nazgul/tasks/TASK-002.md" && rm -f "$WS3_REPO/nazgul/tasks/TASK-002.md.bak"

# Step 4 (the reorder): merge ONLY the DONE task. The manifest already lists
# WS3_TASK1_SHA under Status: DONE, so the H2 guard's lookup finds a match
# and correctly ALLOWS.
WS3_MERGE1_STDERR=$(git -C "$WS3_REPO" merge --no-ff -m "merge TASK-001" feat/FEAT-999/TASK-001 2>&1) && WS3_MERGE1_EC=0 || WS3_MERGE1_EC=$?
assert_exit_code "WS3 e2e: DONE task's branch merges (H2 guard allows)" "$WS3_MERGE1_EC" 0

# The CHANGES_REQUESTED task's branch is never merged by the corrected
# DISPATCH_INSTR (step 4 only names a DONE task) — and even on a direct
# attempt, the guard structurally blocks it, so it can never reach main.
WS3_MERGE2_STDERR=$(git -C "$WS3_REPO" merge --no-ff -m "merge TASK-002" feat/FEAT-999/TASK-002 2>&1) && WS3_MERGE2_EC=0 || WS3_MERGE2_EC=$?
git -C "$WS3_REPO" merge --abort 2>/dev/null || true
assert_exit_code "WS3 e2e: CHANGES_REQUESTED task's branch is never merged (H2 guard blocks)" "$WS3_MERGE2_EC" 1
assert_contains "WS3 e2e: guard message names the blocked task" "$WS3_MERGE2_STDERR" "TASK-002"
teardown_temp_dir

report_results
