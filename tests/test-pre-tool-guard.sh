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

report_results
