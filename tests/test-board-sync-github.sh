#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-board-sync-github"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

SCRIPT="$REPO_ROOT/scripts/board-sync-github.sh"

# Test: script exists
assert_file_exists "board-sync-github.sh exists" "$SCRIPT"

# Test: script is executable
if [ -x "$SCRIPT" ]; then
  _pass "script is executable"
else
  _fail "script is executable" "chmod +x needed"
fi

# Test: script passes bash -n syntax check
SYNTAX_OUTPUT=$(bash -n "$SCRIPT" 2>&1 || true)
if bash -n "$SCRIPT" 2>/dev/null; then
  _pass "passes bash syntax check"
else
  _fail "passes bash syntax check" "$SYNTAX_OUTPUT"
fi

# Test: script passes shellcheck (warnings ok, errors not)
if command -v shellcheck >/dev/null 2>&1; then
  SC_ERRORS=$(shellcheck -S error "$SCRIPT" 2>&1 || true)
  if [ -z "$SC_ERRORS" ]; then
    _pass "passes shellcheck (no errors)"
  else
    _fail "passes shellcheck (no errors)" "$SC_ERRORS"
  fi
else
  _pass "shellcheck not installed — skipped"
fi

# Test: shows usage on no args
OUTPUT=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "shows usage on no args" "$OUTPUT" "Usage:"

# Test: shows usage on unknown command
OUTPUT=$(bash "$SCRIPT" unknown-cmd 2>&1 || true)
assert_contains "shows usage on unknown command" "$OUTPUT" "Usage:"

# Test: script has all required commands in usage
OUTPUT=$(bash "$SCRIPT" 2>&1 || true)
assert_contains "usage mentions setup" "$OUTPUT" "setup"
assert_contains "usage mentions create-issue" "$OUTPUT" "create-issue"
assert_contains "usage mentions sync-task" "$OUTPUT" "sync-task"
assert_contains "usage mentions sync-all" "$OUTPUT" "sync-all"
assert_contains "usage mentions archive-all" "$OUTPUT" "archive-all"
assert_contains "usage mentions disconnect" "$OUTPUT" "disconnect"
assert_contains "usage mentions status" "$OUTPUT" "status"

# Test: script uses set -euo pipefail
assert_file_contains "uses strict mode" "$SCRIPT" "set -euo pipefail"

report_results
