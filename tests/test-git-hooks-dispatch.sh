#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e — several cases assert on a non-zero exit code from
# dispatch_prior_hook itself.

TEST_NAME="test-git-hooks-dispatch"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

DISPATCH="$REPO_ROOT/scripts/git-hooks/_dispatch.sh"

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

report_results
