#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several cases assert on a non-zero `git merge` exit code.

TEST_NAME="test-git-hooks-premerge"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

PRE_MERGE="$REPO_ROOT/scripts/git-hooks/pre-merge-commit"
DISPATCH="$REPO_ROOT/scripts/git-hooks/_dispatch.sh"

# Minimal manual install (NOT production install_git_hooks, to stay acyclic):
# copies the hook + dispatcher into a per-repo hooks dir and points
# core.hooksPath at it directly.
install_hooks() {
  local repo="$1"
  mkdir -p "$repo/.githooks"
  cp "$PRE_MERGE" "$repo/.githooks/pre-merge-commit"
  cp "$DISPATCH" "$repo/.githooks/_dispatch.sh"
  chmod +x "$repo/.githooks/pre-merge-commit" "$repo/.githooks/_dispatch.sh"
  git -C "$repo" config core.hooksPath "$repo/.githooks"
}

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "t@t.t"
  git -C "$repo" config user.name "t"
  git -C "$repo" commit -q --allow-empty -m "init"
}

make_unit_branch() {
  local repo="$1" branch="$2"
  git -C "$repo" checkout -q -b "$branch"
  git -C "$repo" commit -q --allow-empty -m "unit work"
  git -C "$repo" checkout -q main
}

write_config() {
  local repo="$1" json="$2"
  mkdir -p "$repo/nazgul"
  printf '%s' "$json" > "$repo/nazgul/config.json"
}

write_graph() {
  local repo="$1" json="$2"
  mkdir -p "$repo/nazgul/conductor"
  printf '%s' "$json" > "$repo/nazgul/conductor/graph.json"
}

do_merge() {
  local repo="$1" branch="$2"
  MERGE_STDERR=$(git -C "$repo" merge --no-ff -m "merge $branch" "$branch" 2>&1) && MERGE_EC=0 || MERGE_EC=$?
  git -C "$repo" merge --abort 2>/dev/null || true
}

CONDUCTOR_CONFIG='{"execution":{"engine":"conductor"},"guards":{"git_hooks":true}}'

# ---------------------------------------------------------------------------
# BLOCK: conductor engine, unit's graph status != DONE -> merge fails.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$CONDUCTOR_CONFIG"
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"IN_REVIEW","verdict":""}}}'
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "block: non-APPROVED unit merge -> nonzero" "$MERGE_EC" 1
assert_contains "block message names the unit" "$MERGE_STDERR" "TASK-001"
teardown_temp_dir

# ---------------------------------------------------------------------------
# ALLOW: conductor engine, unit's graph status DONE + verdict ^APPROVE.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$CONDUCTOR_CONFIG"
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"DONE","verdict":"APPROVE — all reviewers passed"}}}'
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "allow: DONE+APPROVE unit merge -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# NO-OP: sequential engine -> unit merge allowed regardless of graph verdict.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"execution":{"engine":"sequential"},"guards":{"git_hooks":true}}'
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"IN_REVIEW","verdict":""}}}'
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "no-op: sequential engine -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: absent graph.json -> allowed even under conductor engine.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$CONDUCTOR_CONFIG"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: absent graph.json -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: malformed graph.json -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$CONDUCTOR_CONFIG"
mkdir -p "$TEST_DIR/repo/nazgul/conductor"
printf 'not json {{{' > "$TEST_DIR/repo/nazgul/conductor/graph.json"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: malformed graph.json -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: non-unit source branch (no /TASK-NNN suffix) -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "topic-branch"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$CONDUCTOR_CONFIG"
write_graph "$TEST_DIR/repo" '{"tasks":{}}'
do_merge "$TEST_DIR/repo" "topic-branch"
assert_exit_code "degrade: non-unit source branch -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: kill-switch conductor.enforce.premerge_guard=false -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"execution":{"engine":"conductor"},"guards":{"git_hooks":true},"conductor":{"enforce":{"premerge_guard":false}}}'
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"IN_REVIEW","verdict":""}}}'
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: kill-switch premerge_guard=false -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: guards.git_hooks=false -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"execution":{"engine":"conductor"},"guards":{"git_hooks":false}}'
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"IN_REVIEW","verdict":""}}}'
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: guards.git_hooks=false -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: no nazgul/config.json -> allowed.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
install_hooks "$TEST_DIR/repo"
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "degrade: no config -> exit 0" "$MERGE_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# GIT_REFLOG_ACTION resolution paths. A real `git merge` invocation always
# has git itself set GIT_REFLOG_ACTION="merge <ref>" (setenv overwrite=0
# only fires when the var is absent, and git never leaves it absent), so the
# MERGE_MSG-fallback and truly-unresolvable-source paths can only be
# exercised by invoking the hook binary directly with a controlled
# environment inside a real git repo — the same script git itself would
# invoke, just not reached via a full `git merge` porcelain call.
# ---------------------------------------------------------------------------
run_hook_direct() {
  local repo="$1"
  HOOK_STDERR=$(cd "$repo" && env -u GIT_REFLOG_ACTION "$repo/.githooks/pre-merge-commit" 2>&1) && HOOK_EC=0 || HOOK_EC=$?
}

