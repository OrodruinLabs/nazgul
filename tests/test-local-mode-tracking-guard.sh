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
