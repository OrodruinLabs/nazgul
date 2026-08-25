#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="${NAZGUL_E2E_TEST_DIR:-$SCRIPT_DIR}"

echo "================================"
echo "  Nazgul E2E Test Suite"
echo "  WARNING: These tests call"
echo "  claude -p and cost money."
echo "================================"
echo ""

FILTER=""
for arg in "$@"; do
  case "$arg" in
    --filter=*) FILTER="${arg#--filter=}" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

SCANNED=0
CHECKED=0
PASSED=0
FAILED=0
SKIP_FILTERED=0
SKIP_NO_CLI=0
SKIP_NOT_A_FILE=0
SKIP_UNREADABLE=0

# Same grammar and exit codes as tests/run-tests.sh and tests/smoke/run-smoke.sh:
# 0 pass / 1 failures / 2 NOTHING CHECKED / 3 accounting mismatch.
emit_coverage_line() {
  printf 'run-e2e: %d scanned, %d skipped (filtered-out=%d, no-claude-cli=%d, not-a-file=%d, unreadable=%d), %d checked, %d findings\n' \
    "$SCANNED" "$((SKIP_FILTERED + SKIP_NO_CLI + SKIP_NOT_A_FILE + SKIP_UNREADABLE))" \
    "$SKIP_FILTERED" "$SKIP_NO_CLI" "$SKIP_NOT_A_FILE" "$SKIP_UNREADABLE" "$CHECKED" "$FAILED"
}

HAVE_CLI=1
command -v claude >/dev/null 2>&1 || HAVE_CLI=0

for test_file in "$TEST_DIR"/test-*.sh; do
  [ -e "$test_file" ] || [ -L "$test_file" ] || continue
  name=$(basename "$test_file" .sh)
  SCANNED=$((SCANNED + 1))

  if [ -n "$FILTER" ] && ! grep -qF -e "$FILTER" <<<"$name"; then
    SKIP_FILTERED=$((SKIP_FILTERED + 1))
    continue
  fi

  if [ ! -f "$test_file" ]; then
    SKIP_NOT_A_FILE=$((SKIP_NOT_A_FILE + 1))
    echo "  SKIP: $name (not a regular file — not checked)"
    continue
  fi

  if [ ! -r "$test_file" ]; then
    SKIP_UNREADABLE=$((SKIP_UNREADABLE + 1))
    echo "  SKIP: $name (unreadable — not checked)"
    continue
  fi

  if [ "$HAVE_CLI" -eq 0 ]; then
    SKIP_NO_CLI=$((SKIP_NO_CLI + 1))
    echo "  SKIP: $name (claude CLI not on PATH — not checked)"
    continue
  fi

  CHECKED=$((CHECKED + 1))
  echo "--- $name ---"
  if bash "$test_file" </dev/null; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

echo "================================"
echo "E2E Results: $PASSED/$CHECKED passed"

SKIPPED=$((SKIP_FILTERED + SKIP_NO_CLI + SKIP_NOT_A_FILE + SKIP_UNREADABLE))
if [ "$SCANNED" -ne $((SKIPPED + CHECKED)) ]; then
  echo "run-e2e: INTERNAL — coverage accounting mismatch: $SCANNED scanned != $SKIPPED skipped + $CHECKED checked" >&2
  emit_coverage_line
  exit 3
fi

if [ "$CHECKED" -eq 0 ]; then
  if [ "$SCANNED" -eq 0 ]; then
    echo "run-e2e: NOTHING CHECKED — no e2e test files discovered in $TEST_DIR" >&2
  elif [ "$SKIP_NO_CLI" -gt 0 ]; then
    echo "run-e2e: NOTHING CHECKED — claude CLI not on PATH; $SKIP_NO_CLI scenario(s) never ran" >&2
  else
    echo "run-e2e: NOTHING CHECKED — all $SCANNED candidates were filtered out or ineligible to run" >&2
  fi
  emit_coverage_line
  exit 2
fi

if [ "$FAILED" -gt 0 ]; then
  emit_coverage_line
  exit 1
fi
emit_coverage_line
exit 0
