#!/usr/bin/env bash
set -euo pipefail

# Test: pre-tool-guard.sh blocks dangerous commands and allows safe ones
TEST_NAME="test-pre-tool-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

GUARD="$REPO_ROOT/scripts/pre-tool-guard.sh"

run_guard() {
  local cmd="$1"
  local output
  output=$(echo "$cmd" | bash "$GUARD" 2>&1) || true
  echo "$output"
}

get_exit_code() {
  local cmd="$1"
  echo "$cmd" | bash "$GUARD" >/dev/null 2>&1
  echo $?
}

# Production path: the hook receives a JSON envelope {tool_input:{command:...}}
# on stdin (not the raw command). The guard must extract .tool_input.command
# before tokenizing — otherwise the whole command is one JSON-quoted string.
get_exit_code_json() {
  local cmd="$1"
  printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | bash "$GUARD" >/dev/null 2>&1
  echo $?
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

# --- Git force push (should exit 2) ---
for bad_cmd in \
  "git push --force origin main" \
  "git push -f origin master"; do
  ec=$(get_exit_code "$bad_cmd")
  assert_exit_code "blocked: '$bad_cmd'" "$ec" 2
  output=$(run_guard "$bad_cmd")
  assert_contains "reason for '$bad_cmd'" "$output" "NAZGUL SAFETY"
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

report_results
