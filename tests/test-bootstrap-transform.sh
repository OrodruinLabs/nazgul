#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-bootstrap-transform"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

TRANSFORM="$REPO_ROOT/scripts/bootstrap-transform.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/bootstrap-transform"

# Working copy of input (transform mutates in place). stderr capture lives
# OUTSIDE $WORK so the diff pass doesn't need to exclude it — keeping the diff
# strict catches regressions in any future bundle path (including `.claude/`).
# ASSERT_WORK is allocated later but declared here so one consolidated trap
# covers every path.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-transform-XXXXXX")
ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/bootstrap-transform-err.XXXXXX")
ASSERT_WORK=""
_cleanup() {
  rm -rf "$WORK" "${ASSERT_WORK:-}" 2>/dev/null || true
  rm -f "$ERR_FILE" 2>/dev/null || true
}
trap _cleanup EXIT
cp -R "$FIXTURE_DIR/input/." "$WORK/"

# Run transform
if ! bash "$TRANSFORM" "$WORK" 2>"$ERR_FILE"; then
  _fail "transform exits 0" "$(cat "$ERR_FILE")"
  report_results
  exit 1
fi
_pass "transform exits 0"

# Diff actual vs expected — no excludes needed now that the err file lives
# outside $WORK. If a fixture adds `.claude/` content later, it gets diffed too.
DIFF_OUTPUT=$(diff -r "$FIXTURE_DIR/expected" "$WORK" 2>&1 || true)

if [ -z "$DIFF_OUTPUT" ]; then
  _pass "output matches expected"
else
  _fail "output matches expected" "diff:" "$DIFF_OUTPUT"
fi

assert_file_not_exists "manifest.md dropped from bundle" "$WORK/docs/manifest.md"

# ---------------------------------------------------------------------
# Assertion test: if a Nazgul token survives all rules, transform must fail
# ---------------------------------------------------------------------
ASSERT_WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-assert-XXXXXX")
mkdir -p "$ASSERT_WORK/docs"
cat > "$ASSERT_WORK/docs/evil.md" <<'EVIL'
# Doc
This file uses NAZGUL in uppercase intentionally.
EVIL

# Single invocation: capture combined output AND exit code.
# Can't use `set +e` with `ASSERT_OUTPUT=$(...)` because the assignment wraps
# the command; use the explicit-capture pattern instead.
ASSERT_OUTPUT=$(bash "$TRANSFORM" "$ASSERT_WORK" 2>&1; echo "__EC=$?")
ASSERT_EC="${ASSERT_OUTPUT##*__EC=}"
ASSERT_OUTPUT="${ASSERT_OUTPUT%__EC=*}"

assert_exit_code "assertion fires on residual Nazgul token" "$ASSERT_EC" 3
assert_contains "error message names file" "$ASSERT_OUTPUT" "evil.md"
assert_contains "error message suggests scrub-map edit" "$ASSERT_OUTPUT" "scripts/lib/bootstrap-scrub-map.sh"

report_results
