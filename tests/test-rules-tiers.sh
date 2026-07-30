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
# Test (c): [advisory] count is exactly 20 — was 17 as of FEAT-016 (see prior
# history: Parallel Execution Collapse deleted 4 Conductor-era bullets, +2 from
# §17 Teammate Report Contract). FEAT-017/TASK-011 added 2 more: §11's
# review-then-merge dispatch-order note and §17's MF-047 spawn-vs-manifest
# companion note (17 + 2 = 19). FEAT-018 added 1 more: §18's "Dismissal is
# part of consuming a report" rule. 19 + 1 = 20.
# NOTE: counts OCCURRENCES, not lines (some lines carry two tags) — see the
# [enforced] counter below; for [advisory] the line count and occurrence
# count both happen to be 21 (no line currently carries two [advisory] tags).
# FEAT-021/TASK-010 added 1 more: the "Shared nazgul/ Root Resolver" subsection's
# resolver-adoption-is-review-only bullet (20 + 1 = 21).
ADVISORY_COUNT=$(awk '{ count += gsub(/\[advisory\]/, "") } END { print count + 0 }' "$RULES_FILE")
if [ "$ADVISORY_COUNT" -eq 21 ]; then
  _pass "[advisory] annotation count is exactly 21 (found: $ADVISORY_COUNT)"
else
  _fail "[advisory] annotation count is exactly 21" \
    "found $ADVISORY_COUNT occurrences of [advisory] — expected exactly 21"
fi

# ---------------------------------------------------------------------------
# Test (c2): [enforced]/[hook-driven only] counts. The final whole-branch
# review's enforcement-tier honesty pass reclassified §18 rule 2 (the
# stop-hook's undismissed-teammate directive) from [enforced] to
# [hook-driven only]: the gate only injects a continuation-message directive
# into the loop prompt — a direct dispatcher can route around it — it never
# mechanically blocks a tool call the way a PreToolUse guard does. That is a
# net enforced -1 / hook-driven only +1 relative to the prior count.
#
# These two constants are a structural-freshness check on RULES.md's tier
# taxonomy, not a ceiling: bump them deliberately whenever a genuinely new
# tier-tagged rule is added. Never weaken or remove an existing tag just to
# keep a count unchanged — that defeats the point of the check (FEAT-022/
# TASK-008 review board finding: Attempt 1 folded two new rules into
# unrelated existing bullets specifically to avoid bumping these numbers).
# ---------------------------------------------------------------------------
# NOTE: counts OCCURRENCES, not lines — `grep -c` undercounts because two
# lines in RULES.md (the parallel-batch-selection bullet and the §11
# hard-stops footnote) each carry two `[enforced]` tags. Line count was 49;
# occurrence count was 51 (49 + 2 for the double-tagged lines). FEAT-021/
# TASK-010 added 1 more: the resolver subsection's `_resolution_integrity_ok()`
# fail-open sentence (51 + 1 = 52). FEAT-022/TASK-008 added 1 more: §8's new
# "Project detection (config-present, tasks-absent)" bullet, split out of the
# Implementer bullet it was originally folded into (52 + 1 = 53).
ENFORCED_COUNT=$(awk '{ count += gsub(/\[enforced\]/, "") } END { print count + 0 }' "$RULES_FILE")
if [ "$ENFORCED_COUNT" -eq 53 ]; then
  _pass "[enforced] annotation count is exactly 53 (found: $ENFORCED_COUNT)"
else
  _fail "[enforced] annotation count is exactly 53" \
    "found $ENFORCED_COUNT occurrences of [enforced] — expected exactly 53"
fi

# NOTE: counts OCCURRENCES, not lines — no line currently carries two
# [hook-driven only] tags, so this matches the line count. FEAT-022/TASK-008
# added 1 more: §15's new "Bash-only sourcing and observed-state branch
# creation" bullet, split out of the install/uninstall lifecycle bullet it
# was originally folded into (20 + 1 = 21). FEAT-023/TASK-009 added 1 more:
# §5's new "A gate-triggered stop announces itself" `stop_gate` bullet —
# tagged [hook-driven only], not [enforced], because it is stop-hook.sh
# behavior on the AFK gate path only (ADR-014), not a PreToolUse block
# (21 + 1 = 22).
HOOK_DRIVEN_COUNT=$(awk '{ count += gsub(/\[hook-driven only\]/, "") } END { print count + 0 }' "$RULES_FILE")
if [ "$HOOK_DRIVEN_COUNT" -eq 22 ]; then
  _pass "[hook-driven only] annotation count is exactly 22 (found: $HOOK_DRIVEN_COUNT)"
else
  _fail "[hook-driven only] annotation count is exactly 22" \
    "found $HOOK_DRIVEN_COUNT occurrences of [hook-driven only] — expected exactly 22"
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

# ---------------------------------------------------------------------------
# Test (i): the Shared nazgul/ Root Resolver subsection (FEAT-021/ADR-008,
# TASK-010) exists with honest tiers. Library adoption is review-only, no
# guard blocks a hand-rolled resolution idiom -> [advisory]. The dispatch
# guard's fail-open branch is a deterministic code path inside a real
# PreToolUse guard, same class as MF-053's fail-closed branch -> [enforced].
# ---------------------------------------------------------------------------
assert_file_contains \
  "RULES.md has a Shared nazgul/ Root Resolver subsection" \
  "$RULES_FILE" \
  "### Shared \`nazgul/\` Root Resolver"

assert_file_contains \
  "Resolver precedence starts with CLAUDE_PROJECT_DIR winning unconditionally" \
  "$RULES_FILE" \
  'Precedence: `\$CLAUDE_PROJECT_DIR`, if set and non-empty,'

assert_file_contains \
  "Resolver precedence falls through to git-toplevel then pwd" \
  "$RULES_FILE" \
  'git-toplevel then `\$(pwd)` whose `nazgul/config.json` exists'

assert_file_contains \
  "Resolver-library adoption is tagged [advisory]" \
  "$RULES_FILE" \
  '`\[advisory\]` `scripts/lib/nazgul-root.sh`'

assert_file_contains \
  "scripts/git-hooks/ resolver exemption is documented" \
  "$RULES_FILE" \
  '`scripts/git-hooks/` is exempt'

assert_file_contains \
  "_resolution_integrity_ok() fail-open is tagged [enforced]" \
  "$RULES_FILE" \
  'top of this resolver\.\*\* `\[enforced\]`'

assert_file_contains \
  "_resolution_integrity_ok() fail-open does not relax MF-053" \
  "$RULES_FILE" \
  "relax, MF-053's fail-CLOSED-on-corrupt-config rule"

report_results
