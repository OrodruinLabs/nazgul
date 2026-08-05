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

# --- MF-058: <UNIT-ID>/<reviewer-name>.md filename consistency across the
# live report-contract consumers ---
#
# Each file spells the review-unit and reviewer placeholders with its own
# convention ([UNIT-ID], {{reviewer_name}}, ${reviewer}). The invariant every
# consumer must share is the SHAPE: reviews/<placeholder>/<placeholder>.md —
# a bracketed, braced, or angle-bracketed token, never a divergent literal
# path segment. team-orchestrator.md is no longer one of these consumers:
# FEAT-026/ADR-017 retired its named-teammate report-dispatch path (the sole
# place it restated this pattern), so it is intentionally excluded from this
# check rather than checked against a pattern it no longer has any reason to
# contain.
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

# --- FEAT-028 AC9: the qa-reviewer charter must survive the render ---
#
# The tracked deliverable is reviewer-domains.json, but what a reviewer
# actually obeys is the RENDERED prompt. This renders the real base template
# with the real renderer (the bootstrap-project pipeline) and asserts the
# charter's four ALWAYS-BLOCKING questions arrive intact. Expected strings are
# spelled out here rather than read back from the JSON under test — a render
# check that derives its expectations from its own subject cannot fail.
source "$REPO_ROOT/scripts/lib/bootstrap-render.sh"
DOMAINS_JSON="$REPO_ROOT/agents/templates/reviewer-domains.json"
[ -f "$DOMAINS_JSON" ] || _fail "required file exists: $DOMAINS_JSON" "file not found"

QA_RENDER=$(render_template "$REVIEWER_BASE" | substitute_domain_vars "qa-reviewer" "$DOMAINS_JSON")
assert_eq "qa-reviewer renders through the real bootstrap pipeline" "$?" "0"

QA_SEAMS='Which seams does this diff touch — as producer or consumer? Does each contract test invoke the producer or build state through a supported scratch entry path? (ALWAYS-BLOCKING)'
QA_REDRUN='Where is the red-run evidence for every new/changed test — and does it carry `captured-by: scripts/red-run.sh`? (ALWAYS-BLOCKING)'
QA_FIXTURE='Does any test commit copied project-runtime state instead of generating minimal scratch state during the run? (ALWAYS-BLOCKING)'
QA_DOGFOOD='If a guard changed: does its suite exercise THIS repo'"'"'s own language and shape? (ALWAYS-BLOCKING)'

assert_contains "rendered qa-reviewer asks which seams the diff touches (blocking)" "$QA_RENDER" "$QA_SEAMS"
assert_contains "rendered qa-reviewer asks where the red-run evidence is (blocking)" "$QA_RENDER" "$QA_REDRUN"
assert_contains "rendered qa-reviewer rejects committed runtime snapshots (blocking)" "$QA_RENDER" "$QA_FIXTURE"
assert_contains "rendered qa-reviewer asks whether a changed guard is dogfooded (blocking)" "$QA_RENDER" "$QA_DOGFOOD"
assert_contains "rendered qa-reviewer asks for the coverage-honesty signal" "$QA_RENDER" 'the `N scanned, M skipped` line and the nothing-checked signal'
assert_contains "rendered qa-reviewer asks whether each assertion could actually fail" "$QA_RENDER" "Could each new assertion actually fail"

QA_CHECKLIST=$(grep '^- \[ \] ' <<<"$QA_RENDER")
assert_eq "exactly four ALWAYS-BLOCKING checklist items" "$(grep -c 'ALWAYS-BLOCKING' <<<"$QA_CHECKLIST")" "4"
assert_eq "the ALWAYS-BLOCKING items are the FIRST four" "$(head -4 <<<"$QA_CHECKLIST" | grep -c 'ALWAYS-BLOCKING')" "4"

assert_contains "rendered APPROVE criterion is the charter's" "$QA_RENDER" \
  'Every touched seam is exercised through a real producer or supported scratch entry path, red-run evidence is present and mechanically captured, and remaining concerns are minor'
