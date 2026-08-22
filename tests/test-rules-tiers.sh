#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-rules-tiers"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

RULES_FILE="$REPO_ROOT/RULES.md"

assert_file_not_contains \
  "RULES.md does not claim 'Every rule here is checked by a hook, agent, or script'" \
  "$RULES_FILE" \
  "Every rule here is checked by a hook, agent, or script"

# A "numbered rule line" is `^[0-9]+\. \*\*`; the Recovery Read Order items are
# plain text, so the bold lead-in excludes them.
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

# Bullet-format rules (§10 Branch Isolation and friends), excluding fenced
# blocks and the HITL/AFK/YOLO mode descriptors, which are not rules.
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

# The three counts are structural-freshness checks, NOT ceilings: bump one for a
# genuinely new rule; never weaken a tag to keep a count unchanged (FEAT-022).
ADVISORY_COUNT=$(awk '{ count += gsub(/\[advisory\]/, "") } END { print count + 0 }' "$RULES_FILE")  # occurrences, not lines
if [ "$ADVISORY_COUNT" -eq 36 ]; then
  _pass "[advisory] annotation count is exactly 36 (found: $ADVISORY_COUNT)"
else
  _fail "[advisory] annotation count is exactly 36" \
    "found $ADVISORY_COUNT occurrences of [advisory] — expected exactly 36"
fi

# Bumped per objective, never weakened: 64->69 (FEAT-029), 69->71 (PATCH-002), 71->78
# +advisory 28->31, 78->79 (FEAT-030 §21 + item 8), 79->82 +advisory 31->35 (FEAT-032 §22),
# advisory 35->36 (FEAT-031 RW-G: the plan-binding producer is a script, but what RUNS it is a
# prompt, so §2 states that half as advisory rather than implying the whole is enforced),
# 82->91 (FEAT-031: §2 cancellation x2, the CANCELLED dependency gate, §2 merge evidence x3,
# §16 seam x3). FEAT-031 and FEAT-032 landed concurrently; 91 is the counted total of both,
# not the sum either branch asserted alone. 91->92 (FEAT-031/TASK-019: §15's converse direction —
# every shipped grammar emitter is a registered entry point).
ENFORCED_COUNT=$(awk '{ count += gsub(/\[enforced\]/, "") } END { print count + 0 }' "$RULES_FILE")
if [ "$ENFORCED_COUNT" -eq 92 ]; then
  _pass "[enforced] annotation count is exactly 92 (found: $ENFORCED_COUNT)"
else
  _fail "[enforced] annotation count is exactly 92" \
    "found $ENFORCED_COUNT occurrences of [enforced] — expected exactly 92"
fi

# 21->22 (FEAT-029, §2's typed quarantine), 22->23 (FEAT-031, §3.15's carve-out record):
# both hook-driven because stop-hook.sh produces them and a direct dispatch does not.
HOOK_DRIVEN_COUNT=$(awk '{ count += gsub(/\[hook-driven only\]/, "") } END { print count + 0 }' "$RULES_FILE")
if [ "$HOOK_DRIVEN_COUNT" -eq 23 ]; then
  _pass "[hook-driven only] annotation count is exactly 23 (found: $HOOK_DRIVEN_COUNT)"
else
  _fail "[hook-driven only] annotation count is exactly 23" \
    "found $HOOK_DRIVEN_COUNT occurrences of [hook-driven only] — expected exactly 23"
fi

# §11: batch selection and the two hard stops are unconditional stop-hook bash,
# while the approval gates are an instruction a direct dispatch can bypass.
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

# §12: both guards are real PreToolUse hooks that deny with exit 2.
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

# §13: the concurrency guard, the two hard stops, and atomic claim-then-archive
# are unconditional bash in the tick script; opt-in and no-eval are discipline.
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

# §14: nothing forces a sub-session to call raise_finding, and the no-eval
# safety is test-backed but not regression-guarded -> all [advisory].
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

# §15 resolver: library adoption is review-only; the fail-open branch is a
# deterministic path inside a real PreToolUse guard.
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

# FEAT-029 doctrine: the claims TASK-003/005/006/011 carried forward must be
# present by content, not merely counted by the tier tallies above.
assert_file_contains \
  "§2 states that preflight is not transition authority (ADR-020)" \
  "$RULES_FILE" \
  "Preflight is not authority"

assert_file_contains \
  "§2 names scripts/task-transition.sh as the sole sanctioned status writer" \
  "$RULES_FILE" \
  "SOLE sanctioned writer of a task's status"

