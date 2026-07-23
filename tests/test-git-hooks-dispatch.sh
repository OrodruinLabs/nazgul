#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several cases assert on a non-zero exit code from
# dispatch_prior_hook itself.

TEST_NAME="test-git-hooks-dispatch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"
# shellcheck source=../scripts/lib/git-hooks.sh
source "$REPO_ROOT/scripts/lib/git-hooks.sh"

echo "=== $TEST_NAME ==="

DISPATCH="$REPO_ROOT/scripts/git-hooks/_dispatch.sh"

# init_repo/write_config: same minimal helpers as test-git-hooks-install.sh,
# needed here for the MF-036 install_git_hooks/self_heal_git_hooks coverage
# (this file's original scope was _dispatch.sh only).
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

# Fixture prior hook: logs its argv, captures stdin, exits with $2.
make_fixture_hook() {
  local path="$1" exit_code="$2"
  cat > "$path" <<FIXTURE_EOF
#!/usr/bin/env bash
echo "ran: \$*" >> "$TEST_DIR/dispatch.log"
cat > "$TEST_DIR/dispatch.stdin"
exit $exit_code
FIXTURE_EOF
  chmod +x "$path"
}

# Runs dispatch_prior_hook in a fresh subshell (isolates the source guard
# across cases) and returns its exit code via $?.
run_dispatch() {
  (
    # shellcheck source=/dev/null
    source "$DISPATCH"
    dispatch_prior_hook "$@"
  )
}

# ---------------------------------------------------------------------------
# Passthrough: prior hook exists (recorded prior_hooks_path), exit 0,
# argv + stdin forwarded.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/prior-hooks"
make_fixture_hook "$TEST_DIR/prior-hooks/pre-commit" 0
cat > "$TEST_DIR/nazgul/config.json" <<EOF
{"branch":{"prior_hooks_path":"$TEST_DIR/prior-hooks"}}
EOF
printf 'hello-stdin\n' | CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch pre-commit argA argB
EC=$?
assert_exit_code "passthrough: prior hook exit 0 propagates" "$EC" 0
assert_file_contains "passthrough: argv forwarded" "$TEST_DIR/dispatch.log" "argA argB"
assert_file_contains "passthrough: stdin forwarded" "$TEST_DIR/dispatch.stdin" "hello-stdin"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Passthrough: prior hook exits 1 -> dispatcher propagates exit 1.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/prior-hooks"
make_fixture_hook "$TEST_DIR/prior-hooks/pre-commit" 1
cat > "$TEST_DIR/nazgul/config.json" <<EOF
{"branch":{"prior_hooks_path":"$TEST_DIR/prior-hooks"}}
EOF
CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch pre-commit < /dev/null
EC=$?
assert_exit_code "passthrough: prior hook exit 1 propagates" "$EC" 1
teardown_temp_dir

# ---------------------------------------------------------------------------
# Coverage beyond the two Nazgul-defined hooks: pre-push also dispatches.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/prior-hooks"
make_fixture_hook "$TEST_DIR/prior-hooks/pre-push" 0
cat > "$TEST_DIR/nazgul/config.json" <<EOF
{"branch":{"prior_hooks_path":"$TEST_DIR/prior-hooks"}}
EOF
CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch pre-push < /dev/null
EC=$?
assert_exit_code "coverage: non-Nazgul hook name (pre-push) still dispatches" "$EC" 0
assert_file_contains "coverage: pre-push fixture ran" "$TEST_DIR/dispatch.log" "ran:"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Fallback: prior_hooks_path absent/empty (the "was unset" sentinel) ->
# default .git/hooks/<name>.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
setup_git_repo
mkdir -p "$TEST_DIR/.git/hooks"
make_fixture_hook "$TEST_DIR/.git/hooks/pre-commit" 0
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"prior_hooks_path":""}}
EOF
CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch pre-commit < /dev/null
EC=$?
assert_exit_code "fallback: empty prior_hooks_path -> .git/hooks default" "$EC" 0
assert_file_contains "fallback: .git/hooks/pre-commit fixture ran" "$TEST_DIR/dispatch.log" "ran:"
teardown_temp_dir

# ---------------------------------------------------------------------------
# No-op: no config at all, no git repo -> exit 0, nothing runs.
# ---------------------------------------------------------------------------
setup_temp_dir
CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch pre-commit < /dev/null
EC=$?
assert_exit_code "no-op: no config, no git repo -> exit 0" "$EC" 0
assert_file_not_exists "no-op: nothing executed" "$TEST_DIR/dispatch.log"
teardown_temp_dir

