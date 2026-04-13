#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-transform"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

TRANSFORM="$REPO_ROOT/scripts/bootstrap-transform.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/bootstrap-transform"

# Working copy of input (transform mutates in place)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-transform-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cp -R "$FIXTURE_DIR/input/." "$WORK/"

# Run transform
if ! bash "$TRANSFORM" "$WORK" 2>"$WORK/.err"; then
  _fail "transform exits 0" "$(cat "$WORK/.err")"
  report_results
  exit 1
fi
_pass "transform exits 0"

# Diff actual vs expected (ignore the .err file and any hidden dirs)
DIFF_OUTPUT=$(diff -r \
  --exclude='.err' \
  "$FIXTURE_DIR/expected" "$WORK" 2>&1 || true)

if [ -z "$DIFF_OUTPUT" ]; then
  _pass "output matches expected"
else
  _fail "output matches expected" "diff:" "$DIFF_OUTPUT"
fi

report_results
