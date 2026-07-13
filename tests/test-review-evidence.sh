#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes explicitly

# Test: review-evidence.sh shared validation library
TEST_NAME="test-review-evidence"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/review-evidence.sh"

# Helper: build a nazgul dir with config listing given reviewers, plus any
# extra jq override expressions applied to the same config.
# Usage: setup_evidence_env "code-reviewer qa-reviewer" ['.review_gate.x = true']
setup_evidence_env() {
  setup_temp_dir
  setup_nazgul_dir
  local reviewers_raw="$1"; shift
  local reviewers_json
  # shellcheck disable=SC2086 # intentional word-splitting on space-separated reviewer list
  reviewers_json=$(printf '%s\n' $reviewers_raw | jq -R . | jq -s .)
  create_config ".agents.reviewers = $reviewers_json" "$@"
}

# Helper: write a review file with the given verdict
# Usage: write_review TASK-001 code-reviewer APPROVED
write_review() {
  mkdir -p "$TEST_DIR/nazgul/reviews/$1"
  printf '# Review: %s\n\n## Verdict: %s\n' "$1" "$3" > "$TEST_DIR/nazgul/reviews/$1/$2.md"
}

# Helper: write a review file with a canonical YAML frontmatter verdict block.
# write_review writes a legacy `## Verdict:` body; UNVERIFIED is only read from
# the structured frontmatter block, so these cases need this form.
# Usage: write_frontmatter_verdict TASK-001 code-reviewer UNVERIFIED
write_frontmatter_verdict() {
  mkdir -p "$TEST_DIR/nazgul/reviews/$1"
  printf -- '---\nverdict: %s\n---\nbody\n' "$3" > "$TEST_DIR/nazgul/reviews/$1/$2.md"
}

# Helper: run validation capturing output and exit code
# Sets: VAL_OUTPUT, VAL_EC
run_validate() {
  VAL_OUTPUT=$(validate_review_evidence "$TEST_DIR/nazgul" "$1") && VAL_EC=0 || VAL_EC=$?
}

# --- Test 1: All configured reviewers approved — passes, no output ---
setup_evidence_env "code-reviewer qa-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
write_review "TASK-001" "qa-reviewer" "APPROVED"
run_validate "TASK-001"
assert_exit_code "all approved: exit 0" "$VAL_EC" 0
assert_eq "all approved: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 2: No review directory ---
setup_evidence_env "code-reviewer"
run_validate "TASK-001"
assert_exit_code "no review dir: exit 1" "$VAL_EC" 1
assert_contains "no review dir: NO_REVIEW_DIR" "$VAL_OUTPUT" "NO_REVIEW_DIR"
teardown_temp_dir

# --- Test 3: No reviewers configured ---
setup_evidence_env "code-reviewer"
create_config '.agents.reviewers = []'
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
run_validate "TASK-001"
assert_exit_code "no reviewers configured: exit 1" "$VAL_EC" 1
assert_contains "no reviewers configured marker" "$VAL_OUTPUT" "NO_REVIEWERS_CONFIGURED"
teardown_temp_dir

# --- Test 4: Missing reviewer file ---
setup_evidence_env "code-reviewer qa-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
run_validate "TASK-001"
assert_exit_code "missing reviewer: exit 1" "$VAL_EC" 1
assert_contains "missing reviewer line" "$VAL_OUTPUT" "MISSING qa-reviewer"
assert_not_contains "approved reviewer not flagged" "$VAL_OUTPUT" "code-reviewer"
teardown_temp_dir

# --- Test 5: Reviewer file without APPROVED ---
setup_evidence_env "code-reviewer"
write_review "TASK-001" "code-reviewer" "REJECTED"
run_validate "TASK-001"
assert_exit_code "unapproved reviewer: exit 1" "$VAL_EC" 1
assert_contains "unapproved line" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
teardown_temp_dir

# --- Test 6 (REGRESSION — the bug): summary.md-only directory fails with all reviewers MISSING ---
setup_evidence_env "code-reviewer qa-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf '# Review Summary\n\nVerdict: APPROVED (all reviewers)\n' > "$TEST_DIR/nazgul/reviews/TASK-001/summary.md"
run_validate "TASK-001"
assert_exit_code "summary-only: exit 1" "$VAL_EC" 1
assert_contains "summary-only: code-reviewer missing" "$VAL_OUTPUT" "MISSING code-reviewer"
assert_contains "summary-only: qa-reviewer missing" "$VAL_OUTPUT" "MISSING qa-reviewer"
teardown_temp_dir

