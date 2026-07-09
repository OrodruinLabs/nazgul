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


# ---------------------------------------------------------------------------
# ADR-003: resolve the ACTUAL target repo/branch of the commit, not just
# $CLAUDE_PROJECT_DIR.
# ---------------------------------------------------------------------------

# Helper: a second, wholly unrelated git repo (also on its own base branch),
# to prove `-C <other-repo>` is judged on its own identity, not this project's.
setup_other_repo() {
  OTHER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul:other-XXXXXX")
  export OTHER_DIR
  git -C "$OTHER_DIR" init -q
  git -C "$OTHER_DIR" config user.email "t@t.t"
  git -C "$OTHER_DIR" config user.name "t"
  git -C "$OTHER_DIR" checkout -q -b main
  git -C "$OTHER_DIR" commit -q --allow-empty -m "init"
}

teardown_other_repo() {
  [ -n "${OTHER_DIR:-}" ] && [ -d "$OTHER_DIR" ] && rm -rf "$OTHER_DIR"
  OTHER_DIR=""
}

# FALSE POSITIVE FIX: `git -C <other-repo> commit` — the active-loop project
# ($TEST_DIR) is on the base branch, but the command targets a completely
# different repo. Must be allowed: the commit never touches this project.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
setup_other_repo
input=$(make_bash_input "git -C $OTHER_DIR commit -m 'unrelated repo'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "ADR-003 false-positive fix: -C <other-repo> commit → exit 0" "$GUARD_EC" 0
teardown_other_repo
teardown_temp_dir

# ALLOW: an unrelated cwd/repo entirely, invoked without any active-loop
# project context lining up with it — same false-positive shape, no -C.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
setup_other_repo
input=$(make_bash_input "git -C $OTHER_DIR status && git -C $OTHER_DIR commit -m 'still unrelated'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "ADR-003: unrelated repo via -C in compound command → exit 0" "$GUARD_EC" 0
teardown_other_repo
teardown_temp_dir

# PRESERVED BLOCK: plain cwd (no -C), active-loop repo, base branch → still
# blocked exactly as before the fix.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git commit -m 'oops, still on main'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "ADR-003: preserved block, plain cwd, base branch → exit 2" "$GUARD_EC" 2
teardown_temp_dir

# FALSE NEGATIVE FIX: `-C <active-loop-repo>` explicitly naming the
# active-loop project's own path, still on the base branch. The old guard's
# whole-string `git\s+commit` pre-filter did not even recognize this as a
# git-commit invocation (an intervening `-C <path>` broke the adjacency
# match), so it was allowed unconditionally, regardless of branch. The new
# tokenizer must recognize it and resolve the TARGET's branch → still blocked.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git -C $TEST_DIR commit -m 'via -C, still main'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "ADR-003 false-negative fix: -C <active-loop-repo> base branch → exit 2" "$GUARD_EC" 2
assert_contains "false-negative-fix block message names base branch" "$GUARD_STDERR" "main"
teardown_temp_dir

# ALLOW: `-C <active-loop-repo>` but the repo is on the feature branch, not
# the base branch — still correctly allowed (the fix must not over-block).
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "feat/FEAT-002-x"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git -C $TEST_DIR commit -m 'via -C, on feature branch'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "ADR-003: -C <active-loop-repo> on feature branch → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# DEGRADE: `-C <path>` targets something that is not a git repo at all (a
# bogus/nonexistent path) → allow, exactly like the guard's existing
# not-a-git-repo degrade posture.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git -C /nazgul-test-does-not-exist-xyz commit -m 'bogus target'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "ADR-003: -C <not-a-git-repo> degrades to allow → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# METACHARACTER SAFETY: a `-C` value stuffed with shell metacharacters must
# produce NO side effect (it is only ever handed to `git -C` as one quoted
# argument — never eval'd or re-interpreted by a shell).
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
SIDE_EFFECT_MARKER="$TEST_DIR/side-effect-marker"
rm -f "$SIDE_EFFECT_MARKER"
input=$(make_bash_input "git -C \$(touch $SIDE_EFFECT_MARKER) commit -m 'metachar -C'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "ADR-003: metacharacter -C value degrades to allow → exit 0" "$GUARD_EC" 0
assert_file_not_exists "ADR-003: metacharacter -C value never side-effected (no eval)" "$SIDE_EFFECT_MARKER"
teardown_temp_dir

# ---------------------------------------------------------------------------
# B1 REGRESSION FIX: every commit segment in a compound command is evaluated
# independently — an earlier decoy/unrelated commit segment must not hide a
# later real base-branch commit.
# ---------------------------------------------------------------------------

# B1: decoy commit segment targets a nonexistent path, real commit follows,
# on base branch → still BLOCKED (the whole point of Finding 1).
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "git -C /nazgul-test-does-not-exist-xyz commit -m 'decoy' && git commit -m 'real'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "B1: decoy commit segment (bogus -C) then real commit on base → exit 2" "$GUARD_EC" 2
teardown_temp_dir

# B1: decoy commit segment targets a genuinely different repo, real commit
# follows, on base branch → still BLOCKED.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
setup_other_repo
input=$(make_bash_input "git -C $OTHER_DIR commit -m 'decoy' && git commit -m 'real'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "B1: decoy commit segment (other repo) then real commit on base → exit 2" "$GUARD_EC" 2
teardown_other_repo
teardown_temp_dir

# ---------------------------------------------------------------------------
# B2 REGRESSION FIX: interpreter-wrapped / command-substitution `git commit`
# invocations are not visible to the precise tokenizer; the raw-substring
# fallback must still block them on the base branch.
# ---------------------------------------------------------------------------

# B2: `bash -c 'git commit ...'` on base branch → BLOCKED.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "bash -c 'git commit -m wrapped'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "B2: bash -c 'git commit' on base → exit 2" "$GUARD_EC" 2
teardown_temp_dir

# B2: `true "$(git commit ...)"` (command substitution) on base branch → BLOCKED.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "main"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input 'true "$(git commit -m substituted)"')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'B2: true "$(git commit)" on base → exit 2' "$GUARD_EC" 2
teardown_temp_dir

# B2: the same wrapped forms on the FEATURE branch (not base) → still ALLOWED
# — the conservative fallback must not over-block.
setup_temp_dir
setup_nazgul_dir
init_git_on_branch "feat/FEAT-002-x"
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"branch":{"base":"main","feature":"feat/FEAT-002-x"}}
EOF
input=$(make_bash_input "bash -c 'git commit -m wrapped'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "B2: bash -c 'git commit' on feature branch → exit 0" "$GUARD_EC" 0
teardown_temp_dir

report_results
