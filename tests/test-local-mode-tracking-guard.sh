#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because guard exits non-zero to block commands

TEST_NAME="test-local-mode-tracking-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/local-mode-tracking-guard.sh"

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

# ---------------------------------------------------------------------------
# BLOCK cases: local mode + git add/commit on nazgul/ paths → exit 2
# ---------------------------------------------------------------------------

# Block case 1: local mode, git add on a nazgul/ path
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git add nazgul/config.json")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block: local mode + git add nazgul/ (JSON)" "$GUARD_EC" 2
assert_contains "block message mentions NAZGUL GUARD" "$GUARD_STDERR" "NAZGUL GUARD"
assert_contains "block message mentions nazgul/" "$GUARD_STDERR" "nazgul/"
assert_contains "block message is actionable (.gitignore)" "$GUARD_STDERR" ".gitignore"
teardown_temp_dir

# Block case 2: local mode, git commit with a nazgul/ path in command
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git commit -m 'save' nazgul/tasks/TASK-001.md")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block: local mode + git commit nazgul/ path (JSON)" "$GUARD_EC" 2
assert_contains "block message mentions NAZGUL GUARD" "$GUARD_STDERR" "NAZGUL GUARD"
teardown_temp_dir

# Block case 3: a QUOTED nazgul/ pathspec must still be blocked (stripping the
# message must not strip a quoted path — policy-bypass regression guard)
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git add "nazgul/config.json"')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block: local mode + git add quoted nazgul/ path" "$GUARD_EC" 2
teardown_temp_dir

# Block case 4: commit with a quoted message AND a real nazgul/ pathspec → block
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git commit -m 'unrelated message' nazgul/plan.md")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block: message stripped but nazgul/ pathspec still blocks" "$GUARD_EC" 2
teardown_temp_dir

# Block case 5: mixed pathspec — nazgul/ mixed with a non-nazgul path → block
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git add nazgul/ scripts/my-script.sh")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block: mixed pathspec with nazgul/ still blocks" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# ALLOW cases: shared mode, local mode non-nazgul path, and uninitialised
# ---------------------------------------------------------------------------

# Allow case 1: shared mode — git add nazgul/ is fine
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"shared","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git add nazgul/config.json")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: shared mode + git add nazgul/ exits 0" "$GUARD_EC" 0
teardown_temp_dir

# Allow case 2: local mode, git add on a non-nazgul path — must be allowed
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git add scripts/my-script.sh")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: local mode + git add non-nazgul path exits 0" "$GUARD_EC" 0
teardown_temp_dir

# Allow case 3: local mode, unrelated command (git status) — not add/commit
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git status nazgul/")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: local mode + git status nazgul/ exits 0" "$GUARD_EC" 0
teardown_temp_dir

# Allow case 4: git commit whose MESSAGE mentions nazgul/ but stages no nazgul path
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git commit -m "persist reviews to nazgul/reviews/ — no path staged"')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: commit message mentioning nazgul/ does not block" "$GUARD_EC" 0
teardown_temp_dir

# Allow case 5 (single-quoted message variant)
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git commit -m 'touch nazgul/config.json mention only'")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow: single-quoted message mentioning nazgul/ does not block" "$GUARD_EC" 0
teardown_temp_dir

# Allow FP-3: multiline -m message mentioning nazgul/ — the newline does not escape
# the quoted span; the entire value is consumed as the message flag value.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
multiline_msg=$(printf "emit event\nreferences nazgul/reviews — no pathspec")
input=$(jq -n --arg cmd "git commit -m '$multiline_msg'" '{"tool_name":"Bash","tool_input":{"command":$cmd}}')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow FP-3: multiline -m message mentioning nazgul/ does not block" "$GUARD_EC" 0
teardown_temp_dir

# Allow FP-4: read-only grep whose pattern text contains "git add" and "nazgul/" —
# the command is not a git add/stage/commit so the early gate exits 0.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "grep -r 'git add.*nazgul/' scripts/")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow FP-4: grep pattern containing nazgul/ does not block" "$GUARD_EC" 0
teardown_temp_dir

# Allow FP-5: git commit -F with a nazgul/ path as the message FILE — the -F flag
# signals "message from file"; the path is its value, not a pathspec.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git commit -F nazgul/commit-msg.txt")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow FP-5: -F message-file with nazgul/ path does not block" "$GUARD_EC" 0
teardown_temp_dir

# Allow FP-6: echo command whose text mentions "git add nazgul/" — not a git tracking
# command; the early gate exits 0 before any pathspec analysis.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'echo "checking if git add nazgul/ is blocked"')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow FP-6: echo mentioning git add nazgul/ does not block" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# DEGRADE cases: uninitialised (no config), install_mode absent, empty stdin
# ---------------------------------------------------------------------------

# Degrade case 1: no nazgul/config.json → allow (exit 0)
setup_temp_dir
# No nazgul/config.json created
input=$(make_bash_input "git add nazgul/config.json")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "degrade: no config → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# Degrade case 2: config exists but install_mode absent → allow (exit 0)
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"afk":{"enabled":true}}
EOF
input=$(make_bash_input "git add nazgul/config.json")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "degrade: install_mode absent → exit 0" "$GUARD_EC" 0
teardown_temp_dir

# Degrade case 3: empty stdin → allow (exit 0)
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local"}
EOF
GUARD_STDERR=$(echo "" | bash "$GUARD" 2>&1 >/dev/null) && GUARD_EC=0 || GUARD_EC=$?
assert_exit_code "degrade: empty stdin → exit 0" "$GUARD_EC" 0
teardown_temp_dir

report_results