# --- Test 7: Meta-files are excluded from verdict checks ---
setup_evidence_env "code-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
printf 'tests failed\n' > "$TEST_DIR/nazgul/reviews/TASK-001/test-failures.md"
printf 'feedback\n' > "$TEST_DIR/nazgul/reviews/TASK-001/consolidated-feedback.md"
printf 'simplified\n' > "$TEST_DIR/nazgul/reviews/TASK-001/simplify-report.md"
printf 'summary\n' > "$TEST_DIR/nazgul/reviews/TASK-001/summary.md"
run_validate "TASK-001"
assert_exit_code "meta-files excluded: exit 0" "$VAL_EC" 0
teardown_temp_dir

# --- Test 8: Extra (non-roster) reviewer file without APPROVED fails ---
setup_evidence_env "code-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
write_review "TASK-001" "extra-reviewer" "REJECTED"
run_validate "TASK-001"
assert_exit_code "extra unapproved reviewer: exit 1" "$VAL_EC" 1
assert_contains "extra unapproved line" "$VAL_OUTPUT" "UNAPPROVED extra-reviewer"
teardown_temp_dir

# --- Test 9: Multiple problems all reported ---
setup_evidence_env "code-reviewer qa-reviewer security-reviewer"
write_review "TASK-001" "code-reviewer" "REJECTED"
run_validate "TASK-001"
assert_exit_code "multiple problems: exit 1" "$VAL_EC" 1
assert_contains "multi: unapproved code-reviewer" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
assert_contains "multi: missing qa-reviewer" "$VAL_OUTPUT" "MISSING qa-reviewer"
assert_contains "multi: missing security-reviewer" "$VAL_OUTPUT" "MISSING security-reviewer"
teardown_temp_dir

# --- Test 10: Prose mention of "approved" does NOT count as a verdict ---
setup_evidence_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" << 'REVIEW_EOF'
# Review: TASK-001

This pattern is approved elsewhere in the codebase, but here it breaks.

## Final Verdict
CHANGES_REQUESTED
REVIEW_EOF
run_validate "TASK-001"
assert_exit_code "prose mention: exit 1" "$VAL_EC" 1
assert_contains "prose mention flagged unapproved" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
teardown_temp_dir

# --- Test 11: APPROVED at line start (Final Verdict section body) counts ---
setup_evidence_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" << 'REVIEW_EOF'
# Review: TASK-001

## Final Verdict

APPROVED — no blocking issues found.
REVIEW_EOF
run_validate "TASK-001"
assert_exit_code "line-start verdict: exit 0" "$VAL_EC" 0
teardown_temp_dir

# --- Test 12: Bold verdict line counts; UNAPPROVED in text does not false-positive ---
setup_evidence_env "code-reviewer qa-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" << 'REVIEW_EOF'
# Review: TASK-001

**Final Verdict: APPROVED**
REVIEW_EOF
cat > "$TEST_DIR/nazgul/reviews/TASK-001/qa-reviewer.md" << 'REVIEW_EOF'
# Review: TASK-001

## Final Verdict
UNAPPROVED pending fixes.
REVIEW_EOF
run_validate "TASK-001"
assert_exit_code "mixed verdicts: exit 1" "$VAL_EC" 1
assert_not_contains "bold verdict accepted" "$VAL_OUTPUT" "code-reviewer"
assert_contains "UNAPPROVED text not a false positive" "$VAL_OUTPUT" "UNAPPROVED qa-reviewer"
teardown_temp_dir

# --- Test 13 (REGRESSION — verb-form livelock): imperative "APPROVE" counts ---
# Reviewer agents naturally write "## Verdict: APPROVE"; the matcher must accept it.
setup_evidence_env "code-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVE"
run_validate "TASK-001"
assert_exit_code "imperative APPROVE: exit 0" "$VAL_EC" 0
assert_eq "imperative APPROVE: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 14: 3rd-person "APPROVES" counts ---
setup_evidence_env "code-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVES"
run_validate "TASK-001"
assert_exit_code "APPROVES: exit 0" "$VAL_EC" 0
teardown_temp_dir

