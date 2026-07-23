#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test grep exit codes explicitly

# Test: four-consumer verdict-filename consistency (MF-058), MF-059
# trust-boundary presence, and MF-015's mechanical review_unit emit, per
# FEAT-016 TASK-004.
#
# The MF-058/MF-059 checks are static (grep/test against the agent prompt +
# library files), not runtime — per ADR-004 Decision 2, MF-059 is prompt-only
# guidance with no mechanical enforcement possible; this test asserts the
# language is PRESENT, not that it is obeyed. The MF-058 check is the "simple
# string-consistency test that would have caught the audit's own
# three-scheme drift" the TRD calls for. The MF-015 section below is both a
# static check (the emit instruction calls resolve_review_unit rather than
# self-reporting) and a functional one (resolve_review_unit itself resolves
# per-task from disk, so a task wrongly claimed as part of a group cannot
# inherit the claimed unit id) — closing the TASK-003 security review's
# self-report-trust concern.
TEST_NAME="test-review-contract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

REVIEW_GATE="$REPO_ROOT/agents/review-gate.md"
REVIEWER_BASE="$REPO_ROOT/agents/templates/reviewer-base.md"
TEAM_ORCHESTRATOR="$REPO_ROOT/agents/team-orchestrator.md"
REVIEW_EVIDENCE="$REPO_ROOT/scripts/lib/review-evidence.sh"

for f in "$REVIEW_GATE" "$REVIEWER_BASE" "$TEAM_ORCHESTRATOR" "$REVIEW_EVIDENCE"; do
  if [ ! -f "$f" ]; then
    _fail "required file exists: $f" "file not found"
  fi
done

# --- MF-058: four-consumer <UNIT-ID>/<reviewer-name>.md filename consistency ---
#
# Each file spells the review-unit and reviewer placeholders with its own
# convention ([UNIT-ID], [TASK-ID], {{reviewer_name}}, <TASK-ID>, ${reviewer}),
# per the TRD's own verification that team-orchestrator.md's [TASK-ID] variant
# is an accepted part of the same agreed contract (its dispatch path is
# task-scoped, never group/feature). The invariant every consumer must share
# is the SHAPE: reviews/<placeholder>/<placeholder>.md — a bracketed,
# braced, or angle-bracketed token, never a divergent literal path segment.
PLACEHOLDER='(\[[A-Za-z_-]+\]|\{\{[A-Za-z_]+\}\}|<[A-Za-z_-]+>)'
UNIT_REVIEWER_PATTERN="reviews/${PLACEHOLDER}/${PLACEHOLDER}\.md"

if grep -qE "$UNIT_REVIEWER_PATTERN" "$REVIEW_GATE"; then
  _pass "review-gate.md references the <UNIT-ID>/<reviewer-name>.md pattern"
else
  _fail "review-gate.md references the <UNIT-ID>/<reviewer-name>.md pattern" "no match for: $UNIT_REVIEWER_PATTERN"
fi

if grep -qE "$UNIT_REVIEWER_PATTERN" "$REVIEWER_BASE"; then
  _pass "reviewer-base.md references the <UNIT-ID>/<reviewer-name>.md pattern"
else
  _fail "reviewer-base.md references the <UNIT-ID>/<reviewer-name>.md pattern" "no match for: $UNIT_REVIEWER_PATTERN"
fi

if grep -qE "$UNIT_REVIEWER_PATTERN" "$TEAM_ORCHESTRATOR"; then
  _pass "team-orchestrator.md references the <UNIT-ID>/<reviewer-name>.md pattern"
else
  _fail "team-orchestrator.md references the <UNIT-ID>/<reviewer-name>.md pattern" "no match for: $UNIT_REVIEWER_PATTERN"
fi

# review-evidence.sh documents the same shape in its header comment (the
# canonical-evidence contract statement) even though its live code operates on
# already-resolved bash variables.
if grep -qE "reviews/${PLACEHOLDER}/${PLACEHOLDER}\.md" "$REVIEW_EVIDENCE"; then
  _pass "review-evidence.sh documents the <UNIT-ID>/<reviewer-name>.md pattern"
else
  _fail "review-evidence.sh documents the <UNIT-ID>/<reviewer-name>.md pattern" "no match for: reviews/${PLACEHOLDER}/${PLACEHOLDER}\.md"
fi

# review-evidence.sh's live code must also construct exactly one file per
# reviewer as "<review_dir>/<reviewer>.md" — the actual runtime shape the
# other three files' prose describes.
if grep -qE '\$\{?review_dir\}?/\$\{reviewer\}\.md' "$REVIEW_EVIDENCE"; then
  _pass "review-evidence.sh's runtime code constructs \${review_dir}/\${reviewer}.md"
else
  _fail "review-evidence.sh's runtime code constructs \${review_dir}/\${reviewer}.md" "pattern not found"
fi

# --- MF-059: trust-boundary presence (prompt-only guidance, no mechanical
#     enforcement possible per ADR-004 Decision 2 — this asserts PRESENCE) ---

