#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because guard exits non-zero to block commands

TEST_NAME="test-base-branch-commit-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/base-branch-commit-guard.sh"

# Helper: build JSON PreToolUse Bash hook input
make_bash_input() {
  local cmd="$1"
  jq -n --arg cmd "$cmd" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

# Helper: run guard with JSON input, capture exit code and stderr
run_guard_json() {
  local input="$1"
  GUARD_STDERR=$(echo "$input" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
}

# Helper: make TEST_DIR a git repo whose current branch is $1 (one empty commit
# so branch state is concrete across git versions)
init_git_on_branch() {
  local branch="$1"
  git -C "$TEST_DIR" init -q
  git -C "$TEST_DIR" config user.email "t@t.t"
  git -C "$TEST_DIR" config user.name "t"
  git -C "$TEST_DIR" checkout -q -b "$branch"
  git -C "$TEST_DIR" commit -q --allow-empty -m "init"
}

# ---------------------------------------------------------------------------
# BLOCK: feature active, currently on base branch, git commit → exit 2
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git commit -m 'oops on main'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block: commit on base while feature active → exit 2" "$GUARD_EC" 2
assert_contains "block message names base branch" "$GUARD_STDERR" "main"
assert_contains "block message names feature branch" "$GUARD_STDERR" "feat/FEAT-002-x"
teardown_temp_dir

# ---------------------------------------------------------------------------
# ALLOW: feature active, on the feature branch, git commit → exit 0
# ---------------------------------------------------------------------------
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "feat/FEAT-002-x"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git commit -m 'work'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: commit on feature branch → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# ALLOW: feature active, on an unrelated branch, git commit → exit 0
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "hotfix/other"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git commit -m 'work'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: commit on unrelated branch → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# ALLOW: feature active, on base branch, but non-commit git command → exit 0
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git status")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: git status on base → exit 0" "$GUARD_EC" 0
input=$(make_bash_input "git push origin main")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: git push on base → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE: no config, feature absent/null, empty stdin → exit 0
# ---------------------------------------------------------------------------

# Degrade 1: no config → allow
setup_temp_dir
init_git_on_branch "main"
input=$(make_bash_input "git commit -m 'x'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "degrade: no config → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# Degrade 2: branch.feature absent → allow (no active loop), even committing on base
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":null}}
EOF
input=$(make_bash_input "git commit -m 'x'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "degrade: branch.feature null → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# Degrade 3: empty stdin → allow
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
GUARD_STDERR=$(echo "" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
assert_exit_code "degrade: empty stdin → exit 0" "$GUARD_EC" 0
teardown_temp_dir

report_results