# --- Test 15: APPROVE with trailing punctuation on the verdict line counts ---
# The trailing "." exercises the [^[:alpha:]] boundary branch (not the $ end-of-line
# branch that Test 13's punctuation-free "## Verdict: APPROVE" already covers).
setup_evidence_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" << 'REVIEW_EOF'
# Review: TASK-001

## Verdict: APPROVE.

Typecheck + 147 tests green. APPROVE.
REVIEW_EOF
run_validate "TASK-001"
assert_exit_code "APPROVE with punctuation: exit 0" "$VAL_EC" 0
teardown_temp_dir

# --- Test 16: "UNAPPROVED" on a verdict line does NOT match (substring guard) ---
setup_evidence_env "code-reviewer"
write_review "TASK-001" "code-reviewer" "UNAPPROVED"
run_validate "TASK-001"
assert_exit_code "verdict UNAPPROVED: exit 1" "$VAL_EC" 1
assert_contains "verdict UNAPPROVED flagged" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
teardown_temp_dir

# --- Test 17: "approval denied" does NOT false-positive (word-boundary guard) ---
setup_evidence_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" << 'REVIEW_EOF'
# Review: TASK-001

## Verdict: approval denied — blocking issues remain
REVIEW_EOF
run_validate "TASK-001"
assert_exit_code "approval denied: exit 1" "$VAL_EC" 1
assert_contains "approval denied flagged unapproved" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
teardown_temp_dir

# --- Structured-verdict path + historical livelock regressions ---
SS_DIR=$(mktemp -d)
mkdir -p "$SS_DIR/reviews/TASK-900"
printf '{"agents":{"reviewers":["code-reviewer"]}}' > "$SS_DIR/config.json"

# Structured APPROVE passes the gate
printf -- '---\nverdict: APPROVE\nconfidence: 95\n---\nlooks good\n' > "$SS_DIR/reviews/TASK-900/code-reviewer.md"
rc=0; validate_review_evidence "$SS_DIR" "TASK-900" >/dev/null || rc=$?
assert_exit_code "structured APPROVE → gate passes" "$rc" 0

# 1.3.2 regression: imperative APPROVE (now the canonical enum value) passes
printf -- '---\nverdict: APPROVE\nconfidence: 80\n---\n' > "$SS_DIR/reviews/TASK-900/code-reviewer.md"
rc=0; validate_review_evidence "$SS_DIR" "TASK-900" >/dev/null || rc=$?
assert_exit_code "1.3.2 imperative APPROVE → passes" "$rc" 0

# Structured CHANGES_REQUESTED is NOT approved
printf -- '---\nverdict: CHANGES_REQUESTED\nconfidence: 90\n---\n' > "$SS_DIR/reviews/TASK-900/code-reviewer.md"
out=$(validate_review_evidence "$SS_DIR" "TASK-900" || true)
assert_contains "CHANGES_REQUESTED → UNAPPROVED" "$out" "UNAPPROVED code-reviewer"

# Malformed verdict fails loudly (not silently approved)
printf -- '---\nverdict: LGTM\nconfidence: 99\n---\n' > "$SS_DIR/reviews/TASK-900/code-reviewer.md"
out=$(validate_review_evidence "$SS_DIR" "TASK-900" || true)
assert_contains "invalid verdict → UNAPPROVED" "$out" "UNAPPROVED code-reviewer"

# 1.3.0 regression: summary.md is meta, not a reviewer file (still excluded)
printf -- '---\nverdict: APPROVE\n---\n' > "$SS_DIR/reviews/TASK-900/code-reviewer.md"
printf -- 'consolidated junk\n' > "$SS_DIR/reviews/TASK-900/summary.md"
rc=0; validate_review_evidence "$SS_DIR" "TASK-900" >/dev/null || rc=$?
assert_exit_code "1.3.0 summary.md ignored → passes" "$rc" 0

# Legacy fallback: old-style verdict line still works when no frontmatter
printf -- '# Review\n\nFinal Verdict: APPROVED — ok\n' > "$SS_DIR/reviews/TASK-900/code-reviewer.md"
rc=0; validate_review_evidence "$SS_DIR" "TASK-900" >/dev/null || rc=$?
assert_exit_code "legacy APPROVED line still passes (fallback)" "$rc" 0
rm -rf "$SS_DIR"