# ---------------------------------------------------------------------------
# No-op: recorded prior_hooks_path resolves, but no hook of that name exists
# there -> exit 0, never a failure.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/prior-hooks"
cat > "$TEST_DIR/nazgul/config.json" <<EOF
{"branch":{"prior_hooks_path":"$TEST_DIR/prior-hooks"}}
EOF
CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch commit-msg < /dev/null
EC=$?
assert_exit_code "no-op: no matching prior hook -> exit 0" "$EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Trust boundary: a present-but-non-executable file degrades to no-op, never
# a failure and never exec'd.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/prior-hooks"
cat > "$TEST_DIR/prior-hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod -x "$TEST_DIR/prior-hooks/pre-commit"
cat > "$TEST_DIR/nazgul/config.json" <<EOF
{"branch":{"prior_hooks_path":"$TEST_DIR/prior-hooks"}}
EOF
CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch pre-commit < /dev/null
EC=$?
assert_exit_code "trust boundary: non-executable prior hook -> no-op exit 0" "$EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Trust boundary: a symlinked prior hook degrades to no-op (regular file
# only), preventing config.json from turning the dispatcher into an
# arbitrary-exec primitive.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/prior-hooks" "$TEST_DIR/outside"
make_fixture_hook "$TEST_DIR/outside/real-hook" 0
ln -s "$TEST_DIR/outside/real-hook" "$TEST_DIR/prior-hooks/pre-commit"
cat > "$TEST_DIR/nazgul/config.json" <<EOF
{"branch":{"prior_hooks_path":"$TEST_DIR/prior-hooks"}}
EOF
CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch pre-commit < /dev/null
EC=$?
assert_exit_code "trust boundary: symlinked prior hook -> no-op exit 0" "$EC" 0
assert_file_not_exists "trust boundary: symlinked hook never executed" "$TEST_DIR/dispatch.log"
teardown_temp_dir

# ---------------------------------------------------------------------------
# Trust boundary: path traversal in hook_name is neutralized by basename —
# never escapes the resolved prior-hooks dir.
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
mkdir -p "$TEST_DIR/prior-hooks"
make_fixture_hook "$TEST_DIR/passwd" 0
cat > "$TEST_DIR/nazgul/config.json" <<EOF
{"branch":{"prior_hooks_path":"$TEST_DIR/prior-hooks"}}
EOF
CLAUDE_PROJECT_DIR="$TEST_DIR" run_dispatch "../passwd" < /dev/null
EC=$?
assert_exit_code "trust boundary: path traversal in hook_name -> no-op exit 0" "$EC" 0
assert_file_not_exists "trust boundary: traversal target never executed" "$TEST_DIR/dispatch.log"
teardown_temp_dir

# ---------------------------------------------------------------------------
# MF-036 (p4-*): all four git-p4 hook names are recognized by
# _GH_OTHER_HOOKS and get real dispatcher shims installed, same as any other
# standard githooks(5) name.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x"},"guards":{"git_hooks":true}}'
install_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json"
for p4hook in p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit; do
  case " ${_GH_OTHER_HOOKS[*]} " in
    *" $p4hook "*) _pass "MF-036: _GH_OTHER_HOOKS includes $p4hook" ;;
    *) _fail "MF-036: _GH_OTHER_HOOKS includes $p4hook" "not found in: ${_GH_OTHER_HOOKS[*]}" ;;
  esac
  assert_file_exists "MF-036: install_git_hooks creates a $p4hook shim" "$TEST_DIR/repo/nazgul/.githooks/$p4hook"
done
teardown_temp_dir

# ---------------------------------------------------------------------------
# MF-036 (two-sided drift, non-flagged case): live core.hooksPath matches the
# RECORDED PRIOR value exactly (e.g. an uninstall ran without Nazgul's
# knowledge, restoring the pre-install setting) — self_heal_git_hooks still
# reasserts the managed dir, but does NOT emit the "matches neither" drift
# warning, since this is a recognized (not a surprising third) value.
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":".husky"},"guards":{"git_hooks":true}}'
git -C "$TEST_DIR/repo" config core.hooksPath ".husky"
HEAL_OUT=$(self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json" 2>&1)
HEALED=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "MF-036: current==recorded-prior still reasserts managed dir" "$HEALED" "nazgul/.githooks"
assert_not_contains "MF-036: current==recorded-prior does NOT warn (recognized value)" "$HEAL_OUT" "matches neither"
teardown_temp_dir

# ---------------------------------------------------------------------------
# MF-036 (two-sided drift, flagged case): live core.hooksPath matches NEITHER
# the managed dir NOR the recorded prior value — a genuine third value (e.g.
# the user switched to a different hooks manager mid-cycle). self_heal_
# git_hooks must flag this with a loud warning AND still reassert the
# managed dir (the guard keeps firing regardless).
# ---------------------------------------------------------------------------
setup_temp_dir
init_repo "$TEST_DIR/repo"
write_config "$TEST_DIR/repo" '{"branch":{"base":"main","feature":"feat/x","prior_hooks_path":""},"guards":{"git_hooks":true}}'
git -C "$TEST_DIR/repo" config core.hooksPath ".lefthook"
HEAL_OUT2=$(self_heal_git_hooks "$TEST_DIR/repo" "$TEST_DIR/repo/nazgul/config.json" 2>&1)
HEALED2=$(git -C "$TEST_DIR/repo" config --get core.hooksPath)
assert_eq "MF-036: third-value drift still reasserts managed dir" "$HEALED2" "nazgul/.githooks"
assert_contains "MF-036: third-value drift is flagged with a warning" "$HEAL_OUT2" "matches neither"
assert_contains "MF-036: drift warning names the surprising value" "$HEAL_OUT2" ".lefthook"
teardown_temp_dir

report_results
