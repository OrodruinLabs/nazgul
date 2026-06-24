#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-rules-tiers"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

RULES_FILE="$REPO_ROOT/RULES.md"

# ---------------------------------------------------------------------------
# Test (a): RULES.md does NOT contain the old overclaiming line
# ---------------------------------------------------------------------------
assert_file_not_contains \
  "RULES.md does not claim 'Every rule here is checked by a hook, agent, or script'" \
  "$RULES_FILE" \
  "Every rule here is checked by a hook, agent, or script"

# ---------------------------------------------------------------------------
# Test (b): every numbered rule line carries exactly one tier string
# A "numbered rule line" is a line matching: ^[0-9]+\. \*\* (bold lead-in)
# The Recovery Read Order items use plain text, not bold — excluded by the pattern.
# ---------------------------------------------------------------------------
TIER_PATTERN='\[enforced\]\|\[hook-driven only\]\|\[advisory\]'

missing_tier=0
while IFS= read -r line; do
  if ! echo "$line" | grep -q "$TIER_PATTERN"; then
    printf "  MISSING TIER: %s\n" "$line"
    missing_tier=1
  fi
done < <(grep '^\([0-9]\+\)\. \*\*' "$RULES_FILE")

if [ "$missing_tier" -eq 0 ]; then
  _pass "every numbered rule line carries a tier annotation"
else
  _fail "every numbered rule line carries a tier annotation" \
    "one or more numbered rule lines above are missing a tier label"
fi

# ---------------------------------------------------------------------------
# Test (c): the count of [advisory] annotations is at most 4
# The legend table itself contains [advisory] as a label definition (1 count).
# Rule annotations add to that. Total must be <= 4.
# ---------------------------------------------------------------------------
ADVISORY_COUNT=$(grep -c '\[advisory\]' "$RULES_FILE" || true)
if [ "$ADVISORY_COUNT" -le 4 ]; then
  _pass "[advisory] annotation count is at most 4 (found: $ADVISORY_COUNT)"
else
  _fail "[advisory] annotation count is at most 4" \
    "found $ADVISORY_COUNT occurrences of [advisory] — expected <= 4"
fi

report_results
