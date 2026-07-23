#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several cases assert on a non-zero exit code.

TEST_NAME="test-git-hooks-wiring"
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

# ---------------------------------------------------------------------------
# create_feature_branch() installs git hooks immediately after writing
# branch.feature: core.hooksPath set to the managed dir, templates present.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"objectives_history":[],"guards":{"git_hooks":true}}'
create_feature_branch "Test objective" "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json" >/dev/null
INSTALLED_PATH=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "create_feature_branch: installs hooks (core.hooksPath set)" "$INSTALLED_PATH" "nazgul/.githooks"
assert_file_exists "create_feature_branch: pre-commit template copied" "$TEST_DIR/repo/nazgul/.githooks/pre-commit"
RECORDED=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "create_feature_branch: records prior hooksPath (unset sentinel)" "$RECORDED" ""
teardown_temp_dir

# ---------------------------------------------------------------------------
# create_feature_branch() respects guards.git_hooks=false — no install.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"objectives_history":[],"guards":{"git_hooks":false}}'
create_feature_branch "Test objective" "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json" >/dev/null
git -C "$TEST_DIR/repo" config --get core.hooksPath >/dev/null 2>&1
assert_exit_code "create_feature_branch: guards.git_hooks=false skips install" "$?" 1
teardown_temp_dir

# ---------------------------------------------------------------------------
# cleanup_all_worktrees() uninstalls when this objective actually installed —
# restores the real recorded prior core.hooksPath exactly.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"objectives_history":[],"guards":{"git_hooks":true}}'
create_feature_branch "Test objective" "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json" >/dev/null
RECORDED=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/repo/nazgul/config.json")
assert_eq "install: real prior recorded" "$RECORDED" ".husky"
cleanup_all_worktrees "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
RESTORED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "cleanup_all_worktrees: uninstalls, restores real prior exactly" "$RESTORED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Round trip: install -> cleanup with no prior value truly unsets (not "").
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"objectives_history":[],"guards":{"git_hooks":true}}'
create_feature_branch "Test objective" "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json" >/dev/null
cleanup_all_worktrees "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
git -C "$TEST_DIR/repo" config --get core.hooksPath >/dev/null 2>&1
assert_exit_code "round trip: no-prior-value case truly unsets" "$?" 1
teardown_temp_dir

# ---------------------------------------------------------------------------
# CF-3: cleanup_all_worktrees() must NOT touch core.hooksPath when this
# objective never installed (prior_hooks_path still null) — even though
# worktree_dir is unset/absent, so the early no-op path is taken.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
write_config "$TEST_DIR/repo" '{"branch":{"prior_hooks_path":null},"guards":{"git_hooks":true}}'
cleanup_all_worktrees "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
UNTOUCHED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "CF-3: cleanup on never-installed objective (no worktree_dir) leaves hooksPath alone" "$UNTOUCHED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# CF-3 companion: same never-installed case, but worktree_dir IS set and the
# task-worktree-removal path actually runs — uninstall still must not fire.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
mkdir -p "$TEST_DIR/repo-worktrees"
write_config "$TEST_DIR/repo" "{\"branch\":{\"worktree_dir\":\"$TEST_DIR/repo-worktrees\",\"prior_hooks_path\":null},\"guards\":{\"git_hooks\":true}}"
cleanup_all_worktrees "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
UNTOUCHED2=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "CF-3: cleanup with worktree_dir present but never installed still leaves hooksPath alone" "$UNTOUCHED2" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# session-context.sh SessionStart wires self_heal_git_hooks: drift during an
# active loop (installed + branch.feature set) is reasserted.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.guards.git_hooks = true'
install_git_hooks "$TEST_DIR" "$TEST_DIR/nazgul/config.json"
jq '.branch.feature = "feat/x"' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
  && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
git -C "$TEST_DIR" config core.hooksPath ".git/hooks-other"
bash "$REPO_ROOT/scripts/session-context.sh" >/dev/null 2>&1
HEALED=$(git -C "$TEST_DIR" config --get core.hooksPath)
assert_eq "session-context: self-heal reasserts managed dir on drift" "$HEALED" "nazgul/.githooks"
teardown_temp_dir

# ---------------------------------------------------------------------------
# session-context.sh: never-installed (null prior_hooks_path field) + an
# active objective (branch.feature set) is the MF-034 residual gap —
# self_heal_git_hooks now performs a first-time install (not a blind
# overwrite: the real pre-existing user hooksPath is durably recorded as
# the value to restore later).
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.guards.git_hooks = true' '.branch.feature = "feat/x"' '.branch.prior_hooks_path = null'
git -C "$TEST_DIR" config core.hooksPath ".husky"
bash "$REPO_ROOT/scripts/session-context.sh" >/dev/null 2>&1
INSTALLED=$(git -C "$TEST_DIR" config --get core.hooksPath)
assert_eq "session-context: never-installed + active objective triggers first-time install" "$INSTALLED" "nazgul/.githooks"
RECORDED=$(jq -r '.branch.prior_hooks_path' "$TEST_DIR/nazgul/config.json")
assert_eq "session-context: first-time install records the real prior hooksPath" "$RECORDED" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# session-context.sh: never-installed but NO active objective (branch.feature
# unset) — no branch-setup call site could plausibly have run yet, so no
# first-time install; a real pre-existing user hooksPath is left alone.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.guards.git_hooks = true' '.branch.prior_hooks_path = null'
git -C "$TEST_DIR" config core.hooksPath ".husky"
bash "$REPO_ROOT/scripts/session-context.sh" >/dev/null 2>&1
STILL=$(git -C "$TEST_DIR" config --get core.hooksPath)
assert_eq "session-context: never-installed with no active objective leaves user hooksPath alone" "$STILL" ".husky"
teardown_temp_dir

# ---------------------------------------------------------------------------
# session-context.sh: guards.git_hooks=false — drift left alone (intentional
# disable, matches self_heal_git_hooks's own no-op contract).
# ---------------------------------------------------------------------------
setup_temp_dir
setup_git_repo
setup_nazgul_dir
create_config '.guards.git_hooks = true'
install_git_hooks "$TEST_DIR" "$TEST_DIR/nazgul/config.json"
jq '.branch.feature = "feat/x" | .guards.git_hooks = false' "$TEST_DIR/nazgul/config.json" > "$TEST_DIR/nazgul/config.json.tmp" \
  && mv "$TEST_DIR/nazgul/config.json.tmp" "$TEST_DIR/nazgul/config.json"
git -C "$TEST_DIR" config core.hooksPath ".git/hooks-other"
bash "$REPO_ROOT/scripts/session-context.sh" >/dev/null 2>&1
UNTOUCHED3=$(git -C "$TEST_DIR" config --get core.hooksPath)
assert_eq "session-context: guards.git_hooks=false leaves drift alone" "$UNTOUCHED3" ".git/hooks-other"
teardown_temp_dir

report_results
