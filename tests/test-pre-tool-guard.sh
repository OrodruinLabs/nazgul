#!/usr/bin/env bash
set -euo pipefail

# Test: pre-tool-guard.sh blocks dangerous commands and allows safe ones
TEST_NAME="test-pre-tool-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/pre-tool-guard.sh"

# Every command this suite exercises the guard with, recorded as it happens so
# the differential harness at the bottom of this file (AC1) can replay the full
# set against the pre-fix guard without a hand-maintained duplicate list. A NUL-
# delimited FILE, not an array: get_exit_code/get_exit_code_json are called as
# `x=$(...)`, which runs the function body in a subshell — an array append there
# would vanish when the subshell exits, but a file write persists. NUL (never
# valid inside a bash string) safely delimits records even when $cmd itself
# contains embedded real newlines (the multi-line test cases below).
EXERCISED_LOG="$(mktemp -t pre-tool-guard-exercised.XXXXXX)"
trap 'rm -f "$EXERCISED_LOG"' EXIT
_record_exercised() {
  printf '%s\x1f%s\0' "$1" "$2" >> "$EXERCISED_LOG"
}

run_guard() {
  local cmd="$1"
  local output
  _record_exercised raw "$cmd"
  output=$(echo "$cmd" | bash "$GUARD" 2>&1) || true
  echo "$output"
}