# --- Manifest-aware SKIPPED authorization ---

# Helper: write a .dispatch.json manifest with a given skipped[] name list
# Usage: write_manifest TASK-001 "qa-reviewer:no tests changed"
write_manifest() {
  local unit="$1" skipped_raw="$2"
  mkdir -p "$TEST_DIR/nazgul/reviews/$unit"
  local entries=() entry sname sreason skip_objs=()
  IFS=';' read -ra entries <<< "$skipped_raw"
  for entry in "${entries[@]}"; do
    [ -z "$entry" ] && continue
    sname="${entry%%:*}"
    sreason="${entry#*:}"
    skip_objs+=("$(jq -n --arg n "$sname" --arg r "$sreason" '{name:$n, reason:$r}')")
  done
  local skipped_json="[]"
  [ "${#skip_objs[@]}" -gt 0 ] && skipped_json=$(printf '%s\n' "${skip_objs[@]}" | jq -s '.')
  jq -n --argjson skipped "$skipped_json" '{unit:"'"$unit"'", skipped:$skipped}' \
    > "$TEST_DIR/nazgul/reviews/$unit/.dispatch.json"
}

# Helper: write a diff.patch with `diff --git a/X b/X` headers for given files
# (enough for review-evidence.sh's recompute-and-compare to classify them).
# Usage: write_diff_patch TASK-001 "src/app.py" "tests/test_app.py"
write_diff_patch() {
  local unit="$1"; shift
  mkdir -p "$TEST_DIR/nazgul/reviews/$unit"
  local f out=""
  for f in "$@"; do
    out="${out}diff --git a/${f} b/${f}\n--- a/${f}\n+++ b/${f}\n"
  done
  printf '%b' "$out" > "$TEST_DIR/nazgul/reviews/$unit/diff.patch"
}

# --- Test 18: authorized SKIPPED stub reproducible from the diff — gate satisfied ---
setup_evidence_env "code-reviewer qa-reviewer" '.review_gate.conditional_dispatch = true'
write_review "TASK-001" "code-reviewer" "APPROVED"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: SKIPPED\n---\nskipped: no tests changed\n' > "$TEST_DIR/nazgul/reviews/TASK-001/qa-reviewer.md"
write_diff_patch "TASK-001" "src/app.py"
write_manifest "TASK-001" "qa-reviewer:no tests changed"
run_validate "TASK-001"
assert_exit_code "authorized SKIPPED: exit 0" "$VAL_EC" 0
assert_not_contains "authorized SKIPPED: not MISSING" "$VAL_OUTPUT" "MISSING qa-reviewer"
assert_not_contains "authorized SKIPPED: not UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED qa-reviewer"
teardown_temp_dir

# --- Test 19: authorized SKIPPED with no stub file yet — still gate-satisfying (not MISSING) ---
setup_evidence_env "code-reviewer qa-reviewer" '.review_gate.conditional_dispatch = true'
write_review "TASK-001" "code-reviewer" "APPROVED"
write_diff_patch "TASK-001" "src/app.py"
write_manifest "TASK-001" "qa-reviewer:no tests changed"
run_validate "TASK-001"
assert_exit_code "authorized SKIPPED, no stub: exit 0" "$VAL_EC" 0
assert_not_contains "authorized SKIPPED, no stub: not MISSING" "$VAL_OUTPUT" "MISSING qa-reviewer"
teardown_temp_dir

# --- Test 20: SKIPPED stub with NO manifest — legacy contract intact (still UNAPPROVED) ---
setup_evidence_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: SKIPPED\n---\nskipped: no tests changed\n' > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
run_validate "TASK-001"
assert_exit_code "SKIPPED no manifest: exit 1" "$VAL_EC" 1
assert_contains "SKIPPED no manifest: still UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
teardown_temp_dir

# --- Test 21: security-reviewer in skipped[] is never honored — still required ---
setup_evidence_env "code-reviewer security-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: SKIPPED\n---\nskipped: no security-relevant changes\n' > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md"
write_manifest "TASK-001" "security-reviewer:no security-relevant changes"
run_validate "TASK-001"
assert_exit_code "security-reviewer skip not honored: exit 1" "$VAL_EC" 1
assert_contains "security-reviewer skip not honored: UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED security-reviewer"
teardown_temp_dir

