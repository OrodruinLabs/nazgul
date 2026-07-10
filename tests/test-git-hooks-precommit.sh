#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several cases assert on a non-zero `git commit` exit code.

TEST_NAME="test-git-hooks-precommit"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

PRE_COMMIT="$REPO_ROOT/scripts/git-hooks/pre-commit"
DISPATCH="$REPO_ROOT/scripts/git-hooks/_dispatch.sh"

# Minimal manual install (NOT production install_git_hooks, to stay acyclic):
# copies the hook + dispatcher into a per-repo hooks dir and points
# core.hooksPath at it directly.
install_hooks() {
  local repo="$1"
  mkdir -p "$repo/.githooks"
  cp "$PRE_COMMIT" "$repo/.githooks/pre-commit"
  cp "$DISPATCH" "$repo/.githooks/_dispatch.sh"
  chmod +x "$repo/.githooks/pre-commit" "$repo/.githooks/_dispatch.sh"
  git -C "$repo" config core.hooksPath "$repo/.githooks"
}

init_repo_on_branch() {
  local repo="$1" branch="$2"
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

commit_file() {
  local repo="$1" name="$2"
  echo "content" > "$repo/$name"
  git -C "$repo" add "$name"
  GIT_COMMIT_STDERR=$(git -C "$repo" commit -q -m "commit $name" 2>&1) && GIT_COMMIT_EC=0 || GIT_COMMIT_EC=$?
}

# ---------------------------------------------------------------------------
# BLOCK: feature active, current branch == base -> git commit fails, message
# names both branches.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/repo" "main"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/FEAT-010-x"},"guards":{"git_hooks":true}}'
commit_file "$TEST_DIR/repo" "a.txt"
assert_exit_code "block: commit on base while feature active -> nonzero" "$GIT_COMMIT_EC" 1
assert_contains "block message names base branch" "$GIT_COMMIT_STDERR" "main"
assert_contains "block message names feature branch" "$GIT_COMMIT_STDERR" "feat/FEAT-010-x"
teardown_temp_dir

# ---------------------------------------------------------------------------
# ALLOW: feature active, current branch == feature branch -> commit succeeds.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/repo" "feat/FEAT-010-x"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/FEAT-010-x"},"guards":{"git_hooks":true}}'
commit_file "$TEST_DIR/repo" "a.txt"
assert_exit_code "allow: commit on feature branch -> exit 0" "$GIT_COMMIT_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# ALLOW: unrelated repo, no hook installed there, `git -C <other> commit`
# from a cwd inside the guarded repo -> never blocked (structurally
# impossible for the old cwd/-C bug to reoccur, since the hook only ever
# fires for its own repo).
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/guarded" "main"
install_hooks "$TEST_DIR/guarded"
write_config "$TEST_DIR/guarded" '{"branch":{"base":"main","feature":"feat/FEAT-010-x"},"guards":{"git_hooks":true}}'
init_repo_on_branch "$TEST_DIR/other" "main"
(
  cd "$TEST_DIR/guarded" || exit 1
  echo "content" > "$TEST_DIR/other/b.txt"
  git -C "$TEST_DIR/other" add b.txt
  git -C "$TEST_DIR/other" commit -q -m "commit b.txt"
)
OTHER_EC=$?
assert_exit_code "allow: git -C <unrelated repo> commit from guarded cwd -> exit 0" "$OTHER_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: guards.git_hooks false -> kill switch disables the guard even on
# base branch with an active feature.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/repo" "main"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/FEAT-010-x"},"guards":{"git_hooks":false}}'
commit_file "$TEST_DIR/repo" "a.txt"
assert_exit_code "degrade: guards.git_hooks=false -> exit 0" "$GIT_COMMIT_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: no nazgul/config.json at all -> exit 0.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/repo" "main"
install_hooks "$TEST_DIR/repo"
commit_file "$TEST_DIR/repo" "a.txt"
assert_exit_code "degrade: no config -> exit 0" "$GIT_COMMIT_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: branch.feature null (no active loop) -> exit 0 even on base.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/repo" "main"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":null}}'
commit_file "$TEST_DIR/repo" "a.txt"
assert_exit_code "degrade: branch.feature null -> exit 0" "$GIT_COMMIT_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: malformed config.json (invalid JSON) -> exit 0.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/repo" "main"
install_hooks "$TEST_DIR/repo"
mkdir -p "$TEST_DIR/repo/nazgul"
printf 'not json {{{' > "$TEST_DIR/repo/nazgul/config.json"
commit_file "$TEST_DIR/repo" "a.txt"
assert_exit_code "degrade: malformed config -> exit 0" "$GIT_COMMIT_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: detached HEAD -> `branch --show-current` is empty -> exit 0.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/repo" "main"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/FEAT-010-x"},"guards":{"git_hooks":true}}'
git -C "$TEST_DIR/repo" checkout -q --detach HEAD
commit_file "$TEST_DIR/repo" "a.txt"
assert_exit_code "degrade: detached HEAD -> exit 0" "$GIT_COMMIT_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# CHAIN-DISPATCH: after allowing (feature branch), the prior pre-commit hook
# still runs; if it blocks, its exit code propagates.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo_on_branch "$TEST_DIR/repo" "feat/FEAT-010-x"
mkdir -p "$TEST_DIR/prior-hooks"
cat > "$TEST_DIR/prior-hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "prior hook ran" >&2
exit 1
EOF
chmod +x "$TEST_DIR/prior-hooks/pre-commit"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "{\"branch\":{\"base\":\"main\",\"feature\":\"feat/FEAT-010-x\",\"prior_hooks_path\":\"$TEST_DIR/prior-hooks\"},\"guards\":{\"git_hooks\":true}}"
commit_file "$TEST_DIR/repo" "a.txt"
assert_exit_code "chain-dispatch: prior hook exit 1 propagates on allow path" "$GIT_COMMIT_EC" 1
assert_contains "chain-dispatch: prior hook actually ran" "$GIT_COMMIT_STDERR" "prior hook ran"
teardown_temp_dir

report_results