# Capture the guard's exit code explicitly via `|| ec=$?` so a non-zero (blocked)
# exit is "tested" and never aborts the function under `set -e`/`inherit_errexit`.
get_exit_code() {
  local cmd="$1" ec=0
  _record_exercised raw "$cmd"
  echo "$cmd" | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

# Production path: the hook receives a JSON envelope {tool_input:{command:...}}
# on stdin (not the raw command). The guard must extract .tool_input.command
# before tokenizing — otherwise the whole command is one JSON-quoted string.
get_exit_code_json() {
  local cmd="$1" ec=0
  _record_exercised json "$cmd"
  printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | bash "$GUARD" >/dev/null 2>&1 || ec=$?
  echo "$ec"
}

# --- Safe commands (should exit 0) ---
for safe_cmd in \
  "ls -la" \
  "git status" \
  "npm install" \
  "rm file.txt" \
  "curl https://example.com" \
  "node server.js" \
  "python3 script.py"; do
  ec=$(get_exit_code "$safe_cmd")
  assert_exit_code "safe: '$safe_cmd'" "$ec" 0
done

# --- Filesystem destruction (should exit 2) ---
for bad_cmd in \
  "rm -rf /" \
  "rm -rf ~" \
  'rm -rf $HOME' \
  "rm -rf . "; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-027: rm -rf precision — anchored root/home patterns must still block
# every genuine destructive form (both boundary variants: whitespace, `;`, `&`) ---
for bad_cmd in \
  "rm -rf /" \
  "rm -rf /;" \
  "rm -rf / &&" \
  "rm -rf //" \
  "rm -rf /root" \
  "rm -rf /root/" \
  "rm -rf ~" \
  "rm -rf ~/" \
  'rm -rf $HOME' \
  'rm -rf $HOME/'; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked MF-027: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason MF-027 for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-027: rm -rf precision — legitimate absolute/relative-path deletions
# must NOT be over-matched by the root/home block (the false-positive fix;
# trailing-slash whole-dir forms block above, real subpaths stay allowed) ---
for safe_cmd in \
  "rm -rf /tmp/x" \
  "rm -rf ./build" \
  "rm -rf ~/tmp" \
  "rm -rf /root/subdir" \
  'rm -rf $HOME/scratch' \
  "rm -rf /tmp/build-cache"; do
  ec=$(get_exit_code "$safe_cmd")
  assert_exit_code "allowed MF-027: '$safe_cmd'" "$ec" 0
done

# --- Database destruction (should exit 2) ---
for bad_cmd in \
  "psql -c 'DROP TABLE users'" \
  "mysql -e 'DROP DATABASE mydb'" \
  "sqlite3 db.sqlite 'TRUNCATE TABLE users'"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-029: additional DB-CLI invocation shapes (different clients/quoting) must
# still block, confirming the anchor isn't over-fit to the three literal strings above ---
for bad_cmd in \
  'psql -c "DROP TABLE accounts"' \
  'mysqldump --host=db -e "DROP DATABASE staging"' \
  'sqlcmd -Q "TRUNCATE TABLE dbo.orders"' \
  'redis-cli -x "TRUNCATE someset"' \
  "psql -c 'DROP TABLE \"accounts\"'" \
  "mysql -e 'DROP TABLE \`users\`'" \
  'sqlcmd -Q "TRUNCATE TABLE [dbo].[orders]"'; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked MF-029: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason MF-029 for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-029 B-1..B-4: DB-CLI token boundary — path-prefixed, subshell, piped, and
# quoted invocations are still DB-CLI invocations and must block (PR #71 bot findings) ---
for bad_cmd in \
  '/usr/bin/psql -c "DROP TABLE users"' \
  '$(psql -c "DROP TABLE users")' \
  'cat plan.sql | psql -c "DROP TABLE users"' \
  '"psql" -c "DROP TABLE users"'; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked MF-029 boundary: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason MF-029 boundary for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# Hyphen is deliberately NOT a token boundary: a hyphenated compound naming a client
# (wrapper script, file slug) is not that client, while redis-cli still matches as a
# listed token. Prose keyword mention alongside such a name must stay allowed.
ec=$(get_exit_code 'echo "see my-psql-notes.txt for the DROP TABLE cleanup plan"')
assert_exit_code "allowed MF-029 FP-7: hyphenated compound naming a client is not an invocation" "$ec" 0

# --- MF-029: evidence-derived false positives — quoted prose naming the SQL
# keywords with no DB-CLI invocation token anywhere in the command must be
# allowed (LR-005; observed live false positives during FEAT-018/019 dogfooding) ---

# FP-1: python3 heredoc prose (the FEAT-018 wiki-ingest case)
ec=$(get_exit_code "$(printf 'python3 <<EOF\nThis note explains the TRUNCATE prose fix for FEAT-018\nEOF')")
assert_exit_code "allowed MF-029 FP-1: python3 heredoc prose (no DB-CLI token)" "$ec" 0

# FP-2: jq string argument naming the keywords (the FEAT-019 objective-store self-block case)
ec=$(get_exit_code 'jq -n --arg msg "block DROP TABLE and TRUNCATE keywords" "$msg"')
assert_exit_code "allowed MF-029 FP-2: jq argument naming keywords" "$ec" 0

# FP-3: git commit -m prose message
ec=$(get_exit_code 'git commit -m "fix: anchor DROP TABLE and TRUNCATE guard rules (LR-005)"')
assert_exit_code "allowed MF-029 FP-3: git commit -m prose" "$ec" 0

# FP-4: grep search-pattern argument naming a keyword
ec=$(get_exit_code 'grep -rn "DROP TABLE" scripts/pre-tool-guard.sh')
assert_exit_code "allowed MF-029 FP-4: grep pattern argument" "$ec" 0

# FP-5: file path / code comment containing a keyword, no DB-CLI invocation
ec=$(get_exit_code 'echo "// TODO: handle TRUNCATE edge case in parser.py"')
assert_exit_code "allowed MF-029 FP-5: file path/comment mentioning keyword" "$ec" 0

# FP-6: production JSON-envelope path — same commit-message prose as FP-3, wrapped
# per the real PreToolUse hook contract
ec=$(get_exit_code_json 'git commit -m "fix: anchor DROP TABLE and TRUNCATE guard rules (LR-005)"')
assert_exit_code "allowed MF-029 FP-6: JSON envelope commit-message prose" "$ec" 0

# --- MF-029: whole-command AND regression — the DB-CLI token and the destructive
# statement no longer need to share a ;/&&/||/|-delimited segment, so realistic
# bypasses that split the two across segments or lines must still block ---

# Block S-1: multi-statement SQL inside one quoted -c argument (the `;` inside the
# quotes used to split the DB-CLI token from the keyword into separate segments)
ec=$(get_exit_code 'psql -c "SELECT 1; DROP TABLE users;"')
assert_exit_code "blocked MF-029 S-1: multi-statement quoted -c arg" "$ec" 2

# Block S-2: heredoc invocation — the DB-CLI token and the destructive statement
# land on separate lines, which the old segment-scoped check treated as isolated
ec=$(get_exit_code "$(printf 'psql -h host -d mydb <<SQL\nDROP TABLE users;\nSQL')")
assert_exit_code "blocked MF-029 S-2: heredoc invocation across lines" "$ec" 2

# Block S-3 (deliberate over-block, safe direction): a DB-CLI invocation and an
# unrelated keyword mention in a LATER, independent segment of the same compound
# command now also blocks, since the token and the keyword are only required to
# appear anywhere in $CMD, not in the same segment. This is the documented tradeoff
# of dropping segment-scoping (see the comment above check_sql_destructive()) —
# pinned here as a known, accepted limitation (documented at scripts/pre-tool-guard.sh:54-65).
ec=$(get_exit_code 'psql -c "select 1"; echo "please DROP TABLE users"')
assert_exit_code "blocked MF-029 S-3: cross-segment token+keyword (accepted over-block)" "$ec" 2

# --- Git force push (should exit 2) ---
for bad_cmd in \
  "git push --force origin main" \
  "git push -f origin master"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-028: force-push order independence — all four flag/branch orderings
# must block, since real usage puts the flag before OR after the branch ---
for bad_cmd in \
  "git push --force origin main" \
  "git push -f origin main" \
  "git push origin main --force" \
  "git push origin main -f" \
  "git push origin master --force" \
  "git push origin master -f"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked MF-028: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason MF-028 for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- MF-028: no false-positive — force-push to a non-protected branch, or a
# plain push to main with no force flag, must both be allowed ---
for safe_cmd in \
  "git push origin feature-branch --force" \
  "git push origin main"; do
  ec=$(get_exit_code "$safe_cmd")
  assert_exit_code "allowed MF-028: '$safe_cmd'" "$ec" 0
done

# --- Dangerous system commands (should exit 2) ---
for bad_cmd in \
  ':(){:|:&};:' \
  "chmod -R 777 /var"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
done

# --- Task manifest write protection: BLOCK cases (should exit 2) ---
# Block R1: echo with >> redirect into manifest
ec=$(get_exit_code 'echo "Status: IN_PROGRESS" >> nazgul/tasks/TASK-001.md')
assert_exit_code "blocked Block R1: echo >> manifest" "$ec" 2
output=$(run_guard 'echo "Status: IN_PROGRESS" >> nazgul/tasks/TASK-001.md')
assert_contains "reason Block R1" "$output" "NAZGUL SAFETY"

# Block R2: echo with > redirect into manifest
ec=$(get_exit_code 'echo "Status: DONE" > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked Block R2: echo > manifest" "$ec" 2
output=$(run_guard 'echo "Status: DONE" > nazgul/tasks/TASK-001.md')
assert_contains "reason Block R2" "$output" "NAZGUL SAFETY"

# Block R3: printf with >> redirect into manifest
ec=$(get_exit_code 'printf "Status: DONE\n" >> nazgul/tasks/TASK-002.md')
assert_exit_code "blocked Block R3: printf >> manifest" "$ec" 2
output=$(run_guard 'printf "Status: DONE\n" >> nazgul/tasks/TASK-002.md')
assert_contains "reason Block R3" "$output" "NAZGUL SAFETY"

# Block R4: tee into manifest (existing tee rule)
ec=$(get_exit_code 'tee nazgul/tasks/TASK-003.md')
assert_exit_code "blocked Block R4: tee manifest" "$ec" 2
output=$(run_guard 'tee nazgul/tasks/TASK-003.md')
assert_contains "reason Block R4" "$output" "NAZGUL SAFETY"

# Block R5: sed reading manifest and piping to grep Status (existing sed rule fires when path precedes Status)
ec=$(get_exit_code 'sed -n p nazgul/tasks/TASK-001.md | grep Status')
assert_exit_code "blocked Block R5: sed manifest | grep Status" "$ec" 2
output=$(run_guard 'sed -n p nazgul/tasks/TASK-001.md | grep Status')
assert_contains "reason Block R5" "$output" "NAZGUL SAFETY"

# --- Task manifest write protection: ALLOW cases (false-positives now fixed) ---
# Allow FP-1: echo + mention of manifest path, no redirect into manifest
ec=$(get_exit_code 'echo "Status: IN_PROGRESS"; grep nazgul/tasks/TASK-001.md')
assert_exit_code "allowed Allow FP-1: echo Status + grep manifest (no redirect)" "$ec" 0

# Allow FP-2: printf + cat manifest (no redirect into manifest)
ec=$(get_exit_code 'printf "Current Status: DONE\n"; cat nazgul/tasks/TASK-001.md')
assert_exit_code "allowed Allow FP-2: printf Status + cat manifest (no redirect)" "$ec" 0

# Allow FP-3: echo mentioning manifest path, no redirect
ec=$(get_exit_code 'echo "Checking Status of nazgul/tasks/TASK-001.md..."')
assert_exit_code "allowed Allow FP-3: echo mentioning manifest path (no redirect)" "$ec" 0

# Allow FP-4: grep only, no echo/printf at all
ec=$(get_exit_code 'grep "Status" nazgul/tasks/TASK-001.md')
assert_exit_code "allowed Allow FP-4: grep Status in manifest (read-only)" "$ec" 0

# --- D: echo/printf redirect: false-positive fixes (quoted > is data, not redirect) ---
# Allow D-FP-1: > is DATA inside double quotes — must not block
ec=$(get_exit_code 'echo "> nazgul/tasks/TASK-001.md"')
assert_exit_code "allowed D-FP-1: echo with > inside double quotes (data, not redirect)" "$ec" 0

# Allow D-FP-2: >> is DATA inside single quotes — must not block
ec=$(get_exit_code "printf '%s' '>> nazgul/tasks/TASK-001.md'")
assert_exit_code "allowed D-FP-2: printf with >> inside single quotes (data, not redirect)" "$ec" 0

# --- D: echo/printf redirect: false-negative fixes (quoted/./target must block) ---
# Block D-FN-1: real redirect with double-quoted target path
ec=$(get_exit_code 'echo foo > "nazgul/tasks/TASK-001.md"')
assert_exit_code "blocked D-FN-1: echo foo > \"nazgul/tasks/TASK-001.md\" (quoted target)" "$ec" 2
output=$(run_guard 'echo foo > "nazgul/tasks/TASK-001.md"')
assert_contains "reason D-FN-1" "$output" "NAZGUL SAFETY"

# Block D-FN-2: real redirect with ./nazgul/ prefixed target
ec=$(get_exit_code 'echo foo > ./nazgul/tasks/TASK-001.md')
assert_exit_code "blocked D-FN-2: echo foo > ./nazgul/tasks/TASK-001.md (./ prefix)" "$ec" 2
output=$(run_guard 'echo foo > ./nazgul/tasks/TASK-001.md')
assert_contains "reason D-FN-2" "$output" "NAZGUL SAFETY"

# --- Category 3: >| and >>| noclobber-override redirects (should exit 2) ---
# Block G-1: >| noclobber-override redirect to manifest
ec=$(get_exit_code 'echo foo >| nazgul/tasks/TASK-001.md')
assert_exit_code "blocked G-1: echo foo >| nazgul/tasks/TASK-001.md (noclobber >|)" "$ec" 2
output=$(run_guard 'echo foo >| nazgul/tasks/TASK-001.md')
assert_contains "reason G-1" "$output" "NAZGUL SAFETY"

# Block G-2: >>| noclobber-override append redirect to manifest
ec=$(get_exit_code 'echo foo >>| nazgul/tasks/TASK-001.md')
assert_exit_code "blocked G-2: echo foo >>| nazgul/tasks/TASK-001.md (noclobber >>|)" "$ec" 2
output=$(run_guard 'echo foo >>| nazgul/tasks/TASK-001.md')
assert_contains "reason G-2" "$output" "NAZGUL SAFETY"

# --- Category 1: compound echo — non-echo/printf segments are ignored (allow regression) ---
# Allow H-1: grep with manifest path piped to head (no echo/printf, no redirect)
ec=$(get_exit_code 'grep Status scripts/foo.sh | head')
assert_exit_code "allowed H-1: grep manifest | head (no echo/printf)" "$ec" 0

# Allow H-2: echo in compound with no redirect into manifest
ec=$(get_exit_code 'echo "checking"; grep Status scripts/foo.sh')
assert_exit_code "allowed H-2: echo checking; grep (no redirect into manifest)" "$ec" 0

# --- Category 4: full-word redirect-target resolution (leading redirect + split fragments) ---
# Block I-1: leading redirect before the command word (> target echo ok)
ec=$(get_exit_code '> nazgul/tasks/TASK-001.md echo ok')
assert_exit_code "blocked I-1: > nazgul/tasks/TASK-001.md echo ok (leading redirect)" "$ec" 2
output=$(run_guard '> nazgul/tasks/TASK-001.md echo ok')
assert_contains "reason I-1" "$output" "NAZGUL SAFETY"

# Block I-2: target split across adjacent quoted + unquoted fragments
ec=$(get_exit_code 'echo ok > "nazgul/tasks/"TASK-001.md')
assert_exit_code "blocked I-2: echo ok > \"nazgul/tasks/\"TASK-001.md (split target)" "$ec" 2
output=$(run_guard 'echo ok > "nazgul/tasks/"TASK-001.md')
assert_contains "reason I-2" "$output" "NAZGUL SAFETY"

# Allow I-3: leading redirect to a NON-manifest target (no false-positive)
ec=$(get_exit_code '> /tmp/out.log echo ok')
assert_exit_code "allowed I-3: > /tmp/out.log echo ok (non-manifest target)" "$ec" 0

# Allow I-4: split fragments that do NOT form a manifest path
ec=$(get_exit_code 'echo ok > "/tmp/"out.log')
assert_exit_code "allowed I-4: echo ok > \"/tmp/\"out.log (non-manifest split target)" "$ec" 0

# --- Category 5: production JSON-envelope path (regression for command extraction) ---
# Block J-1: JSON envelope with a real echo>manifest must fire (prod hook contract)
ec=$(get_exit_code_json 'echo "Status: DONE" > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked J-1: JSON envelope echo > manifest (production path)" "$ec" 2

# Allow J-2: JSON envelope read-only echo of a manifest path (no redirect)
ec=$(get_exit_code_json 'echo "checking nazgul/tasks/TASK-001.md"')
assert_exit_code "allowed J-2: JSON envelope read-only echo (production path)" "$ec" 0

# --- Category 6: & redirects (2>&1, &>) and multi-line segment reset ---
# Block K-1: fd-dup 2>&1 before a real > into manifest (the & must not eat the redirect)
ec=$(get_exit_code 'echo foo 2>&1 > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked K-1: echo foo 2>&1 > manifest" "$ec" 2

# Block K-2: &> combined stdout+stderr redirect into manifest
ec=$(get_exit_code 'echo foo &> nazgul/tasks/TASK-001.md')
assert_exit_code "blocked K-2: echo foo &> manifest" "$ec" 2

# Allow K-3: 2>&1 with no manifest redirect (no false-positive)
ec=$(get_exit_code 'echo foo 2>&1')
assert_exit_code "allowed K-3: echo foo 2>&1 (no manifest redirect)" "$ec" 0

# Block K-4: multi-line — a non-echo segment then echo > manifest (per-line reset)
ec=$(get_exit_code "$(printf 'ls x\necho b > nazgul/tasks/TASK-001.md')")
assert_exit_code "blocked K-4: multiline ls; then echo > manifest" "$ec" 2

# Allow K-5: multi-line echos with no manifest redirect
ec=$(get_exit_code "$(printf 'echo a\necho b')")
assert_exit_code "allowed K-5: multiline echos, no redirect" "$ec" 0

# --- Category 7: backslash-escaped quotes inside double-quoted spans ---
# Block L-1: an escaped \" inside the echoed string must not desync in_dq and hide
# the redirect (the > into the manifest must still be detected).
ec=$(get_exit_code 'echo "foo\"bar" > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked L-1: echo \"foo\\\"bar\" > manifest (escaped quote)" "$ec" 2

# Allow L-2: escaped quote, no redirect → no false-positive
ec=$(get_exit_code 'echo "foo\"bar baz"')
assert_exit_code "allowed L-2: echo \"foo\\\"bar baz\" (escaped quote, no redirect)" "$ec" 0

# --- Category 8: fd-numbered and leading redirects ---
# Block N-1: a leading 2>&1 must not steal the command word from a later echo
ec=$(get_exit_code '2>&1 echo foo > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked N-1: leading 2>&1 then echo > manifest" "$ec" 2

# Block N-2: a leading fd redirect (1>file) before echo
ec=$(get_exit_code '1>/tmp/x echo foo > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked N-2: leading 1>/tmp/x then echo > manifest" "$ec" 2

# Block N-3: echo with a fd-numbered redirect (1>) directly into a manifest
ec=$(get_exit_code 'echo foo 1> nazgul/tasks/TASK-001.md')
assert_exit_code "blocked N-3: echo foo 1> manifest (fd-numbered redirect)" "$ec" 2

# Allow N-4: leading fd redirect to a non-manifest target, no manifest write
ec=$(get_exit_code '2>/tmp/e echo foo')
assert_exit_code "allowed N-4: 2>/tmp/e echo foo (no manifest target)" "$ec" 0

# --- Category 9: leading VAR=value env assignments ---
# Block O-1: a leading assignment must not steal the command word from echo
ec=$(get_exit_code 'FOO=1 echo ok > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked O-1: FOO=1 echo ok > manifest (leading env assignment)" "$ec" 2

# Block O-2: multiple leading assignments then echo
ec=$(get_exit_code 'A=1 B=2 echo ok > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked O-2: A=1 B=2 echo ok > manifest" "$ec" 2

# --- Category 10: single-quote atomicity (a > inside single quotes is DATA) ---
# Allow P-1: the >> lives inside single quotes → not a redirect → no manifest write.
# (Regression guard: confirms in_sq toggles correctly via the '\'' shell-escape idiom.)
ec=$(get_exit_code "printf '%s' '>> nazgul/tasks/TASK-001.md'")
assert_exit_code "allowed P-1: printf '%s' '>> manifest' (redirect is single-quoted data)" "$ec" 0

# Block P-2: a real redirect AFTER a single-quoted span still blocks (sq closes properly).
ec=$(get_exit_code "echo 'hi there' > nazgul/tasks/TASK-001.md")
assert_exit_code "blocked P-2: echo 'hi there' > manifest (real redirect after sq span)" "$ec" 2

# --- Category 11: fd_target_pending must not leak across a segment separator ---
# Block Q-1: an fd-dup (>&) as the last token of segment 1 leaves fd_target_pending
# set; reset_segment() must clear it so the echo in segment 2 still registers and the
# manifest write blocks. (Defensive — the minimal valid-shell trigger is a syntax error.)
ec=$(get_exit_code 'echo x >& ; echo y > nazgul/tasks/TASK-001.md')
assert_exit_code "blocked Q-1: fd-dup before ';' does not swallow next segment's echo" "$ec" 2

# --- Category 12: MF-022 funnel — mv/cp targeting a task manifest (secondary,
# defense-in-depth layer; the structural fix is the stop-hook reconciliation) ---
# Block R-1: mv forging a manifest into place
ec=$(get_exit_code 'mv fake.md nazgul/tasks/TASK-005.md')
assert_exit_code "blocked R-1: mv fake.md nazgul/tasks/TASK-005.md (manifest funnel)" "$ec" 2
output=$(run_guard 'mv fake.md nazgul/tasks/TASK-005.md')
assert_contains "reason R-1" "$output" "NAZGUL SAFETY"

# Block R-2: cp forging a manifest into place
ec=$(get_exit_code 'cp fake.md nazgul/tasks/TASK-005.md')
assert_exit_code "blocked R-2: cp fake.md nazgul/tasks/TASK-005.md (manifest funnel)" "$ec" 2
output=$(run_guard 'cp fake.md nazgul/tasks/TASK-005.md')
assert_contains "reason R-2" "$output" "NAZGUL SAFETY"

# Block R-3: mv with a flag before the source (flag must not be mistaken for the target)
ec=$(get_exit_code 'mv -f fake.md nazgul/tasks/TASK-005.md')
assert_exit_code "blocked R-3: mv -f fake.md nazgul/tasks/TASK-005.md" "$ec" 2

# Block R-4: ./ prefixed manifest target
ec=$(get_exit_code 'cp fake.md ./nazgul/tasks/TASK-005.md')
assert_exit_code "blocked R-4: cp fake.md ./nazgul/tasks/TASK-005.md (./ prefix)" "$ec" 2

# Allow R-5: cp READING from a manifest (manifest is the source, not the target)
ec=$(get_exit_code 'cp nazgul/tasks/TASK-005.md /tmp/backup.md')
assert_exit_code "allowed R-5: cp nazgul/tasks/TASK-005.md /tmp/backup.md (manifest is source)" "$ec" 0

# Allow R-6: mv/cp with no manifest path anywhere
ec=$(get_exit_code 'mv src.txt /tmp/dest.txt')
assert_exit_code "allowed R-6: mv src.txt /tmp/dest.txt (no manifest involved)" "$ec" 0

# Allow R-7: mv reading from a manifest to a non-manifest destination
ec=$(get_exit_code 'mv nazgul/tasks/TASK-005.md /tmp/archived-005.md')
assert_exit_code "allowed R-7: mv nazgul/tasks/TASK-005.md /tmp/archived-005.md (manifest is source)" "$ec" 0

# --- TASK-003 (Defect 1a): fork-free `[[ =~ ]]` matching must be verdict-
# preserving, not just faster — plan.md V1/C1 pins the three ways a naive
# `echo|grep` -> `[[ =~ ]]` swap diverges, and both directions of the
# check_pattern line-safety requirement. ---

# V1-pin (a): \s -> [[:space:]] must still match runs of multiple spaces, not
# just a single \s+ occurrence (GNU-only \s is undefined in POSIX regcomp).
ec=$(get_exit_code 'rm  -rf   /')
assert_exit_code "blocked V1-a: rm  -rf   / (multiple spaces, [[:space:]]+ pin)" "$ec" 2
output=$(run_guard 'rm  -rf   /')
assert_contains "reason V1-a" "$output" "NAZGUL SAFETY"

# V1-pin (b): case-insensitivity must survive the swap via scoped nocasematch.
ec=$(get_exit_code 'mysql -e "drop table users"')
assert_exit_code "blocked V1-b: lowercase mysql -e drop table users (nocasematch pin)" "$ec" 2
output=$(run_guard 'mysql -e "drop table users"')
assert_contains "reason V1-b" "$output" "NAZGUL SAFETY"

# V1-pin (c): grep's line-oriented semantics must be preserved — a $-anchored
# check_pattern rule still fires on an interior line of a multi-line command
# (the guard blocks this today; a whole-string swap would fail open).
ec=$(get_exit_code "$(printf 'echo hi\nrm -rf .\necho bye')")
assert_exit_code "blocked V1-c: multiline command, rm -rf . on interior line" "$ec" 2

# C1 over-block pin (d): a `.*`-bearing check_pattern rule must NOT span lines.
# dd if= on one line and an unrelated of=/dev/ mention on a much later line
# must not block (a naive whole-string swap would span the newline).
ec=$(get_exit_code "$(printf 'dd if=/tmp/disk.img bs=4M\necho step one\necho step two\necho mentions of=/dev/zero in passing')")
assert_exit_code "allowed C1-d: dd if= and of=/dev/ on unrelated lines (no over-block)" "$ec" 0

# C1 over-block pin (e): same direction as (d) for the curl|sh rule.
ec=$(get_exit_code "$(printf 'curl -sL https://example.com/install.sh -o /tmp/install.sh\necho done downloading\ncat /tmp/install.sh | sh')")
assert_exit_code "allowed C1-e: curl and | sh on unrelated lines (no over-block)" "$ec" 0

# C1 item 4 pin: check_sql_destructive keeps WHOLE-COMMAND matching (never
# line-iterated, per FEAT-019). A DB-CLI token starting one line and a DROP
# TABLE keyword starting a different line must still block, proving the
# anchors' bracket negations tolerate an embedded newline under regexec.
ec=$(get_exit_code "$(printf 'psql\nDROP TABLE users;')")
assert_exit_code "blocked C1-sql: DB-CLI token and DROP TABLE on separate lines" "$ec" 2
output=$(run_guard "$(printf 'psql\nDROP TABLE users;')")
assert_contains "reason C1-sql" "$output" "NAZGUL SAFETY"

# --- AC1: differential verdict harness. Every command string this suite has
# exercised the guard with (recorded above via _record_exercised, including
# the six pins just above) is replayed against BOTH the pre-fix guard, pinned
# to the Wave-1 Base SHA (the manifest's own documented common ancestor, and
# since this task is a single commit on top of it, genuinely the pre-fix file
# forever — `git show HEAD:...` would collapse to a self-comparison the
# instant the fix is committed, since HEAD then IS the post-fix blob) and the
# guard in the working tree. Exit code AND full stderr must be byte-identical
# for every case — "still green" is not sufficient, the verdicts themselves
# are diffed. ---
PRE_FIX_BASE_SHA="5483d70a1c2bd11c4bdaee813369bb7c5afacc5c"
GUARD_OLD="$(mktemp -t pre-tool-guard-old.XXXXXX)"
trap 'rm -f "$EXERCISED_LOG" "$GUARD_OLD"' EXIT
git -C "$REPO_ROOT" show "$PRE_FIX_BASE_SHA":scripts/pre-tool-guard.sh > "$GUARD_OLD"

diff_verdict() {
  local mode="$1" cmd="$2"
  local old_ec=0 new_ec=0 old_err new_err
  if [ "$mode" = "json" ]; then
    old_err=$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | bash "$GUARD_OLD" 2>&1 >/dev/null) || old_ec=$?
    new_err=$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | bash "$GUARD" 2>&1 >/dev/null) || new_ec=$?
  else
    old_err=$(echo "$cmd" | bash "$GUARD_OLD" 2>&1 >/dev/null) || old_ec=$?
    new_err=$(echo "$cmd" | bash "$GUARD" 2>&1 >/dev/null) || new_ec=$?
  fi
  if [ "$old_ec" = "$new_ec" ] && [ "$old_err" = "$new_err" ]; then
    _pass "differential [$mode] exit=$new_ec: ${cmd:0:80}"
  else
    _fail "differential [$mode]: ${cmd:0:80}" \
      "old exit=$old_ec  new exit=$new_ec" \
      "old stderr: ${old_err:0:200}" \
      "new stderr: ${new_err:0:200}"
  fi
}

# Floor assertion: if _record_exercised ever silently stopped firing (mktemp
# failure, a refactor changing how run_guard/get_exit_code* are called), this
# loop would iterate zero times and report_results would still print a clean
# "0/0 passed" — a silent shrink, not a failure. Assert the recorded count by a
# known-good floor, not by trusting the loop to run at all.
EXERCISED_COUNT=$(tr -dc '\0' < "$EXERCISED_LOG" | wc -c | tr -d ' ')
if [ "$EXERCISED_COUNT" -ge 160 ]; then
  _pass "differential harness recorded >=160 commands (got $EXERCISED_COUNT)"
else
  _fail "differential harness recorded >=160 commands" "got $EXERCISED_COUNT"
fi

# No dedup (associative arrays are bash 4+ only, and this must also pass under
# /bin/bash 3.2.57): a command exercised twice by the suite above is simply
# diffed twice. Redundant, not incorrect.
while IFS= read -r -d '' _rec; do
  _mode="${_rec%%$'\x1f'*}"
  _cmd="${_rec#*$'\x1f'}"
  diff_verdict "$_mode" "$_cmd"
done < "$EXERCISED_LOG"

report_results
