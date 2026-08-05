#!/usr/bin/env bash
set -euo pipefail

# Nazgul Test Runner — discovers and runs all test-*.sh files
# Usage:
#   tests/run-tests.sh                  # Run all tests
#   tests/run-tests.sh --filter=guard   # Run only tests matching "guard"
#
# Exit codes:
#   0  every checked file passed
#   1  at least one checked file failed
#   2  NOTHING CHECKED — the filter matched no file, or no test file was discovered
#   3  internal coverage-accounting defect (scanned != skipped + checked)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER=""

for arg in "$@"; do
  case "$arg" in
    --filter=*) FILTER="${arg#--filter=}" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

echo "================================"
echo "  Nazgul Integration Test Suite"
echo "================================"
echo ""

SCANNED=0
CHECKED=0
PASSED_FILES=0
FAILED_FILES=0
SKIP_FILTERED=0
SKIP_UNREADABLE=0
FAILED_NAMES=()
UNREADABLE_NAMES=()

for test_file in "$SCRIPT_DIR"/test-*.sh; do
  # A broken symlink is a candidate that exists and cannot be read — not a non-candidate.
  if [ ! -e "$test_file" ] && [ ! -L "$test_file" ]; then
    continue
  fi
  name=$(basename "$test_file")
  SCANNED=$((SCANNED + 1))

  if [ -n "$FILTER" ] && ! grep -qF -e "$FILTER" <<<"$name"; then
    SKIP_FILTERED=$((SKIP_FILTERED + 1))
    continue
  fi

  if [ ! -f "$test_file" ] || [ ! -r "$test_file" ]; then
    SKIP_UNREADABLE=$((SKIP_UNREADABLE + 1))
    UNREADABLE_NAMES+=("$name")
    continue
  fi

  CHECKED=$((CHECKED + 1))
  echo ""

  if bash "$test_file"; then
    PASSED_FILES=$((PASSED_FILES + 1))
  else
    FAILED_FILES=$((FAILED_FILES + 1))
    FAILED_NAMES+=("$name")
  fi
done

SKIPPED=$((SKIP_FILTERED + SKIP_UNREADABLE))

# Fixed-grammar coverage line, always the last line of stdout (TRD §6).
emit_coverage_line() {
  printf 'run-tests: %d scanned, %d skipped (filtered-out=%d, unreadable=%d), %d checked, %d findings\n' \
    "$SCANNED" "$SKIPPED" "$SKIP_FILTERED" "$SKIP_UNREADABLE" "$CHECKED" "$FAILED_FILES"
}

echo ""
echo "================================"
echo "  Summary"
echo "================================"
echo "$CHECKED files checked, $PASSED_FILES passed, $FAILED_FILES failed"

if [ "$SKIP_UNREADABLE" -gt 0 ]; then
  echo ""
  echo "Unreadable test files (skipped, not checked):"
  for name in "${UNREADABLE_NAMES[@]}"; do
    echo "  - $name"
  done
fi

if [ "$FAILED_FILES" -gt 0 ]; then
  echo ""
  echo "Failed test files:"
  for name in "${FAILED_NAMES[@]}"; do
    echo "  - $name"
  done
fi

echo ""

if [ "$SCANNED" -ne $((SKIPPED + CHECKED)) ]; then
  echo "run-tests: INTERNAL — coverage accounting mismatch: $SCANNED scanned != $SKIPPED skipped + $CHECKED checked" >&2
  emit_coverage_line
  exit 3
fi

if [ "$CHECKED" -eq 0 ]; then
  if [ "$SCANNED" -eq 0 ]; then
    echo "run-tests: NOTHING CHECKED — no test files discovered in $SCRIPT_DIR" >&2
  elif [ -n "$FILTER" ] && [ "$SKIP_FILTERED" -eq "$SCANNED" ]; then
    echo "run-tests: NOTHING CHECKED — all $SCANNED candidates skipped; no test files matched filter '$FILTER'" >&2
  elif [ -n "$FILTER" ]; then
    echo "run-tests: NOTHING CHECKED — matching candidates for filter '$FILTER' were unreadable or non-regular" >&2
  else
    echo "run-tests: NOTHING CHECKED — all $SCANNED candidates skipped" >&2
  fi
  emit_coverage_line
  exit 2
fi

if [ "$FAILED_FILES" -gt 0 ]; then
  emit_coverage_line
  exit 1
fi

echo "All tests passed."
emit_coverage_line
exit 0