# --- Test 22 (SECURITY, GROUP-2 CRITICAL/82): forged manifest skipping qa on a
# diff that touches tests/ is REJECTED — the skip is not reproducible ---
setup_evidence_env "code-reviewer qa-reviewer" '.review_gate.conditional_dispatch = true'
write_review "TASK-001" "code-reviewer" "APPROVED"
write_diff_patch "TASK-001" "tests/test_app.py"
write_manifest "TASK-001" "qa-reviewer:no tests changed"
run_validate "TASK-001"
assert_exit_code "forged qa skip on tests/ diff: exit 1" "$VAL_EC" 1
assert_contains "forged qa skip on tests/ diff: not honored" "$VAL_OUTPUT" "MISSING qa-reviewer"
teardown_temp_dir

# --- Test 23: manifest whose skipped[] exactly matches the recompute is HONORED
# for a different reviewer (architect-reviewer, tests-only diff) ---
setup_evidence_env "code-reviewer qa-reviewer architect-reviewer" '.review_gate.conditional_dispatch = true'
write_review "TASK-001" "code-reviewer" "APPROVED"
write_review "TASK-001" "qa-reviewer" "APPROVED"
write_diff_patch "TASK-001" "tests/test_app.py"
write_manifest "TASK-001" "architect-reviewer:no architecture-surface change"
run_validate "TASK-001"
assert_exit_code "matching recompute honored: exit 0" "$VAL_EC" 0
assert_not_contains "matching recompute honored: not MISSING" "$VAL_OUTPUT" "MISSING architect-reviewer"
teardown_temp_dir

# --- Test 24 (SECURITY): conditional_dispatch=false + any skip stub is REJECTED,
# even when the diff would otherwise legitimately support the skip ---
setup_evidence_env "code-reviewer qa-reviewer" '.review_gate.conditional_dispatch = false'
write_review "TASK-001" "code-reviewer" "APPROVED"
write_diff_patch "TASK-001" "src/app.py"
write_manifest "TASK-001" "qa-reviewer:no tests changed"
run_validate "TASK-001"
assert_exit_code "conditional_dispatch=false rejects any skip: exit 1" "$VAL_EC" 1
assert_contains "conditional_dispatch=false rejects any skip: not honored" "$VAL_OUTPUT" "MISSING qa-reviewer"
teardown_temp_dir

# --- UNVERIFIED role-aware DONE-gate (FEAT-011 TASK-002) ---

# UNVERIFIED reads as NOT approved (regardless of gate exemption)
setup_evidence_env "code-reviewer"
write_frontmatter_verdict "TASK-001" "code-reviewer" "UNVERIFIED"
rc=0; _has_approved_verdict "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" || rc=$?
assert_exit_code "UNVERIFIED is not approved" "$rc" 1
teardown_temp_dir

# --- Test 25: non-critical UNVERIFIED + toggle default(true) — gate satisfied ---
setup_evidence_env "code-reviewer qa-reviewer"
write_review "TASK-001" "qa-reviewer" "APPROVED"
write_frontmatter_verdict "TASK-001" "code-reviewer" "UNVERIFIED"
run_validate "TASK-001"
assert_exit_code "non-critical UNVERIFIED default toggle: exit 0" "$VAL_EC" 0
assert_not_contains "non-critical UNVERIFIED: not UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
teardown_temp_dir

# --- Test 26: same UNVERIFIED with allow_unverified_nonblocking=false — blocks ---
setup_evidence_env "code-reviewer qa-reviewer" '.review_gate.allow_unverified_nonblocking = false'
write_review "TASK-001" "qa-reviewer" "APPROVED"
write_frontmatter_verdict "TASK-001" "code-reviewer" "UNVERIFIED"
run_validate "TASK-001"
assert_exit_code "UNVERIFIED toggle off: exit 1" "$VAL_EC" 1
assert_contains "UNVERIFIED toggle off: UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
teardown_temp_dir

# --- Test 27: security-reviewer UNVERIFIED always blocks (even toggle on) ---
setup_evidence_env "code-reviewer security-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
write_frontmatter_verdict "TASK-001" "security-reviewer" "UNVERIFIED"
run_validate "TASK-001"
assert_exit_code "security-reviewer UNVERIFIED: exit 1" "$VAL_EC" 1
assert_contains "security-reviewer UNVERIFIED: UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED security-reviewer"
teardown_temp_dir

