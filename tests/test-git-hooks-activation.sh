#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several cases assert on a non-zero exit code.

TEST_NAME="test-git-hooks-activation"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$REPO_ROOT/scripts/worktree-utils.sh"
source "$REPO_ROOT/scripts/lib/git-hooks.sh"
# worktree-utils.sh is `set -euo pipefail`; sourcing it into this test shell
# carries that setting over. Revert so assertions on non-zero exits below
# don't abort the run.
set +e

echo "=== $TEST_NAME ==="

init_repo() {
  local repo="$1" branch="${2:-main}"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "t@t.t"
  git -C "$repo" config user.name "t"
  git -C "$repo" checkout -q -b "$branch"
  git -C "$repo" commit -q --allow-empty -m "init"
}

write_config() {
  local repo="$1" json="$2"
  mkdir -p "$repo/nazgul"
  printf '%s' "$json" > "$repo/nazgul/config.json"
}

# Real production manifest shape: frontmatter `status:` is canonical, per
# scripts/lib/task-utils.sh and the pre-merge-commit hook's own precedence.
write_task() {
  local repo="$1" id="$2" status="$3" sha="$4"
  mkdir -p "$repo/nazgul/tasks"
  cat > "$repo/nazgul/tasks/$id.md" <<EOF
---
status: $status
---
# $id

## Commits

- $sha task work
EOF
}

# ---------------------------------------------------------------------------
# End-to-end (MF-034): the skills/start/SKILL.md Branch Setup sequence —
# create_feature_branch + setup_worktree_dir — genuinely activates the
# managed git-hooks install: core.hooksPath set, prior value recorded.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"objectives_history":[],"guards":{"git_hooks":true}}'
CONFIG="$TEST_DIR/repo/nazgul/config.json"
create_feature_branch "Activate git hooks" "$TEST_DIR/repo" "$CONFIG" >/dev/null
setup_worktree_dir "$TEST_DIR/repo" "$CONFIG" >/dev/null

INSTALLED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "activation: SKILL.md branch-setup flow sets core.hooksPath" "$INSTALLED" "nazgul/.githooks"
assert_file_exists "activation: pre-merge-commit template installed" "$TEST_DIR/repo/nazgul/.githooks/pre-merge-commit"
RECORDED=$(jq -r '.branch.prior_hooks_path' "$CONFIG")
assert_eq "activation: prior_hooks_path recorded (unset sentinel)" "$RECORDED" ""
WORKTREE_DIR=$(jq -r '.branch.worktree_dir' "$CONFIG")
assert_dir_exists "activation: worktree dir created and recorded" "$WORKTREE_DIR"
teardown_temp_dir

# ---------------------------------------------------------------------------
# End-to-end: OBJECTIVE_COMPLETE's cleanup_all_worktrees call uninstalls and
# restores the real recorded prior core.hooksPath after activation.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"objectives_history":[],"guards":{"git_hooks":true}}'
CONFIG="$TEST_DIR/repo/nazgul/config.json"
create_feature_branch "Activate git hooks" "$TEST_DIR/repo" "$CONFIG" >/dev/null
setup_worktree_dir "$TEST_DIR/repo" "$CONFIG" >/dev/null
cleanup_all_worktrees "$TEST_DIR/repo" "$CONFIG"
RESTORED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "activation: OBJECTIVE_COMPLETE cleanup restores real prior hooksPath" "$RESTORED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# MF-035: merge_task_to_feature(), invoked with the process cwd set INSIDE a
# SECONDARY task worktree (the exact escape condition MF-035 describes —
# an agent that never `cd`'d back to the main worktree), still triggers the
# managed pre-merge-commit guard: it blocks a non-DONE unit.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"objectives_history":[],"guards":{"git_hooks":true},"execution":{"parallel":true}}'
CONFIG="$TEST_DIR/repo/nazgul/config.json"
create_feature_branch "Merge cwd safety" "$TEST_DIR/repo" "$CONFIG" >/dev/null
setup_worktree_dir "$TEST_DIR/repo" "$CONFIG" >/dev/null
INITIAL_SHA=$(git -C "$TEST_DIR/repo" rev-parse HEAD)

