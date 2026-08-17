#!/usr/bin/env bash
set -uo pipefail
# Presence test for the session-level peer trust boundary (spec 1-A).
# [advisory] behaviorally; THIS test is the [enforced] presence layer —
# the exact tier split test-review-contract.sh:84-99 pins for teammate MF-059.
TEST_NAME="test-session-trust-boundary"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
echo "=== $TEST_NAME ==="

TPL="$REPO_ROOT/templates/CLAUDE.md.template"
START="$REPO_ROOT/skills/start/SKILL.md"

for f in "$TPL" "$START"; do
  if grep -q "MF-059" "$f" && grep -qi "untrusted" "$f" && grep -qi "never counts as" "$f"; then
    _pass "$(basename "$f") states the session-level peer trust boundary"
  else
    _fail "$(basename "$f") states the session-level peer trust boundary" "missing MF-059 / untrusted / never-counts-as language"
  fi
done
# The boundary must not overclaim permanence: platform-versioned wording required.
if grep -q "2.1.233" "$TPL"; then
  _pass "template boundary is platform-version-scoped, not claimed permanent"
else
  _fail "template boundary is platform-version-scoped" "no version scope found"
fi

report_results