# MERGE_MSG fallback, non-APPROVED unit -> blocked.
setup_temp_dir
init_repo "$TEST_DIR/repo"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$CONDUCTOR_CONFIG"
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"IN_REVIEW","verdict":""}}}'
mkdir -p "$TEST_DIR/repo/.git"
printf "Merge branch 'feat/FEAT-010-x/TASK-001' into main\n" > "$TEST_DIR/repo/.git/MERGE_MSG"
run_hook_direct "$TEST_DIR/repo"
assert_exit_code "MERGE_MSG fallback: non-APPROVED unit -> nonzero" "$HOOK_EC" 1
assert_contains "MERGE_MSG fallback block message names the unit" "$HOOK_STDERR" "TASK-001"
rm -f "$TEST_DIR/repo/.git/MERGE_MSG"
teardown_temp_dir

# MERGE_MSG fallback, DONE+APPROVE unit -> allowed.
setup_temp_dir
init_repo "$TEST_DIR/repo"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$CONDUCTOR_CONFIG"
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"DONE","verdict":"APPROVE — ok"}}}'
mkdir -p "$TEST_DIR/repo/.git"
printf "Merge branch 'feat/FEAT-010-x/TASK-001' into main\n" > "$TEST_DIR/repo/.git/MERGE_MSG"
run_hook_direct "$TEST_DIR/repo"
assert_exit_code "MERGE_MSG fallback: DONE+APPROVE unit -> exit 0" "$HOOK_EC" 0
rm -f "$TEST_DIR/repo/.git/MERGE_MSG"
teardown_temp_dir

# DEGRADE: source unresolvable from both GIT_REFLOG_ACTION (unset) and
# MERGE_MSG (absent) -> allowed.
setup_temp_dir
init_repo "$TEST_DIR/repo"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "$CONDUCTOR_CONFIG"
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"IN_REVIEW","verdict":""}}}'
run_hook_direct "$TEST_DIR/repo"
assert_exit_code "degrade: unresolvable source (no REFLOG_ACTION, no MERGE_MSG) -> exit 0" "$HOOK_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# CHAIN-DISPATCH: after allowing (DONE+APPROVE unit), the prior
# pre-merge-commit hook still runs; if it blocks, its exit code propagates.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
make_unit_branch "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
mkdir -p "$TEST_DIR/prior-hooks"
cat > "$TEST_DIR/prior-hooks/pre-merge-commit" <<'EOF'
#!/usr/bin/env bash
echo "prior hook ran" >&2
exit 1
EOF
chmod +x "$TEST_DIR/prior-hooks/pre-merge-commit"
install_hooks "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" "{\"execution\":{\"engine\":\"conductor\"},\"branch\":{\"prior_hooks_path\":\"$TEST_DIR/prior-hooks\"},\"guards\":{\"git_hooks\":true}}"
write_graph "$TEST_DIR/repo" '{"tasks":{"TASK-001":{"status":"DONE","verdict":"APPROVE — ok"}}}'
do_merge "$TEST_DIR/repo" "feat/FEAT-010-x/TASK-001"
assert_exit_code "chain-dispatch: prior hook exit 1 propagates on allow path" "$MERGE_EC" 1
assert_contains "chain-dispatch: prior hook actually ran" "$MERGE_STDERR" "prior hook ran"
teardown_temp_dir

report_results
