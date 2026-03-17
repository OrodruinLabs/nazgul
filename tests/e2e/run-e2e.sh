#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "================================"
echo "  Hydra E2E Test Suite"
echo "  WARNING: These tests call"
echo "  claude -p and cost money."
echo "================================"
echo ""

# Verify claude CLI is available
if ! command -v claude &>/dev/null; then
  echo "SKIP: claude CLI not found. E2E tests require Claude Code."
  exit 0
fi

FILTER=""
for arg in "$@"; do
  case "$arg" in
    --filter=*) FILTER="${arg#--filter=}" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

TOTAL=0
PASSED=0
FAILED=0

for test_file in "$SCRIPT_DIR"/test-*.sh; do
  [ -f "$test_file" ] || continue
  name=$(basename "$test_file" .sh)

  if [ -n "$FILTER" ] && ! echo "$name" | grep -q "$FILTER"; then
    continue
  fi

  TOTAL=$((TOTAL + 1))
  echo "--- $name ---"
  if bash "$test_file"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

echo "================================"
echo "E2E Results: $PASSED/$TOTAL passed"
[ "$FAILED" -eq 0 ]
