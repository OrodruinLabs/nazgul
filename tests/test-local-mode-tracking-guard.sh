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

# --- Category W: portable word-boundary pre-filter (no \b dependency) ---
# Allow W-1: "git"/"add" only as substrings (legitimate, addendum) must not pass the
# pre-filter as whole words — and even if they did, no real pathspec is staged.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'echo "this legitimate addendum mentions nazgul/x"')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow W-1: 'legitimate addendum' substrings + nazgul/ (no whole-word git/add)" "$GUARD_EC" 0
teardown_temp_dir

# Block W-2: a real whole-word git add on a nazgul/ path still passes the boundary
# pre-filter and blocks (confirms the portable pattern matches genuine commands).
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git add nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block W-2: git add nazgul/ (portable boundary still matches real cmd)" "$GUARD_EC" 2
teardown_temp_dir

# --- Category H: heredoc-aware tokenizer (Defect 1e) ---
# A `-m "$(cat <<'MSG' ... MSG)"` heredoc body containing a literal `"` used to
# close the outer -m argument's quote tracking early, exposing a bare nazgul/
# token in the body to check_path — a false BLOCK. Found live by the FEAT-021
# TASK-010 implementer.
#
# Attempt 1 fixed this by also recognizing "<<" as a heredoc start whenever
# in_dq==1, which independently produced three false-ALLOW bypasses (security +
# code review, TASK-004 attempt 1) because a single in_dq flag can't tell a
# real dq-nested $(...) heredoc apart from a plain "<<" inside an ordinary
# "..." string. Attempt 2 dropped dq-context heredoc recognition entirely,
# which closed those bypasses but reopened the original false BLOCK for every
# dq-nested heredoc (H-1/H-3/H-4) and its own unquoted-delimiter break-class
# fix introduced three more false ALLOWs (H-6..H-9). Attempt 3 (final) tracks
# `$(...)` nesting depth (cs_depth) so a heredoc is recognized inside `in_dq`
# only while genuinely nested in a command substitution — restoring AC1
# without reopening H-2/H-6..H-9 — and made the delimiter scan itself
# quote-COMPOSABLE (mirroring the main tokenizer's adjacent-quoted+unquoted
# rule), closing three further bypasses an adversarial re-probe found in a
# mixed-quote delimiter like `<<EO'F'` (H-10/H-11/H-12).

# Block H-1: a dq-nested $(cat <<'MSG' ...) heredoc whose body contains a
# literal " must NOT close the outer -m argument's quote early — the original
# Defect 1e, fixed via $(...)-nesting-depth-gated heredoc recognition.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
# Built with printf, NOT a nested heredoc. The obvious fixture —
# `$(cat <<'CMDEOF' … git commit -m "$(cat <<'MSG' … " … )` — is a heredoc
# inside a command substitution inside a heredoc, whose body carries an
# unbalanced `"`. bash 5 parses that; /bin/bash 3.2 (macOS, this repo's stated
# minimum) does NOT — it fails the whole FILE with `unexpected EOF while
# looking for matching '"'`, so the suite silently stopped running there.
# Fittingly, the fixture for a heredoc-tokenizer bug was itself breaking an
# older shell's heredoc tokenizer. Verified byte-identical to the construct it
# replaces (both hash to 7cfc22b6…).
SQ="'"
heredoc_cmd=$(printf '%s\n' \
  "git commit -m \"\$(cat <<${SQ}MSG${SQ}" \
  'Note: a literal " character, then mentions nazgul/config.json on this line' \
  'MSG' \
  ')"')
