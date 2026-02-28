#!/usr/bin/env bash
set -euo pipefail

# Hydra Test Runner — discovers and runs all test-*.sh files
# Usage:
#   tests/run-tests.sh                  # Run all tests
#   tests/run-tests.sh --filter=guard   # Run only tests matching "guard"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER=""

for arg in "$@"; do
  case "$arg" in
    --filter=*) FILTER="${arg#--filter=}" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

echo "================================"
echo "  Hydra Integration Test Suite"
echo "================================"
echo ""

TOTAL_FILES=0
PASSED_FILES=0
FAILED_FILES=0
FAILED_NAMES=()

for test_file in "$SCRIPT_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  name=$(basename "$test_file")

  # Apply filter if specified
  if [ -n "$FILTER" ] && ! echo "$name" | grep -q "$FILTER"; then
    continue
  fi

  TOTAL_FILES=$((TOTAL_FILES + 1))
  echo ""

  if bash "$test_file"; then
    PASSED_FILES=$((PASSED_FILES + 1))
  else
    FAILED_FILES=$((FAILED_FILES + 1))
    FAILED_NAMES+=("$name")
  fi
done

echo ""
echo "================================"
echo "  Summary"
echo "================================"
echo "$TOTAL_FILES files run, $PASSED_FILES passed, $FAILED_FILES failed"

if [ "$FAILED_FILES" -gt 0 ]; then
  echo ""
  echo "Failed test files:"
  for name in "${FAILED_NAMES[@]}"; do
    echo "  - $name"
  done
  exit 1
fi

echo ""
echo "All tests passed."
exit 0
