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
# Test (c): [advisory] count is exactly 15 — the Parallel Execution Collapse
# deleted the Conductor engine's 4 advisory bullets in the old §11 (opt-in
# engine selection, two hard stops, wave parallelism, graph-only invariant);
# their replacements in the new §11/§12 are [enforced]/[hook-driven only]
# because the checks now run as unconditional stop-hook/script conditionals
# instead of agent-protocol-invoked steps. 19 - 4 = 15.
ADVISORY_COUNT=$(grep -c '\[advisory\]' "$RULES_FILE" || true)
if [ "$ADVISORY_COUNT" -eq 15 ]; then
  _pass "[advisory] annotation count is exactly 15 (found: $ADVISORY_COUNT)"
else
  _fail "[advisory] annotation count is exactly 15" \
    "found $ADVISORY_COUNT occurrences of [advisory] — expected exactly 15"
fi

# ---------------------------------------------------------------------------
# Test (e): the Parallel Dispatch section exists with honest tiers. Batch
# selection and the two hard stops are computed by unconditional stop-hook
# bash conditionals (no agent judgment gates whether they run), so per the
# legend they are [enforced] — unlike the deleted Conductor's agent-invoked
# equivalents, which were [advisory]. The approval gates remain a
# continuation-message instruction a direct dispatch can bypass ->
# [hook-driven only].
# ---------------------------------------------------------------------------
assert_file_contains \
  "RULES.md has a Parallel Dispatch section" \
  "$RULES_FILE" \
  "## 11. Parallel Dispatch"

assert_file_contains \
  "Parallel batch selection is tagged [enforced]" \
  "$RULES_FILE" \
  'Batch selection.*`\[enforced\]`'

assert_file_contains \
  "Parallel hard stops are tagged [enforced] (stop-hook-invoked, not agent-gated)" \
  "$RULES_FILE" \
  'hard stops are unconditional.*`\[enforced\]`'

assert_file_contains \
  "Parallel dispatch gates are tagged [hook-driven only]" \
  "$RULES_FILE" \
  'approve_plan,approve_batch,approve_final_pr.*`\[hook-driven only\]`'

# ---------------------------------------------------------------------------
# Test (f): the Parallel Dispatch Enforcement section exists with honest
# tiers. Both guards are real PreToolUse hooks that deny (exit 2)
# mechanically -> [enforced].
# ---------------------------------------------------------------------------
assert_file_contains \
  "RULES.md has a Parallel Dispatch Enforcement section" \
  "$RULES_FILE" \
  "## 12. Parallel Dispatch Enforcement"

assert_file_contains \
  "Dispatch guard is tagged [enforced]" \
  "$RULES_FILE" \
  'Dispatch guard.*`\[enforced\]`'

assert_file_contains \
  "Re-work guard is tagged [enforced]" \
  "$RULES_FILE" \
  'Re-work guard.*`\[enforced\]`'

assert_file_contains \
  "Parallel Dispatch Enforcement cross-references the two unconditional hard stops" \
  "$RULES_FILE" \
  "unconditional hard stops"

assert_file_not_contains \
  "RULES.md no longer describes the deleted Conductor engine as live" \
  "$RULES_FILE" \
  "\`agents/conductor.md\`"

# ---------------------------------------------------------------------------
# Test (g): the Automation Heartbeat section (FEAT-008) exists with honest
# tiers. The concurrency guard and the two hard stops are plain, unconditional
# bash checked by the tick script itself (no agent judgment involved) -> [en-
# forced], same class as stop-hook.sh's own internal gates. Atomic claim-then-
# archive is a fixed single-outcome filesystem operation in that same flow ->
# [enforced]. Opt-in/default-off and no-eval are agent/config discipline with
# no mechanical guard against regression -> [advisory].
# ---------------------------------------------------------------------------
assert_file_contains \
  "RULES.md has an Automation Heartbeat section" \
  "$RULES_FILE" \
  "## 13. Automation Heartbeat"

assert_file_contains \
  "Heartbeat opt-in/default-off is tagged [advisory]" \
  "$RULES_FILE" \
  'Opt-in and default-off.*`\[advisory\]`'

assert_file_contains \
  "Heartbeat concurrency guard is tagged [enforced]" \
  "$RULES_FILE" \
  'concurrency guard: never a second loop.*`\[enforced\]`'

assert_file_contains \
  "Heartbeat's two hard stops are tagged [enforced]" \
  "$RULES_FILE" \
  'two hard stops are unconditional.*`\[enforced\]`'

assert_file_contains \
  "Heartbeat atomic claim-then-archive is tagged [enforced]" \
  "$RULES_FILE" \
  'Idempotent atomic claim-then-archive.*`\[enforced\]`'

assert_file_contains \
  "Heartbeat no-eval discipline is tagged [advisory]" \
  "$RULES_FILE" \
  'No `eval` on inbox/objective text.*`\[advisory\]`'

assert_file_contains \
  "Automation Heartbeat references branch isolation (§10) as unchanged" \
  "$RULES_FILE" \
  "Branch isolation (§10) applies unchanged"

# ---------------------------------------------------------------------------
# Test (h): the Raising Findings section (FEAT-009 TASK-009) exists with
# honest tiers. Nothing forces a sub-session to call raise_finding instead of
# working around a finding, and the no-eval/neutralization safety is
# test-backed today but not regression-guarded -> both [advisory], same class
# as §13's no-eval bullet.
# ---------------------------------------------------------------------------
assert_file_contains \
  "RULES.md has a Raising Findings section" \
  "$RULES_FILE" \
  "## 14. Raising Findings"

assert_file_contains \
  "Use-it-instead-of-working-around-it is tagged [advisory]" \
  "$RULES_FILE" \
  'Use it instead of working around out-of-scope findings.*`\[advisory\]`'

assert_file_contains \
  "Raising findings no-eval discipline is tagged [advisory]" \
  "$RULES_FILE" \
  'Data-only, no `eval`.*`\[advisory\]`'

assert_file_contains \
  "Raising findings append-only sink is tagged [advisory]" \
  "$RULES_FILE" \
  'Append-only sink.*`\[advisory\]`'

report_results