assert_contains "rendered CHANGES_REQUESTED criterion is the charter's" "$QA_RENDER" \
  'A touched seam is unpinned, red-run evidence is missing, project-runtime state is committed as fixture data, a changed guard is not dogfooded, or an assertion cannot fail (confidence >= 80)'
assert_contains "rendered review steps read the manifest's Red-Run Evidence section" "$QA_RENDER" '`## Red-Run Evidence` section'
assert_contains "rendered review steps reject committed runtime snapshots" "$QA_RENDER" 'Nazgul manifests, reviews, checkpoints, locks, and inbox records must be generated in a temporary project'
assert_contains "rendered review steps forbid re-running the suite" "$QA_RENDER" 'Do NOT re-run the suite'
assert_contains "rendered qa-reviewer keeps its read-only tools list" "$QA_RENDER" '  - Read'
assert_not_contains "rendered qa-reviewer still has no Bash tool" "$QA_RENDER" '  - Bash'
assert_contains "rendered qa-reviewer carries the ALWAYS-BLOCKING mechanism that gives the questions teeth" "$QA_RENDER" \
  'Never downgrade an always-blocking finding'

# The bundle path (skills/bootstrap-project) renders with BUNDLE_MODE=true; the
# charter has to survive that branch too, not just the loop's.
QA_BUNDLE=$(BUNDLE_MODE=true render_template "$REVIEWER_BASE" | substitute_domain_vars "qa-reviewer" "$DOMAINS_JSON")
assert_contains "bundle-mode render keeps the seams question" "$QA_BUNDLE" "$QA_SEAMS"
assert_contains "bundle-mode render keeps the red-run question" "$QA_BUNDLE" "$QA_REDRUN"

# Control: the same pipeline over the pre-charter qa-reviewer shape. Without it
# these assertions could be passing on base-template text rather than on the
# domain config this task rewrote.
CONTROL_JSON=$(mktemp "${TMPDIR:-/tmp}/qa-control.XXXXXX")
cat > "$CONTROL_JSON" <<'CONTROL'
{
  "qa-reviewer": {
    "description": "Reviews test coverage, edge cases, test quality, and assertion completeness for this project",
    "title": "QA",
    "context_items": "test framework, test locations, coverage tool, test commands, fixture patterns",
    "checklist": [
      "New code has corresponding tests",
      "Tests cover happy path AND error/edge cases"
    ],
    "review_steps": ["Find corresponding test files"],
    "category": "Testing",
    "approved_criteria": "Tests are adequate, concerns are minor",
    "rejected_criteria": "Missing tests or critical test quality issues (confidence >= 80)"
  }
}
CONTROL
CONTROL_RENDER=$(render_template "$REVIEWER_BASE" | substitute_domain_vars "qa-reviewer" "$CONTROL_JSON")
CONTROL_CHECKLIST=$(grep '^- \[ \] ' <<<"$CONTROL_RENDER")
rm -f "$CONTROL_JSON"

assert_not_contains "control render: pre-charter config produces no seams question" "$CONTROL_RENDER" "$QA_SEAMS"
assert_not_contains "control render: pre-charter config produces no red-run question" "$CONTROL_RENDER" "$QA_REDRUN"
assert_not_contains "control render: pre-charter config has no ALWAYS-BLOCKING checklist item" "$CONTROL_CHECKLIST" "ALWAYS-BLOCKING"
assert_not_contains "control render: pre-charter config keeps the old APPROVE criterion, not the charter's" "$CONTROL_RENDER" \
  'Every touched seam is pinned by a contract test'

DISCOVERY=$(cat "$REPO_ROOT/agents/discovery.md")
assert_contains "discovery names the live reviewer base as its source of truth" \
  "$DISCOVERY" '`agents/templates/reviewer-base.md` + `agents/templates/reviewer-domains.json` are the SINGLE source of'
assert_contains "discovery binds its reviewer contract to this test" \
  "$DISCOVERY" 'reviewer-contract:begin — checked against agents/templates/reviewer-base.md by tests/test-review-contract.sh'
assert_not_contains "discovery no longer embeds the obsolete Bash-capable reviewer copy" \
  "$DISCOVERY" 'allowed-tools: Read, Glob, Grep, Bash(npm test *)'

report_results
