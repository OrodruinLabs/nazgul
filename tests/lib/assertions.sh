#!/usr/bin/env bash
# Nazgul Test Assertions Library
# Sourced by all test-*.sh files. Tracks pass/fail counts and prints results.

TESTS_RUN=0
TESTS_FAILED=0
TESTS_PASSED=0
TESTS_SKIPPED=0
NOTHING_CHECKED_EXIT=2

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

# A check the environment could not run. Counted apart from pass/fail so an absent
# tool or an unproducible condition never reads as a check that passed (MF-057).
_skip() {
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  printf "  SKIP: %s\n" "$1"
}

# grep exit >=2 means it could not evaluate the needle at all (a `-`-leading needle
# is read as an option; a malformed BRE aborts) — a test defect, not a no-match.
_assert_unevaluable() {
  _fail "$1" "grep could not evaluate the needle/pattern (exit $2) — test defect, not a negative result" \
    "  needle: '$3'" "  fix: the needle is unparseable as given; pass it via -e/-- or escape it"
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
  local name="$1" haystack="$2" needle="$3" rc=0
  # String assertions are literal: callers do not need to escape BRE syntax.
  # Here-string, not `echo | grep`: grep -q's early exit SIGPIPEs the writer, which
  # pipefail reports as failure once the haystack exceeds the pipe buffer (~64KB).
  grep -qF -e "$needle" <<<"$haystack" || rc=$?
  case "$rc" in
    0) _pass "$name" ;;
    1) _fail "$name" "expected to contain: '$needle'" "  in: '${haystack:0:200}'" ;;
    *) _assert_unevaluable "$name" "$rc" "$needle" ;;
  esac
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3" rc=0
  # String assertions are literal: callers do not need to escape BRE syntax.
  grep -qF -e "$needle" <<<"$haystack" || rc=$?
  case "$rc" in
    0) _fail "$name" "expected NOT to contain: '$needle'" "  in: '${haystack:0:200}'" ;;
    1) _pass "$name" ;;
    *) _assert_unevaluable "$name" "$rc" "$needle" ;;
  esac
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

assert_dir_exists() {
  local name="$1" path="$2"
  if [ -d "$path" ]; then
    _pass "$name"
  else
    _fail "$name" "directory does not exist: $path"
  fi
}

assert_dir_not_exists() {
  local name="$1" path="$2"
  if [ ! -d "$path" ]; then
    _pass "$name"
  else
    _fail "$name" "directory should not exist: $path"
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
  local name="$1" file="$2" pattern="$3" rc=0
  # File assertions intentionally accept a basic regular expression (BRE).
  if [ ! -f "$file" ]; then
    _fail "$name" "file not found: $file"
    return
  fi
  grep -q -e "$pattern" "$file" || rc=$?
  case "$rc" in
    0) _pass "$name" ;;
    1) _fail "$name" "file '$file' does not contain pattern: '$pattern'" ;;
    *) _assert_unevaluable "$name" "$rc" "$pattern" ;;
  esac
}

assert_file_not_contains() {
  local name="$1" file="$2" pattern="$3" rc=0
  # File assertions intentionally accept a basic regular expression (BRE).
  # An absent file is "never looked", not "looked and found none" (RULES §15).
  if [ ! -f "$file" ]; then
    _fail "$name" "file not found: $file — absence cannot stand in for a negative result"
    return
  fi
  grep -q -e "$pattern" "$file" || rc=$?
  case "$rc" in
    0) _fail "$name" "file '$file' should not contain pattern: '$pattern'" ;;
    1) _pass "$name" ;;
    *) _assert_unevaluable "$name" "$rc" "$pattern" ;;
  esac
}

report_results() {
  echo ""
  echo "---"
  printf "%s: %d/%d passed" "${TEST_NAME:-tests}" "$TESTS_PASSED" "$TESTS_RUN"
  [ "$TESTS_SKIPPED" -gt 0 ] && printf " (%d SKIPPED — not checked)" "$TESTS_SKIPPED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    printf " (%d FAILED)" "$TESTS_FAILED"
    echo ""
    return 1
  fi
  echo ""
  # A file that asserted nothing has not passed; it has not run. Reporting success
  # here is the vacuous green the harness's own zero-match fix abolished (D-6).
  if [ "$TESTS_RUN" -eq 0 ]; then
    printf '%s: NOTHING CHECKED — 0 assertions ran (%d skipped)\n' \
      "${TEST_NAME:-tests}" "$TESTS_SKIPPED" >&2
    return "$NOTHING_CHECKED_EXIT"
  fi
  return 0
}
