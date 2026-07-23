#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test grep exit codes explicitly

# Test: four-consumer verdict-filename consistency (MF-058) and MF-059
# trust-boundary presence, per FEAT-016 TASK-004.
#
# Both checks are static (grep/test against the agent prompt + library files),
# not runtime — per ADR-004 Decision 2, MF-059 is prompt-only guidance with no
# mechanical enforcement possible; this test asserts the language is PRESENT,
# not that it is obeyed. The MF-058 check is the "simple string-consistency
# test that would have caught the audit's own three-scheme drift" the TRD
# calls for.
TEST_NAME="test-review-contract"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

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

report_results