if grep -q "MF-059" "$REVIEWER_BASE" && grep -qi "untrusted" "$REVIEWER_BASE" && grep -qi "authoritative" "$REVIEWER_BASE"; then
  _pass "reviewer-base.md states the initial-dispatch-only trust boundary"
else
  _fail "reviewer-base.md states the initial-dispatch-only trust boundary" "missing MF-059 / untrusted / authoritative language"
fi

if grep -q "MF-059" "$REVIEW_GATE" && grep -qi "authoritative" "$REVIEW_GATE"; then
  _pass "review-gate.md states the dispatch trust boundary"
else
  _fail "review-gate.md states the dispatch trust boundary" "missing MF-059 / authoritative language"
fi

if grep -q "MF-059" "$TEAM_ORCHESTRATOR" && grep -qi "legitimate" "$TEAM_ORCHESTRATOR"; then
  _pass "team-orchestrator.md states the SendMessage trust boundary"
else
  _fail "team-orchestrator.md states the SendMessage trust boundary" "missing MF-059 / legitimate-sender language"
fi

# The trust-boundary language must sit adjacent to team-orchestrator.md's
# existing SendMessage coordination guidance, not floating disconnected from
# it (per the TRD's placement instruction).
if awk '/## Inter-Agent Communication/,0' "$TEAM_ORCHESTRATOR" | grep -q "MF-059"; then
  _pass "team-orchestrator.md's trust boundary sits within Inter-Agent Communication"
else
  _fail "team-orchestrator.md's trust boundary sits within Inter-Agent Communication" "MF-059 marker not found after the section heading"
fi

# --- MF-015: review_unit must be computed MECHANICALLY, not self-reported
#     (TASK-003 security-review follow-up) ---
#
# The reviewer_verdict emit step must call resolve_review_unit() rather than
# echoing back the DELEGATE instruction's prose [UNIT-ID] as-is — otherwise a
# misclassifying or prompt-injected review-gate run could emit whatever
# review_unit it wants, and the MF-015 coverage-gate consumer (subagent-stop.sh
# / the DONE-gate) would be trusting a self-report from the same agent it
# polices. Static check first: the emit block must source review-evidence.sh
# and call resolve_review_unit, and must NOT emit review_unit as a bare
# restatement of $UNIT_ID.
if grep -q "source \"\${CLAUDE_PLUGIN_ROOT}/scripts/lib/review-evidence.sh\"" "$REVIEW_GATE" \
  && grep -q 'resolve_review_unit "\$NAZGUL_DIR"' "$REVIEW_GATE"; then
  _pass "review-gate.md's emit step calls resolve_review_unit (mechanical, not self-reported)"
else
  _fail "review-gate.md's emit step calls resolve_review_unit (mechanical, not self-reported)" "resolve_review_unit call not found in review-gate.md"
fi

if grep -q 'review_unit "\$REVIEW_UNIT"' "$REVIEW_GATE"; then
  _pass "review-gate.md's emit command uses the recomputed \$REVIEW_UNIT, not \$UNIT_ID directly"
else
  _fail "review-gate.md's emit command uses the recomputed \$REVIEW_UNIT, not \$UNIT_ID directly" "emit line does not reference \$REVIEW_UNIT"
fi

if grep -q 'if `REVIEW_UNIT` differs from `\$UNIT_ID`' "$REVIEW_GATE" \
  && grep -q 'do NOT emit for that task' "$REVIEW_GATE"; then
  _pass "review-gate.md's emit step has the cross-group mismatch rule (skip+log when REVIEW_UNIT != UNIT_ID)"
else
  _fail "review-gate.md's emit step has the cross-group mismatch rule (skip+log when REVIEW_UNIT != UNIT_ID)" "mismatch-rule prose not found in review-gate.md emit block"
fi

if grep -qE 'review_unit "\$UNIT_ID"' "$REVIEW_GATE"; then
  _fail "review-gate.md's emit command does NOT self-report \$UNIT_ID as review_unit" "found the vulnerable self-report pattern"
else
  _pass "review-gate.md's emit command does NOT self-report \$UNIT_ID as review_unit"
fi

# Functional check: resolve_review_unit() itself resolves PER TASK from disk,
# so two tasks an orchestrator claims are both "GROUP-1" cannot both silently
# inherit that claim if their own manifests disagree — a wrongly-claimed task
# resolves to ITS OWN group, exposing the mismatch rather than masking it.
source "$REPO_ROOT/scripts/lib/review-evidence.sh"

setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_task_file "TASK-101" "IMPLEMENTED"
set_task_group "TASK-101" "1"
create_task_file "TASK-102" "IMPLEMENTED"
set_task_group "TASK-102" "2"   # deliberately a DIFFERENT group than TASK-101

UNIT_101=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-101")
UNIT_102=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-102")

assert_eq "mechanical resolve: correctly-grouped task resolves to its own group" "$UNIT_101" "GROUP-1"
assert_eq "mechanical resolve: a task NOT actually in GROUP-1 resolves to its OWN group, not the claimed one" "$UNIT_102" "GROUP-2"
assert_not_contains "mechanical resolve: mismatched task does not silently inherit the claimed unit" "$UNIT_102" "GROUP-1"

teardown_temp_dir

report_results