# --- Test 28: architect-reviewer UNVERIFIED blocks (default critical list) ---
setup_evidence_env "code-reviewer architect-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
write_frontmatter_verdict "TASK-001" "architect-reviewer" "UNVERIFIED"
run_validate "TASK-001"
assert_exit_code "architect UNVERIFIED default: exit 1" "$VAL_EC" 1
assert_contains "architect UNVERIFIED default: UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED architect-reviewer"
teardown_temp_dir

# --- Test 29: custom critical_reviewers list honored — architect drops out of it ---
# With critical_reviewers=["security-reviewer"], architect UNVERIFIED is now
# gate-satisfying, while security-reviewer UNVERIFIED still blocks (never honored).
setup_evidence_env "code-reviewer architect-reviewer security-reviewer" \
  '.review_gate.critical_reviewers = ["security-reviewer"]'
write_review "TASK-001" "code-reviewer" "APPROVED"
write_frontmatter_verdict "TASK-001" "architect-reviewer" "UNVERIFIED"
write_frontmatter_verdict "TASK-001" "security-reviewer" "UNVERIFIED"
run_validate "TASK-001"
assert_exit_code "custom critical list: exit 1 (security still blocks)" "$VAL_EC" 1
assert_not_contains "custom critical list: architect honored" "$VAL_OUTPUT" "UNAPPROVED architect-reviewer"
assert_contains "custom critical list: security still blocks" "$VAL_OUTPUT" "UNAPPROVED security-reviewer"
teardown_temp_dir

# --- Test 30 (REGRESSION): APPROVE / CHANGES_REQUESTED outcomes unchanged ---
setup_evidence_env "code-reviewer qa-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
write_review "TASK-001" "qa-reviewer" "APPROVED"
run_validate "TASK-001"
assert_exit_code "regression APPROVE: exit 0" "$VAL_EC" 0
assert_eq "regression APPROVE: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 31 (REGRESSION): corrupt review_gate fails CLOSED for architect ---
# `.review_gate` a wrong type (string) makes the critical_reviewers jq read exit
# non-zero while the roster still parses; it must degrade to the safe default,
# not to empty — so architect-reviewer UNVERIFIED still blocks (no fail-open).
setup_evidence_env "code-reviewer architect-reviewer" \
  '.review_gate = "corrupt-not-an-object"'
write_review "TASK-001" "code-reviewer" "APPROVED"
write_frontmatter_verdict "TASK-001" "architect-reviewer" "UNVERIFIED"
run_validate "TASK-001"
assert_exit_code "corrupt review_gate: exit 1 (fail closed)" "$VAL_EC" 1
assert_contains "corrupt review_gate: architect blocks" "$VAL_OUTPUT" "UNAPPROVED architect-reviewer"
teardown_temp_dir

# --- Test 31b (REGRESSION): fully unparseable config never fails open ---
setup_evidence_env "code-reviewer architect-reviewer"
write_review "TASK-001" "code-reviewer" "APPROVED"
write_frontmatter_verdict "TASK-001" "architect-reviewer" "UNVERIFIED"
printf '{invalid' > "$TEST_DIR/nazgul/config.json"
run_validate "TASK-001"
assert_exit_code "unparseable config: exit 1 (fail closed)" "$VAL_EC" 1
teardown_temp_dir

# --- Test 32: well-formed empty critical_reviewers honors architect UNVERIFIED ---
# Distinct from Test 31's parse failure: an operator-set `[]` means nothing is
# critical, so architect UNVERIFIED is gate-satisfying.
setup_evidence_env "code-reviewer architect-reviewer" \
  '.review_gate.critical_reviewers = []'
write_review "TASK-001" "code-reviewer" "APPROVED"
write_frontmatter_verdict "TASK-001" "architect-reviewer" "UNVERIFIED"
run_validate "TASK-001"
assert_exit_code "empty critical list: exit 0" "$VAL_EC" 0
assert_not_contains "empty critical list: architect honored" "$VAL_OUTPUT" "UNAPPROVED architect-reviewer"
teardown_temp_dir

report_results