TASK_DIR=$(create_task_worktree "TASK-001" "$TEST_DIR/repo" "$CONFIG" | tail -1)
echo "work" > "$TASK_DIR/work.txt"
git -C "$TASK_DIR" add work.txt
git -C "$TASK_DIR" commit -q -m "task work"
TASK_SHA=$(git -C "$TASK_DIR" rev-parse HEAD)
write_task "$TEST_DIR/repo" "TASK-001" "IN_REVIEW" "$TASK_SHA"

( cd "$TASK_DIR" && merge_task_to_feature "TASK-001" "$TEST_DIR/repo" "$CONFIG" ) >/dev/null 2>&1
MERGE_RC=$?
assert_exit_code "MF-035: merge from inside secondary worktree cwd is still blocked" "$MERGE_RC" 1
FEATURE_HEAD=$(git -C "$TEST_DIR/repo" rev-parse HEAD)
assert_eq "MF-035: blocked merge leaves feature branch HEAD untouched" "$FEATURE_HEAD" "$INITIAL_SHA"
teardown_temp_dir

# ---------------------------------------------------------------------------
# MF-035 companion: same setup, task manifest DONE -> merge from inside the
# secondary worktree succeeds and lands the commit on the feature branch.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"objectives_history":[],"guards":{"git_hooks":true},"execution":{"parallel":true}}'
CONFIG="$TEST_DIR/repo/nazgul/config.json"
create_feature_branch "Merge cwd safety" "$TEST_DIR/repo" "$CONFIG" >/dev/null
setup_worktree_dir "$TEST_DIR/repo" "$CONFIG" >/dev/null

TASK_DIR=$(create_task_worktree "TASK-001" "$TEST_DIR/repo" "$CONFIG" | tail -1)
echo "work" > "$TASK_DIR/work.txt"
git -C "$TASK_DIR" add work.txt
git -C "$TASK_DIR" commit -q -m "task work"
TASK_SHA=$(git -C "$TASK_DIR" rev-parse HEAD)
write_task "$TEST_DIR/repo" "TASK-001" "DONE" "$TASK_SHA"

( cd "$TASK_DIR" && merge_task_to_feature "TASK-001" "$TEST_DIR/repo" "$CONFIG" ) >/dev/null 2>&1
MERGE_RC=$?
assert_exit_code "MF-035: DONE unit merges cleanly from inside secondary worktree cwd" "$MERGE_RC" 0
assert_contains "MF-035: task commit landed on feature branch" "$(git -C "$TEST_DIR/repo" log --oneline)" "task work"
teardown_temp_dir

# ---------------------------------------------------------------------------
# self_heal_git_hooks broadening: guards.git_hooks true + branch.feature set
# + prior_hooks_path still null (the residual MF-034 gap: an active
# objective whose branch-setup call site never installed) -> first-time
# install fires, not just a drift-reassert (previously a structural no-op).
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"guards":{"git_hooks":true},"branch":{"feature":"feat/x","prior_hooks_path":null}}'
CONFIG="$TEST_DIR/repo/nazgul/config.json"
self_heal_git_hooks "$TEST_DIR/repo" "$CONFIG"
HEALED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: first-time-installs when feature set + prior_hooks_path null" "$HEALED" "nazgul/.githooks"
RECORDED=$(jq -r '.branch.prior_hooks_path' "$CONFIG")
assert_eq "self-heal: first install records the real prior hooksPath" "$RECORDED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# self_heal_git_hooks broadening: gate still requires guards.git_hooks true
# -> no first-time install when guards explicitly disabled.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"guards":{"git_hooks":false},"branch":{"feature":"feat/x","prior_hooks_path":null}}'
CONFIG="$TEST_DIR/repo/nazgul/config.json"
self_heal_git_hooks "$TEST_DIR/repo" "$CONFIG"
UNTOUCHED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: guards.git_hooks=false still skips first-time install" "$UNTOUCHED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# self_heal_git_hooks broadening: gate still requires branch.feature set ->
# no first-time install with no active objective.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"guards":{"git_hooks":true},"branch":{"prior_hooks_path":null}}'
CONFIG="$TEST_DIR/repo/nazgul/config.json"
self_heal_git_hooks "$TEST_DIR/repo" "$CONFIG"
UNTOUCHED2=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "self-heal: no branch.feature still skips first-time install" "$UNTOUCHED2" ".husky"
teardown_temp_dir

report_results
