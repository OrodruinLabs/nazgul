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
# Test (d): every "- **rule**" bullet carries a tier annotation
# (Section 10 Branch Isolation uses bullet format, not numbered format)
# Excludes lines inside fenced code blocks (Recovery Pointer template, etc.)
# and mode-name bullets that are plain descriptors, not enforcement rules.
# ---------------------------------------------------------------------------
missing_bullet_tier=0
while IFS= read -r line; do
  if ! echo "$line" | grep -qE '\[(enforced|hook-driven only|advisory)\]'; then
    printf "  MISSING TIER (bullet): %s\n" "$line"
    missing_bullet_tier=1
  fi
done < <(awk '/^```/{in_fence=!in_fence;next} !in_fence && /^- \*\*/' "$RULES_FILE" \
           | grep -v '^- \*\*\(HITL\|AFK\|YOLO\)\b')

if [ "$missing_bullet_tier" -eq 0 ]; then
  _pass "every bullet-format rule line carries a tier annotation"
else
  _fail "every bullet-format rule line carries a tier annotation" \
    "one or more bullet-format rule lines above are missing a tier label"
fi

# ---------------------------------------------------------------------------
# Test (c): the count of [advisory] annotations is exactly 9
# The legend table itself contains [advisory] as a label definition (1 count).
# Rule annotations add to that (incl. §11 Conductor's engine-selection, hard-stops,
# wave-parallelism, and graph-only-invariant bullets — all four are agent-invoked,
# not hook-gated, per FEAT-007's tier-honesty correction; plus §12's wave-digest
# bullet, the one Enforced-Conductor layer that stays advisory). Total must be
# exactly 9.
# ---------------------------------------------------------------------------
ADVISORY_COUNT=$(grep -c '\[advisory\]' "$RULES_FILE" || true)
if [ "$ADVISORY_COUNT" -eq 9 ]; then
  _pass "[advisory] annotation count is exactly 9 (found: $ADVISORY_COUNT)"
else
  _fail "[advisory] annotation count is exactly 9" \
    "found $ADVISORY_COUNT occurrences of [advisory] — expected exactly 9"
fi

# ---------------------------------------------------------------------------
# Test (e): the Conductor section exists with honest tiers. The two hard
# stops and wave parallelism are agent-invoked (no PreToolUse guard or
# stop-hook forces the call), so per the legend they are [advisory], not
# [enforced]/[hook-driven only] — same as the graph-only invariant.
# ---------------------------------------------------------------------------
assert_file_contains \
  "RULES.md has a Conductor Execution Engine section" \
  "$RULES_FILE" \
  "## 11. Conductor Execution Engine"

assert_file_contains \
  "Conductor hard stops are tagged [advisory] (agent-invoked, not hook-gated)" \
  "$RULES_FILE" \
  'hard stops are unconditional.*`\[advisory\]`'

assert_file_contains \
  "Conductor wave parallelism is tagged [advisory] (agent-invoked, not hook-gated)" \
  "$RULES_FILE" \
  'Wave parallelism.*`\[advisory\]`'

assert_file_contains \
  "Conductor graph-only invariant is tagged [advisory], not a mechanical guard" \
  "$RULES_FILE" \
  "Graph-only invariant: the Conductor never holds file bodies"

# ---------------------------------------------------------------------------
# Test (f): the Conductor Enforcement section (FEAT-007 follow-up, "Enforced
# Conductor") exists with honest tiers. Dispatch + re-work guards are real
# PreToolUse hooks that deny (exit 2) mechanically -> [enforced]. Orphan
# detection and team routing are wired into real hook events / an existing
# hook-driven mechanism but only detect/observe rather than block -> [hook-
# driven only]. The wave digest is read-only convenience nothing forces the
# Conductor to consult -> [advisory], same as §11.
# ---------------------------------------------------------------------------
assert_file_contains \
  "RULES.md has a Conductor Enforcement section" \
  "$RULES_FILE" \
  "## 12. Conductor Enforcement"

assert_file_contains \
  "Dispatch guard is tagged [enforced]" \
  "$RULES_FILE" \
  'Dispatch guard.*`\[enforced\]`'

assert_file_contains \
  "Re-work guard is tagged [enforced]" \
  "$RULES_FILE" \
  'Re-work guard.*`\[enforced\]`'

assert_file_contains \
  "Orphan detection is tagged [hook-driven only]" \
  "$RULES_FILE" \
  'Orphan detection.*`\[hook-driven only\]`'

assert_file_contains \
  "Team routing is tagged [hook-driven only]" \
  "$RULES_FILE" \
  'Team routing.*`\[hook-driven only\]`'

assert_file_contains \
  "Wave digest is tagged [advisory]" \
  "$RULES_FILE" \
  'Wave digest.*`\[advisory\]`'

assert_file_contains \
  "Conductor Enforcement cross-references the two unconditional hard stops" \
  "$RULES_FILE" \
  "unconditional hard stops"

report_results
