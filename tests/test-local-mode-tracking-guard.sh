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

# Block C-1: ./nazgul/config.json — leading ./ prefix must not bypass detection
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git add ./nazgul/config.json")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block C-1: git add ./nazgul/config.json (leading ./ not stripped)" "$GUARD_EC" 2
assert_contains "block C-1 message mentions NAZGUL GUARD" "$GUARD_STDERR" "NAZGUL GUARD"
teardown_temp_dir

# Block C-2: ./nazgul bare directory with leading ./
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "git add ./nazgul")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block C-2: git add ./nazgul (bare dir with leading ./)" "$GUARD_EC" 2
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

# Allow A-1: non-git command where token[0] is "grep" and token[1] would be "git" —
# the tokenizer must not treat a non-git first word as a git invocation.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "grep git add nazgul/ docs/")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow A-1: grep git add nazgul/ (non-git first token) does not block" "$GUARD_EC" 0
teardown_temp_dir

# Allow A-2: echo whose text contains "git commit" and "nazgul/x" — first token is echo,
# not git; verified by the tokenizer not just the pre-filter.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "echo git commit nazgul/x")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow A-2: echo git commit nazgul/x (non-git first token) does not block" "$GUARD_EC" 0
teardown_temp_dir

# Allow B-1: multiline commit message where a continuation line starts with nazgul/ —
# tr flattens newlines so the line stays inside the quoted span and is never emitted
# as a positional pathspec token.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
multiline_commit=$(printf "git commit -m 'first line\nnazgul/evil continuation'")
input=$(jq -n --arg cmd "$multiline_commit" '{"tool_name":"Bash","tool_input":{"command":$cmd}}')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow B-1: multiline -m message with nazgul/ on continuation line does not block" "$GUARD_EC" 0
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

# ---------------------------------------------------------------------------
# Category 1: Compound commands — real git add inside a compound must block
# ---------------------------------------------------------------------------

# Block E-1: semicolon compound; second segment is git add on nazgul/
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'echo ok; git add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block E-1: echo ok; git add nazgul/config.json (compound semicolon)" "$GUARD_EC" 2
assert_contains "block E-1 message mentions NAZGUL GUARD" "$GUARD_STDERR" "NAZGUL GUARD"
teardown_temp_dir

# Block E-2: && compound; second segment is git add on nazgul/
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'cd repo && git add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block E-2: cd repo && git add nazgul/config.json (compound &&)" "$GUARD_EC" 2
teardown_temp_dir

# Block E-3: pipe compound; second segment is git add on nazgul/
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'foo | git add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block E-3: foo | git add nazgul/config.json (compound pipe)" "$GUARD_EC" 2
teardown_temp_dir

# Allow E-4: grep whose pattern mentions git add — first token is grep, not git → allow
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "grep 'git add' nazgul/x.sh")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow E-4: grep 'git add' nazgul/x.sh (compound non-git segment)" "$GUARD_EC" 0
teardown_temp_dir

# Allow E-5: echo with quoted "git add nazgul/" text — the segment first token is echo → allow
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'echo "git add nazgul/"; ls')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow E-5: echo \"git add nazgul/\"; ls (quoted string, non-git first token)" "$GUARD_EC" 0
teardown_temp_dir

# ---------------------------------------------------------------------------
# Category 2: git global options — subcommand after globals must still block
# ---------------------------------------------------------------------------

# Block F-1: git -C <dir> add nazgul/
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git -C repo add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block F-1: git -C repo add nazgul/config.json (global -C)" "$GUARD_EC" 2
assert_contains "block F-1 message mentions NAZGUL GUARD" "$GUARD_STDERR" "NAZGUL GUARD"
teardown_temp_dir

# Block F-2: git -c name=value commit -- nazgul/
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git -c x=y commit -- nazgul/x')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block F-2: git -c x=y commit -- nazgul/x (global -c)" "$GUARD_EC" 2
teardown_temp_dir

# Block F-3: git --work-tree=. add nazgul/
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git --work-tree=. add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block F-3: git --work-tree=. add nazgul/config.json (global --work-tree=)" "$GUARD_EC" 2
teardown_temp_dir

# Block F-4: git -p add nazgul/ (flag-only global)
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git -p add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block F-4: git -p add nazgul/config.json (flag-only global -p)" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# Category M: multi-line input and &-bearing redirect tokens
# ---------------------------------------------------------------------------

# Block M-1: multi-line input — a non-git line then the real git add (per-line reset).
# Regression: previously newlines were flattened to spaces, hiding the git add.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "$(printf 'echo ok\ngit add nazgul/config.json')")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block M-1: multiline echo then git add nazgul/ (per-line reset)" "$GUARD_EC" 2
teardown_temp_dir

# Block M-2: a 2>&1 redirect token must NOT act as a separator that drops the pathspec
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git add nazgul/config.json 2>&1')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block M-2: git add nazgul/ 2>&1 (redirect dup, not a separator)" "$GUARD_EC" 2
teardown_temp_dir

# Block M-3: backslash-escaped quotes inside the -m message must not desync the
# quote state and hide a real nazgul/ pathspec after '--'.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git commit -m "msg with \"quote\"" -- nazgul/x')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block M-3: -m with escaped quotes then -- nazgul/x (escaped quote)" "$GUARD_EC" 2
teardown_temp_dir

# Allow M-4: adjacent quoted+unquoted fragments in a -m value form ONE message
# word (foonazgul/x), not a pathspec — must not false-positive.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git commit -m "foo"nazgul/x')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow M-4: -m \"foo\"nazgul/x (adjacent fragments form the message)" "$GUARD_EC" 0
teardown_temp_dir

# Block M-5: adjacent fragments that DO form a real nazgul/ pathspec still block.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git add "nazgul/"config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block M-5: git add \"nazgul/\"config.json (fragments form a real pathspec)" "$GUARD_EC" 2
teardown_temp_dir

# Block M-6: a leading redirect must not skip the segment and hide the git add
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input '> /tmp/out git add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block M-6: > /tmp/out git add nazgul/ (leading redirect skipped)" "$GUARD_EC" 2
teardown_temp_dir

# Block M-7: a leading fd redirect (2>file) before the git add
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input '2>/tmp/e git add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block M-7: 2>/tmp/e git add nazgul/ (leading fd redirect)" "$GUARD_EC" 2
teardown_temp_dir

# Allow M-8: a non-git leading command with a redirect into a nazgul/ file is not a
# git staging op — the segment is non-git, so the guard does not block.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'cat foo > nazgul/out.txt')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow M-8: cat foo > nazgul/out.txt (non-git, redirect not a stage)" "$GUARD_EC" 0
teardown_temp_dir

# Block M-9: a leading VAR=value env assignment must not mark the segment not_git
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'FOO=1 git add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block M-9: FOO=1 git add nazgul/ (leading env assignment)" "$GUARD_EC" 2
teardown_temp_dir

report_results