input=$(make_bash_input "$heredoc_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow H-1: dq-nested heredoc + embedded quote + nazgul/ token (AC1)" "$GUARD_EC" 0
teardown_temp_dir

# Block H-2 (bypass pin): a REAL git add on a nazgul/ path after a heredoc must
# still block — this is what stops H-1's fix from turning the tokenizer off.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
heredoc_bypass_cmd=$(printf '%s\n' \
  'cat <<'"'"'MSG'"'"'' \
  'decoy nazgul/text inside the heredoc body' \
  'MSG' \
  'git add nazgul/real-file')
input=$(make_bash_input "$heredoc_bypass_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-2: real git add nazgul/ after a heredoc still blocks" "$GUARD_EC" 2
teardown_temp_dir

# Allow H-3: <<-'MSG' (tab-stripping variant) is also dq-nested, so it
# behaves like H-1.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
TAB=$'\t'
NL=$'\n'
heredoc_dash_cmd="git commit -m \"\$(cat <<-'MSG'${NL}${TAB}Note: a literal \" character, then mentions nazgul/config.json on this line${NL}${TAB}MSG${NL})\""
input=$(make_bash_input "$heredoc_dash_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow H-3: <<-'MSG' tab-stripping heredoc variant (AC1)" "$GUARD_EC" 0
teardown_temp_dir

# Allow H-4: <<"MSG" (double-quoted delimiter) is also dq-nested, so it
# behaves like H-1.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
heredoc_dq_delim_cmd=$(printf '%s\n' \
  'git commit -m "$(cat <<"MSG"' \
  'Note: a literal " character, then mentions nazgul/config.json on this line' \
  'MSG' \
  ')"')
input=$(make_bash_input "$heredoc_dq_delim_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'allow H-4: <<"MSG" double-quoted delimiter heredoc variant (AC1)' "$GUARD_EC" 0
teardown_temp_dir

# Allow H-5: an unterminated heredoc (delimiter line never appears) degrades to
# ALLOW per the file's documented degradation contract, asserted explicitly.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
heredoc_unterminated_cmd=$(printf '%s\n' \
  'git commit -m "$(cat <<'"'"'MSG'"'"'' \
  'Also touches nazgul/config.json but the heredoc never closes')
input=$(make_bash_input "$heredoc_unterminated_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "allow H-5: unterminated heredoc degrades to ALLOW" "$GUARD_EC" 0
teardown_temp_dir

# --- Category H (attempt-1 regression pins): three false-ALLOW bypasses the
# attempt-1 heredoc tokenizer introduced (security 90 + code-reviewer 84,
# TASK-004 attempt 1), each verified to FAIL against commit 15160c2 and PASS
# after. Mirrors H-2's two-line "real git add after" structure so a bypass
# that swallows the second line is caught.

# Block H-6 (probe a — security B1a): "<<" inside a plain double-quoted span
# (no nested $(...)) must not be misread as a heredoc start — a stray
# unquoted-delimiter break class that omits '"' absorbs the closing quote and
# desyncs in_dq, swallowing the real git add on the next line.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_a_cmd=$(printf '%s\n' \
  'echo "no heredoc here <<MARK"' \
  'git add nazgul/secret.txt')
input=$(make_bash_input "$probe_a_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-6: << inside a plain double-quoted span, real git add after (probe a)" "$GUARD_EC" 2
teardown_temp_dir

# Block H-7 (probe b — security B1b / code-reviewer B1): a <<< here-string
# must be consumed atomically, not torn into a plain redirect plus a bogus
# heredoc that swallows the real git add on the next line.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_b_cmd=$(printf '%s\n' \
  'ls <<< done' \
  'git add nazgul/secret')
input=$(make_bash_input "$probe_b_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-7: <<< here-string, real git add after (probe b)" "$GUARD_EC" 2
teardown_temp_dir

# Block H-8 (probe c — security B1c): a backslash-escaped "<" at top level
# must not combine with the following "<" into a heredoc start.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_c_cmd=$(printf '%s\n' \
  'echo \<<EOF' \
  'git add nazgul/secret')
input=$(make_bash_input "$probe_c_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-8: backslash-escaped \<< at top level, real git add after (probe c)' "$GUARD_EC" 2
teardown_temp_dir

# Block H-9 (code-reviewer B1 PoC, same-line variant): <<< on the same line
# as the real nazgul/ pathspec must not leave a stale redir_skip_next that
# swallows the pathspec at emit().
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git add <<<"x" nazgul/config.json')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-9: git add <<<\"x\" nazgul/config.json (same-line here-string)" "$GUARD_EC" 2
teardown_temp_dir

# --- Category H (attempt-3 regression pins): three more false-ALLOW bypasses
# an adversarial security re-probe found in the attempt-2 fix itself — the
# unquoted-delimiter break class that added '"'"'/" also made the delimiter
# non-composable, so a MIXED quoted+unquoted delimiter word (<<EO'"'"'F'"'"',
# <<EO"F", <<'"'"'AB'"'"'CD) truncates early: the real terminator line never
# matches, in_heredoc never resets, and every following line — including the
# real git add — is skipped. Each verified to FAIL against commit b70315e and
# PASS after. Mirrors H-2's two-line "real git add after" structure.

# Block H-10 (probe d): <<EO'"'"'F'"'"' — real bash quote-removal on the
# delimiter word yields "EOF"; an unquoted scan that stops at the first quote
# char yields the truncated "EO", which the real "EOF" terminator line never
# matches.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_d_cmd=$(printf '%s\n' \
  'cat <<EO'"'"'MSGF'"'"'' \
  'body' \
  'EOMSGF' \
  'git add nazgul/evil-file')
input=$(make_bash_input "$probe_d_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-10: <<EO'MSGF' mixed unquoted+quoted delimiter, real git add after (probe d)" "$GUARD_EC" 2
teardown_temp_dir

# Block H-11 (probe e): <<EO"MSGF" — the double-quoted mirror of H-10.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_e_cmd=$(printf '%s\n' \
  'cat <<EO"MSGF"' \
  'body' \
  'EOMSGF' \
  'git add nazgul/evil-file')
input=$(make_bash_input "$probe_e_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-11: <<EO"MSGF" mixed unquoted+quoted delimiter, real git add after (probe e)' "$GUARD_EC" 2
teardown_temp_dir

# Block H-12 (probe f): <<'MSG'FF — the quoted-then-unquoted mirror, where the
# quoted-delimiter branch previously returned right after the closing quote
# and never consumed the trailing unquoted suffix.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_f_cmd=$(printf '%s\n' \
  'cat <<'"'"'MSG'"'"'FF' \
  'body' \
  'MSGFF' \
  'git add nazgul/evil')
input=$(make_bash_input "$probe_f_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-12: <<'MSG'FF quoted-then-unquoted delimiter, real git add after (probe f)" "$GUARD_EC" 2
teardown_temp_dir

# --- Category H (attempt-4 regression pins): a fifth bypass found by an
# adversarial re-probe of attempt 3's own fix (security B1, H-13/H-14), plus
# a sixth the implementer found while hardening the attempt-3 non-blocking
# note (H-16). Both share the same swallow-real-command shape as H-6..H-12: a
# bogus span opens and its state never resets, so the real git add is
# skipped. H-13/H-14/H-16 verified exit=0 on 9ea7c41, exit=2 after this fix;
# H-15/H-17/H-18 are sanity/no-regression pins (never bypassed, or correctly
# never blocked).

# Block H-13 (probe g — security B1): $((1<<2)) is arithmetic expansion, not
# a nested $(...) — its "<<" is a shift operator. cs_depth alone can't tell
# "$((" apart from "$(" followed by "(", so "<<" was wrongly read as a
# heredoc start, leaving in_heredoc set after the arithmetic span closed.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_g_cmd=$(printf '%s\n' \
  'echo "$((1<<2))"' \
  'git add nazgul/evil')
input=$(make_bash_input "$probe_g_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-13: $((1<<2)) arithmetic left-shift, real git add after (probe g)' "$GUARD_EC" 2
teardown_temp_dir

# Block H-14 (probe g variant): whitespace around the shift operator must not
# change the outcome.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_g2_cmd=$(printf '%s\n' \
  'echo "$(( 5 << 3 ))"' \
  'git add nazgul/evil')
input=$(make_bash_input "$probe_g2_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-14: $(( 5 << 3 )) spaced arithmetic left-shift, real git add after (probe g variant)' "$GUARD_EC" 2
teardown_temp_dir

# Block H-15: the right-shift mirror (>>) was never actually routed through
# try_heredoc() (only "<" triggers it) — this is a sanity/no-regression pin,
# not a fixed bypass: verified exit=2 on both 9ea7c41 and this fix.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_g3_cmd=$(printf '%s\n' \
  'echo "$(( 1>>2 ))"' \
  'git add nazgul/evil')
input=$(make_bash_input "$probe_g3_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-15: $(( 1>>2 )) arithmetic right-shift, real git add after (probe g right-shift)' "$GUARD_EC" 2
teardown_temp_dir

# Block H-16 (implementer-found, attempt 4): a genuine single-quoted string
# inside $(...) containing a literal " — real bash never treats it as quote
# syntax there ('...' takes no escaping), but the unconditional c=="\"" reset
# at cs_depth>0 (pre-fix) read it as closing the OUTER quote, and nothing
# tracked real '...' spans nested in $(...) either. That left in_sq stuck
# open (re-entered at top level with no matching closer left in the line),
# swallowing "&& git add nazgul/evil" into the never-flushed token. This is
# the well-formed case: $(echo 'contains " quote') genuinely closes and the
# real git add genuinely executes in real bash — unlike a same-shape probe
# with an unmatched " inside $(...), which is itself malformed/unterminated
# and correctly degrades to ALLOW (H-18).
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git commit -m "$(echo '"'"'contains " quote'"'"')" && git add nazgul/evil')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-16: single-quoted span inside $(...) with an embedded ", real git add after (implementer probe)' "$GUARD_EC" 2
teardown_temp_dir

# Allow H-17: a genuinely nested double-quoted string inside $(...) that
# merely mentions nazgul/ as inert text (not a real pathspec) must not
# false-block — the H-16 fix must isolate the nested span, not just close it.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input 'git commit -m "$(echo "nazgul/fake")"')
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'allow H-17: nested-dq inert nazgul/ mention inside $(...) does not false-block' "$GUARD_EC" 0
teardown_temp_dir

# Block H-18 (RECLASSIFIED, TASK-004 attempt 5 — was "allow" under attempts
# 3/4's in_dq2/in_sq2 nested-quote isolation, deleted this attempt). The
# command's $(...) never actually closes in real bash: "echo "hi)"" is a
# complete, properly double-quoted "hi)" argument INSIDE the substitution —
# real bash reads the embedded ")" as inert literal text, not a closer — so
# no ")" remains anywhere on the line to end the $(...), and "&& git add
# nazgul/evil" is never really reached in real bash either way.
#
# Attempt 5's narrow rule intentionally does not track real nested quoting
# inside an unrecognized $(...) (that machinery — in_dq2/in_sq2 — is exactly
# what this attempt retired). It tracks opaque paren depth only, so the ")"
# inside the properly-quoted "hi)" is miscounted as the substitution's own
# close, and the tokenizer follows the (illusory) "&&" as if it were a real
# separator, and does correctly identify a real git add after it. Given the
# input never executes in real bash regardless, and a false BLOCK costs less
# than a false ALLOW per this guard's own contract, blocking a malformed,
# never-executing construct is the accepted, documented direction — not a
# reopened bypass. Contrast H-16 (well-formed, genuinely executes in real
# bash, no embedded ")" inside its quoted content to miscount) which still
# blocks correctly under the same mechanism.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h18_cmd=$(printf '%s\n' \
  'git commit -m "$(echo "hi)" && git add nazgul/evil')
input=$(make_bash_input "$probe_h18_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-18: malformed/never-executing nested-quote span now blocks (opaque paren-depth miscount, reclassified attempt 5)" "$GUARD_EC" 2
teardown_temp_dir

# --- Category H (attempt-6 regression pins): a top-level, UNQUOTED $((...))
# was arming a bogus heredoc because the top-level "<<" scanner never applied
# the cat/tee gate the $(...)-nested case already had. Verified to FAIL (exit
# 0) against commit d8a0293 and PASS (exit 2) after this fix — both
# directions checked, not assumed.

# Block H-19 (probe h — orchestrator B1): echo $((1<<2)) at top level, no
# surrounding quotes, real git add after.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h_cmd=$(printf '%s\n' \
  'echo $((1<<2))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-19: echo $((1<<2)) top-level (unquoted), real git add after (probe h)' "$GUARD_EC" 2
teardown_temp_dir

# Block H-20 (probe h variant): x=$((1<<2)) assignment form.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h2_cmd=$(printf '%s\n' \
  'x=$((1<<2))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h2_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-20: x=$((1<<2)) top-level assignment, real git add after (probe h variant)' "$GUARD_EC" 2
teardown_temp_dir

# Block H-21 (probe h variant): whitespace around the shift operator.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h3_cmd=$(printf '%s\n' \
  'echo $(( 5 << 3 ))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h3_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-21: echo $(( 5 << 3 )) top-level spaced arithmetic, real git add after (probe h variant)' "$GUARD_EC" 2
teardown_temp_dir

# Block H-22 (probe h variant): a no-op command word (":") preceding the
# arithmetic expansion.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h4_cmd=$(printf '%s\n' \
  ': $((1<<2))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h4_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-22: : $((1<<2)) top-level no-op command, real git add after (probe h variant)' "$GUARD_EC" 2
teardown_temp_dir

# --- Category H (attempt-6 sanity pins): the uniform cat/tee gate must not
# regress a REAL top-level heredoc using an unquoted delimiter or "tee", or
# the tab-stripping "<<-" variant — only bogus arming is removed, not genuine
# heredoc recognition.

# Allow-body/Block-after H-23: cat <<EOF (bare, unquoted delimiter) at top
# level — body is inert, real git add after the terminator still blocks.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h5_cmd=$(printf '%s\n' \
  'cat <<EOF' \
  'decoy nazgul/text inside the heredoc body' \
  'EOF' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h5_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-23: cat <<EOF (unquoted delimiter) top-level heredoc, real git add after" "$GUARD_EC" 2
teardown_temp_dir

# Block H-24: tee <<EOF at top level — the other enumerated heredoc-consuming
# command, real git add after the terminator still blocks.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h6_cmd=$(printf '%s\n' \
  'tee <<EOF' \
  'decoy nazgul/text inside the heredoc body' \
  'EOF' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h6_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-24: tee <<EOF top-level heredoc, real git add after" "$GUARD_EC" 2
teardown_temp_dir

# Block H-25: cat <<-'EOF' (tab-stripping variant) at top level, real git add
# after the tab-indented terminator still blocks.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
TAB=$'\t'
NL=$'\n'
probe_h7_cmd="cat <<-'EOF'${NL}${TAB}decoy nazgul/text inside the heredoc body${NL}${TAB}EOF${NL}git add nazgul/config.json"
input=$(make_bash_input "$probe_h7_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-25: cat <<-'EOF' tab-stripping top-level heredoc, real git add after" "$GUARD_EC" 2
teardown_temp_dir

# --- Category H (attempt-7 regression pins): heredoc_command_before()'s
# backward letter-scan armed on a bareword arithmetic OPERAND spelled
# cat/tee (a ninth false ALLOW, found independently by security and QA on
# attempt 6, confirmed by execution) because it had no grammar anchoring
# for $((...)) and no true word-boundary check. H-26..H-31 verified exit=0
# on 308c9190 (attempt 6), exit=2 after this fix — both directions checked.
# H-32..H-34 are sanity/no-regression pins (already correct on attempt 6,
# previously unpinned).

# Block H-26 (orchestrator/security/qa B1): echo $((cat<<2)) — cat is a
# bareword arithmetic operand ($cat, unset -> 0), not the cat(1) command.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h26_cmd=$(printf '%s\n' \
  'echo $((cat<<2))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h26_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-26: echo $((cat<<2)) bareword arithmetic operand, real git add after' "$GUARD_EC" 2
teardown_temp_dir

# Block H-27 (B1 variant): x=$((cat<<2)) assignment form.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h27_cmd=$(printf '%s\n' \
  'x=$((cat<<2))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h27_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-27: x=$((cat<<2)) top-level assignment, bareword operand, real git add after' "$GUARD_EC" 2
teardown_temp_dir

# Block H-28 (B1 variant): : $((tee<<1)) — the other enumerated word, no-op
# command prefix.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h28_cmd=$(printf '%s\n' \
  ': $((tee<<1))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h28_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-28: : $((tee<<1)) no-op command, bareword operand, real git add after' "$GUARD_EC" 2
teardown_temp_dir

# Block H-29 (B1 variant, spaced): x=$(( cat << 2 )) — whitespace between the
# arithmetic open and the operand must not defeat the "((" boundary check.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h29_cmd=$(printf '%s\n' \
  'x=$(( cat << 2 ))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h29_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-29: x=$(( cat << 2 )) spaced arithmetic, bareword operand, real git add after' "$GUARD_EC" 2
teardown_temp_dir

# Block H-30 (N1): x=$((_cat<<2)) — the letter-scan stops at "_", capturing
# only the "cat" suffix of the real identifier "_cat"; must still refuse.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h30_cmd=$(printf '%s\n' \
  'x=$((_cat<<2))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h30_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-30: x=$((_cat<<2)) underscore-prefixed identifier suffix, real git add after' "$GUARD_EC" 2
teardown_temp_dir

# Block H-31 (N1): x=$((2tee<<3)) — the letter-scan stops at a digit,
# capturing only the "tee" suffix of the real identifier "2tee".
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h31_cmd=$(printf '%s\n' \
  'x=$((2tee<<3))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h31_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-31: x=$((2tee<<3)) digit-prefixed identifier suffix, real git add after' "$GUARD_EC" 2
teardown_temp_dir

# --- Category H (attempt-7 sanity pins, code-reviewer N1): the boundary
# fix must not disturb whole-word non-cat/tee identifiers or the genuine
# subshell heredoc case — already correct on attempt 6, previously unpinned.

# Block H-32: x=$((mycat<<2)) — "mycat" is one contiguous letter-run and
# never equals "cat"/"tee"; must keep refusing to arm.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h32_cmd=$(printf '%s\n' \
  'x=$((mycat<<2))' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h32_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code 'block H-32: x=$((mycat<<2)) whole-word non-cat/tee identifier, real git add after' "$GUARD_EC" 2
teardown_temp_dir

# Block H-33: bobcat <<EOF / concat <<EOF at top level — whole-word
# non-cat/tee command names must not arm as a recognized heredoc.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h33_cmd=$(printf '%s\n' \
  'bobcat <<EOF' \
  'decoy nazgul/text inside the heredoc body' \
  'EOF' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h33_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-33: bobcat <<EOF whole-word non-cat command, real git add after" "$GUARD_EC" 2
teardown_temp_dir

setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h33b_cmd=$(printf '%s\n' \
  'concat <<EOF' \
  'decoy nazgul/text inside the heredoc body' \
  'EOF' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h33b_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-33b: concat <<EOF whole-word non-cat command, real git add after" "$GUARD_EC" 2
teardown_temp_dir

# Block H-34 (security N2): (cat <<EOF ... EOF) — a genuine subshell heredoc
# must keep arming. Only "((" (arithmetic open) excludes; a single "("
# (subshell/command-substitution open) must not.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
probe_h34_cmd=$(printf '%s\n' \
  '(cat <<EOF' \
  'decoy nazgul/text inside the heredoc body' \
  'EOF' \
  ')' \
  'git add nazgul/config.json')
input=$(make_bash_input "$probe_h34_cmd")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "block H-34: (cat <<EOF ... EOF) genuine subshell heredoc still arms, real git add after" "$GUARD_EC" 2
teardown_temp_dir

# ---------------------------------------------------------------------------
# Performance: resolve_project_root() deferred past the pre-filters (V2/AC2)
# ---------------------------------------------------------------------------

# Deterministic proof (load-independent): for a command failing either
# pre-filter, `nazgul-root.sh` must never even be sourced — xtrace of the run
# must not mention it, regardless of how busy the host machine is.
setup_temp_dir
setup_nazgul_dir
cat > "$TEST_DIR/nazgul/config.json" <<'EOF'
{"install_mode":"local","afk":{"enabled":true}}
EOF
input=$(make_bash_input "echo hello world")
CLAUDE_PROJECT_DIR="$TEST_DIR" run_guard_json "$input"
assert_exit_code "perf: pre-filter-failing command is allowed" "$GUARD_EC" 0
trace_output=$(echo "$input" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash -x "$GUARD" 2>&1 >/dev/null)
assert_not_contains "perf: nazgul-root.sh never sourced for pre-filter-failing command" "$trace_output" "nazgul-root.sh"

# Wall-clock corroboration: compare the pre-filter-exit (fast) path against a
# real blocking command (slow path) that does reach resolve_project_root(),
# sampled back-to-back so both inherit identical ambient host load — this
# stays meaningful even on a contended CI/dev box where an absolute ms budget
# would not. Median over N=20 interleaved samples each.
slow_input=$(make_bash_input "git add nazgul/config.json")

# EPOCHREALTIME is bash >= 5. Under `set -u` on /bin/bash 3.2 (macOS, this
# repo's stated minimum) referencing it aborts the whole file, so the section
# is gated rather than assumed (PR #75 review). Skipping is safe: this block
# is CORROBORATION only — the deterministic xtrace assertion above already
# proves resolve_project_root() is not reached on the pre-filter path, and it
# runs on every shell. The skip is announced, not silent, so nobody reads a
# green run as "the perf claim was checked" when it was not.
if [ -z "${EPOCHREALTIME+x}" ]; then
  echo "  (perf: SKIPPED — \$EPOCHREALTIME requires bash >= 5; running $(bash --version 2>/dev/null | head -1 | sed 's/GNU bash, version //;s/ .*//'). The xtrace assertion above already pins the behaviour.)"
else
PERF_N=20
fast_samples=()
slow_samples=()
for ((_i = 0; _i < PERF_N; _i++)); do
  _start=$EPOCHREALTIME
  echo "$input" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$GUARD" >/dev/null 2>&1
  _end=$EPOCHREALTIME
  fast_samples+=("$(awk -v s="$_start" -v e="$_end" 'BEGIN{printf "%.3f", (e-s)*1000}')")
  _start=$EPOCHREALTIME
  echo "$slow_input" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$GUARD" >/dev/null 2>&1
  _end=$EPOCHREALTIME
  slow_samples+=("$(awk -v s="$_start" -v e="$_end" 'BEGIN{printf "%.3f", (e-s)*1000}')")
done
fast_median_ms=$(printf '%s\n' "${fast_samples[@]}" | sort -n | awk -v n="$PERF_N" 'NR==int((n+1)/2){print; exit}')
slow_median_ms=$(printf '%s\n' "${slow_samples[@]}" | sort -n | awk -v n="$PERF_N" 'NR==int((n+1)/2){print; exit}')
echo "  (perf: pre-filter-exit median ${fast_median_ms} ms vs resolve_project_root-path median ${slow_median_ms} ms, N=${PERF_N} each; pre-fix empty-stdin baseline was ~36.9 ms)"
faster=$(awk -v f="$fast_median_ms" -v s="$slow_median_ms" 'BEGIN{print (f<s)?"yes":"no"}')
assert_eq "perf: pre-filter-exit path is faster than the resolve_project_root path" "$faster" "yes"
fi
teardown_temp_dir

# The fail-closed reader-unavailable path exists for "scripts/lib/ did not ship", so an
# unconditional `source lib/nazgul-root.sh` in it exited 1 — a PreToolUse ALLOW — on its own cause.
SELFDEP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-lmtg-selfdep-XXXXXX")
mkdir -p "$SELFDEP_DIR/scripts/lib" "$SELFDEP_DIR/proj/nazgul"
cp "$GUARD" "$SELFDEP_DIR/scripts/"
for _l in read-hook-payload nazgul-root emit-event; do
  cp "$REPO_ROOT/scripts/lib/$_l.sh" "$SELFDEP_DIR/scripts/lib/"
done
SELFDEP_GUARD="$SELFDEP_DIR/scripts/local-mode-tracking-guard.sh"

selfdep_probe() {
  local ec=0
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git add nazgul/x"}}' \
    | CLAUDE_PROJECT_DIR="$SELFDEP_DIR/proj" bash "$SELFDEP_GUARD" >/dev/null 2>&1 || ec=$?
  printf '%s' "$ec"
}

printf '%s\n' '{"install_mode":"local"}' > "$SELFDEP_DIR/proj/nazgul/config.json"
assert_eq "self-dep control: an intact copy still blocks a tracked nazgul/ path" "$(selfdep_probe)" "2"

rm -f "$SELFDEP_DIR/scripts/lib/read-hook-payload.sh"
assert_eq "reader missing, resolver present: fails CLOSED in a local-mode project" "$(selfdep_probe)" "2"

rm -f "$SELFDEP_DIR/scripts/lib/nazgul-root.sh"
assert_eq "reader AND resolver missing: still fails CLOSED, never the exit-1 a hook reads as allow" \
  "$(selfdep_probe)" "2"

# The deny must stay SCOPED with the resolver gone: same broken tree, out-of-scope project.
printf '%s\n' '{"install_mode":"plugin"}' > "$SELFDEP_DIR/proj/nazgul/config.json"
assert_eq "reader AND resolver missing, install_mode plugin: fails OPEN, this guard's scope holds" \
  "$(selfdep_probe)" "0"
rm -f "$SELFDEP_DIR/proj/nazgul/config.json"
assert_eq "reader AND resolver missing, no config at all: fails OPEN rather than denying every repo" \
  "$(selfdep_probe)" "0"
rm -rf "$SELFDEP_DIR"

report_results