assert_file_contains \
  "§2 documents the typed reconciliation quarantine fields" \
  "$RULES_FILE" \
  'Blocked kind: reconciliation'

assert_file_contains \
  "§2 documents repair as the only exit from a quarantine" \
  "$RULES_FILE" \
  'only exit from a reconciliation quarantine'

assert_file_contains \
  "§2's dependency gate is qualified by review granularity" \
  "$RULES_FILE" \
  'dependency condition is granularity-aware'

assert_file_contains \
  "§7 states the generated-artifact evidence contract" \
  "$RULES_FILE" \
  "generated-artifact claim needs verified output"

assert_file_contains \
  "§15 carries the bound coverage-honesty entry-point registry" \
  "$RULES_FILE" \
  "registry of bound entry points lives HERE"

assert_file_contains \
  "§15's registry enrolls scripts/self-audit.sh" \
  "$RULES_FILE" \
  '`scripts/self-audit.sh` (enrolled FEAT-029/TASK-012'

# FEAT-030 §21: the runtime-state addressing rule must state its own enforcement
# honestly, and must not drift from the sentinel and event type that actually shipped.
assert_file_contains \
  "RULES.md has a Runtime-State Path Addressing section" \
  "$RULES_FILE" \
  "## 21. Runtime-State Path Addressing & Write Read-Back"

assert_file_contains \
  "§21's addressing rule is tagged [enforced]" \
  "$RULES_FILE" \
  'Runtime-state paths are addressed.*`\[enforced\]`'

assert_file_contains \
  "§21's CLAUDE_PROJECT_DIR bridge is tagged [advisory]" \
  "$RULES_FILE" \
  'The resolver stays.*`\[advisory\]`'

assert_file_contains \
  "§21 states why the resolver is not interchangeable with <main_worktree_path>" \
  "$RULES_FILE" \
  "returns the TASK WORKTREE"

assert_file_contains \
  "§21 splits the read-back rule into an enforced contract and advisory runtime compliance" \
  "$RULES_FILE" \
  '`\[enforced\]` for the spec contract, `\[advisory\]` for'

assert_file_contains \
  "§21 records the Write-tool decision in the learner's direction too" \
  "$RULES_FILE" \
  'RETAINS the `Write` grant'

# The gate-attribution clause is pinned against the SHIPPED code, not against ADR-021's
# suggestion: a sentinel or event type the stop-hook does not emit is a fabricated rule.
STOP_HOOK="$REPO_ROOT/scripts/stop-hook.sh"
for token in ':NO-SOURCE-CHANGED' ':EXHAUSTED' 'gate_attribution'; do
  assert_file_contains "§21 names '$token', which scripts/stop-hook.sh emits" "$RULES_FILE" "$token"
  assert_file_contains "scripts/stop-hook.sh still ships '$token'" "$STOP_HOOK" "$token"
done

# §15 owns the coverage-honesty registry; §21 cross-references it rather than restating it.
REGISTRY_HITS=$(grep -c "registry of bound entry points lives HERE" "$RULES_FILE" || true)
if [ "$REGISTRY_HITS" -eq 1 ]; then
  _pass "the coverage-honesty registry is declared exactly once (§15)"
else
  _fail "the coverage-honesty registry is declared exactly once (§15)" \
    "found $REGISTRY_HITS declarations — a second copy is a registry that can drift"
fi

assert_file_not_contains \
  "RULES.md no longer claims EnterWorktree is a live worktree-entry path" \
  "$RULES_FILE" \
  "the real worktree-entry paths are the"

# FEAT-032 §22: the posture must state its own enforcement and must not overclaim
# — receipt IS hook-observable (probe P6), so "buildable" is the honest word.
assert_file_contains \
  "RULES.md has a Cross-Session Messaging Posture section" \
  "$RULES_FILE" \
  "## 22. Cross-Session Messaging Posture"

assert_file_contains \
  "§22's doctrine rule is tagged [advisory]" \
  "$RULES_FILE" \
  'may never authorize one.*`\[advisory\]`'

assert_file_contains \
  "§22's no-poster rule is tagged [enforced]" \
  "$RULES_FILE" \
  'posts to the messaging socket, ever.*`\[enforced\]`'

assert_file_contains \
  "§22 states inbound gating is unbuilt, not impossible" \
  "$RULES_FILE" \
  "buildable is not built"

report_results
