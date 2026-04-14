#!/usr/bin/env bash
# Nazgul Test Assertions Library
# Sourced by all test-*.sh files. Tracks pass/fail counts and prints results.

TESTS_RUN=0
TESTS_FAILED=0
TESTS_PASSED=0

_pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf "  PASS: %s\n" "$1"
}

_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "  FAIL: %s\n" "$1"
  shift
  for line in "$@"; do
    printf "        %s\n" "$line"
  done
}

assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "expected: '$expected'" "  actual: '$actual'"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    _pass "$name"
  else
    _fail "$name" "expected to contain: '$needle'" "  in: '${haystack:0:200}'"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    _fail "$name" "expected NOT to contain: '$needle'" "  in: '${haystack:0:200}'"
  else
    _pass "$name"
  fi
}

assert_exit_code() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" -eq "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "expected exit code: $expected" "  actual exit code: $actual"
  fi
}

assert_file_exists() {
  local name="$1" path="$2"
  if [ -f "$path" ]; then
    _pass "$name"
  else
    _fail "$name" "file does not exist: $path"
  fi
}

assert_file_not_exists() {
  local name="$1" path="$2"
  if [ ! -f "$path" ]; then
    _pass "$name"
  else
    _fail "$name" "file should not exist: $path"
  fi
}

assert_json_field() {
  local name="$1" file="$2" jq_path="$3" expected="$4"
  if [ ! -f "$file" ]; then
    _fail "$name" "JSON file not found: $file"
    return
  fi
  local actual
  actual=$(jq -r "$jq_path" "$file" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "jq '$jq_path' expected: '$expected'" "  actual: '$actual'"
  fi
}

assert_file_contains() {
  local name="$1" file="$2" pattern="$3"
  if [ ! -f "$file" ]; then
    _fail "$name" "file not found: $file"
    return
  fi
  if grep -q "$pattern" "$file"; then
    _pass "$name"
  else
    _fail "$name" "file '$file' does not contain pattern: '$pattern'"
  fi
}

assert_file_not_contains() {
  local name="$1" file="$2" pattern="$3"
  if [ ! -f "$file" ]; then
    _pass "$name"
    return
  fi
  if grep -q "$pattern" "$file"; then
    _fail "$name" "file '$file' should not contain pattern: '$pattern'"
  else
    _pass "$name"
  fi
}

report_results() {
  echo ""
  echo "---"
  printf "%s: %d/%d passed" "${TEST_NAME:-tests}" "$TESTS_PASSED" "$TESTS_RUN"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    printf " (%d FAILED)" "$TESTS_FAILED"
    echo ""
    return 1
  fi
  echo ""
  return 0
}
