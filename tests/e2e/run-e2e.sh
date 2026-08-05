#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Same grammar and exit codes as tests/run-tests.sh and tests/smoke/run-smoke.sh:
# 0 pass / 1 failures / 2 NOTHING CHECKED / 3 accounting mismatch.
emit_coverage_line() {
  printf 'run-e2e: %d scanned, %d skipped (filtered-out=%d, no-claude-cli=%d), %d checked, %d findings\n' \
    "$SCANNED" "$((SKIP_FILTERED + SKIP_NO_CLI))" "$SKIP_FILTERED" "$SKIP_NO_CLI" "$CHECKED" "$FAILED"
}

HAVE_CLI=1
command -v claude >/dev/null 2>&1 || HAVE_CLI=0

for test_file in "$SCRIPT_DIR"/test-*.sh; do
  [ -e "$test_file" ] || [ -L "$test_file" ] || continue
  name=$(basename "$test_file" .sh)
  SCANNED=$((SCANNED + 1))

  if [ -n "$FILTER" ] && ! grep -q -e "$FILTER" <<<"$name"; then
    SKIP_FILTERED=$((SKIP_FILTERED + 1))
    continue
  fi

  if [ "$HAVE_CLI" -eq 0 ]; then
    SKIP_NO_CLI=$((SKIP_NO_CLI + 1))
    echo "  SKIP: $name (claude CLI not on PATH — not checked)"
    continue
  fi

  CHECKED=$((CHECKED + 1))
  echo "--- $name ---"
  if bash "$test_file"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

echo "================================"
echo "E2E Results: $PASSED/$CHECKED passed"

SKIPPED=$((SKIP_FILTERED + SKIP_NO_CLI))
if [ "$SCANNED" -ne $((SKIPPED + CHECKED)) ]; then
  echo "run-e2e: INTERNAL — coverage accounting mismatch: $SCANNED scanned != $SKIPPED skipped + $CHECKED checked" >&2
  emit_coverage_line
  exit 3
fi

if [ "$CHECKED" -eq 0 ]; then
  if [ "$SCANNED" -eq 0 ]; then
    echo "run-e2e: NOTHING CHECKED — no e2e test files discovered in $SCRIPT_DIR" >&2
  elif [ "$SKIP_NO_CLI" -gt 0 ]; then
    echo "run-e2e: NOTHING CHECKED — claude CLI not on PATH; $SKIP_NO_CLI scenario(s) never ran" >&2
  else
    echo "run-e2e: NOTHING CHECKED — all $SCANNED candidates skipped; no e2e test matched filter '$FILTER'" >&2
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
