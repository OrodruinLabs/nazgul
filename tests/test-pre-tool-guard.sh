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

report_results
