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
# receipt_hash_enforcement explicitly off here: this block tests the
# frontmatter-verdict parsing path itself (TASK-009 is additive on top of
# it), not receipt-hash matching — none of these fixtures carry a receipt.
SS_DIR=$(mktemp -d)
mkdir -p "$SS_DIR/reviews/TASK-900"
printf '{"agents":{"reviewers":["code-reviewer"]},"review_gate":{"receipt_hash_enforcement":false}}' > "$SS_DIR/config.json"

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

# --- resolve_review_unit() (MF-013, TASK-001) ---
# NOTE: these tests write a real nazgul/tasks/<id>.md manifest via
# create_task_file, unlike setup_evidence_env's fixtures above (which have no
# task file at all, so they exercise the "missing task file → degrade to
# task_id" branch regardless of configured granularity — see Test G below,
# which makes that degrade path explicit).

# --- Test 33: task granularity (default) — returns task_id unchanged ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "task"'
create_task_file "TASK-001" "IMPLEMENTED"
set_task_group "TASK-001" "3"
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "task granularity: unit == task_id" "$UNIT" "TASK-001"
teardown_temp_dir

# --- Test 34: group granularity — Group field present → GROUP-<n> ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
create_task_file "TASK-001" "IMPLEMENTED"
set_task_group "TASK-001" "2"
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "group granularity: GROUP-2" "$UNIT" "GROUP-2"
teardown_temp_dir

# --- Test 35: group granularity — no Group field, falls back to Wave ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
cat > "$TEST_DIR/nazgul/tasks/TASK-001.md" << 'TASK_EOF'
---
status: IMPLEMENTED
---
# TASK-001: Test task

- **Wave**: 4
- **Depends on**: none
- **Retry count**: 0/3
TASK_EOF
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "group granularity: Wave fallback GROUP-4" "$UNIT" "GROUP-4"
teardown_temp_dir

# --- Test 36: group granularity — neither Group nor Wave → default "1" ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
cat > "$TEST_DIR/nazgul/tasks/TASK-001.md" << 'TASK_EOF'
---
status: IMPLEMENTED
---
# TASK-001: Test task

- **Depends on**: none
- **Retry count**: 0/3
TASK_EOF
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "group granularity: no Group/Wave → GROUP-1 default" "$UNIT" "GROUP-1"
teardown_temp_dir

# --- Test 37: feature granularity — feat_id present → FEATURE-<feat_id> ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "feature"' '.feat_id = "FEAT-016"'
create_task_file "TASK-001" "IMPLEMENTED"
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "feature granularity: FEATURE-FEAT-016" "$UNIT" "FEATURE-FEAT-016"
teardown_temp_dir

# --- Test 38: feature granularity — feat_id null/absent — degrades to task_id ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "feature"'
create_task_file "TASK-001" "IMPLEMENTED"
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "feature granularity: null feat_id degrades to task_id" "$UNIT" "TASK-001"
teardown_temp_dir

# --- Test 39: group granularity — task manifest missing — degrades to task_id ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"'
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-999")
assert_eq "group granularity: missing task file degrades to task_id" "$UNIT" "TASK-999"
teardown_temp_dir

# --- Test 40: config.json entirely absent — degrades to task_id (any mode) ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IMPLEMENTED"
set_task_group "TASK-001" "2"
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "no config: degrades to task_id" "$UNIT" "TASK-001"
teardown_temp_dir

# --- Test 41: unparseable config.json — never fails open into group/feature mode ---
setup_temp_dir
setup_nazgul_dir
create_task_file "TASK-001" "IMPLEMENTED"
set_task_group "TASK-001" "2"
printf '{invalid' > "$TEST_DIR/nazgul/config.json"
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "unparseable config: degrades to task_id" "$UNIT" "TASK-001"
teardown_temp_dir

# --- Test 42: invalid granularity value falls back to task mode ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "bogus"'
create_task_file "TASK-001" "IMPLEMENTED"
set_task_group "TASK-001" "2"
UNIT=$(resolve_review_unit "$TEST_DIR/nazgul" "TASK-001")
assert_eq "invalid granularity: falls back to task_id" "$UNIT" "TASK-001"
teardown_temp_dir

# --- Test 43 (end-to-end, MF-013 core regression): validate_review_evidence
# resolves reviews/GROUP-<n> in group granularity, not reviews/<task_id> ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IMPLEMENTED"
set_task_group "TASK-001" "1"
write_review "GROUP-1" "code-reviewer" "APPROVED"
run_validate "TASK-001"
assert_exit_code "group mode: evidence found under GROUP-1: exit 0" "$VAL_EC" 0
assert_eq "group mode: evidence found under GROUP-1: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 44: group mode — evidence only under the WRONG group id still fails ---
# (reviews/TASK-001 exists but is not the resolved unit — proves the fix isn't
# accidentally falling back to the old task-id path.)
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "group"' '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IMPLEMENTED"
set_task_group "TASK-001" "1"
write_review "TASK-001" "code-reviewer" "APPROVED"
run_validate "TASK-001"
assert_exit_code "group mode: task-id-only evidence not honored: exit 1" "$VAL_EC" 1
assert_contains "group mode: task-id-only evidence not honored: NO_REVIEW_DIR" "$VAL_OUTPUT" "NO_REVIEW_DIR"
teardown_temp_dir

# --- Test 45 (end-to-end): validate_review_evidence resolves
# reviews/FEATURE-<feat_id> in feature granularity ---
setup_temp_dir
setup_nazgul_dir
create_config '.review_gate.granularity = "feature"' '.feat_id = "FEAT-016"' \
  '.agents.reviewers = ["code-reviewer"]'
create_task_file "TASK-001" "IMPLEMENTED"
write_review "FEATURE-FEAT-016" "code-reviewer" "APPROVED"
run_validate "TASK-001"
assert_exit_code "feature mode: evidence found under FEATURE-FEAT-016: exit 0" "$VAL_EC" 0
teardown_temp_dir

# --- Test 46 (Bundle 5, FEAT-009 backlog verification): a .dispatch.json
# marking a reviewer resolved:true with NO persisted verdict file still
# reports MISSING — the evidence gate never trusts the manifest's `resolved`
# field (that field means "has a generated agent definition," computed at
# manifest-write time, not "verdict captured"). Confirms the FEAT-009
# incident's underlying concern is closed under the current schema; see
# review-provenance.sh:9 for the resolved field's actual meaning. ---
setup_evidence_env "security-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
jq -n '{unit:"TASK-001", feat_id:"FEAT-009", reviewers:[{name:"security-reviewer", resolved:true}], selected:["security-reviewer"], skipped:[]}' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/.dispatch.json"
# Deliberately NO security-reviewer.md written.
run_validate "TASK-001"
assert_exit_code "resolved:true without persisted file: exit 1" "$VAL_EC" 1
assert_contains "resolved:true without persisted file: still MISSING" "$VAL_OUTPUT" "MISSING security-reviewer"
teardown_temp_dir

# ===========================================================================
# TASK-009 / LR-001 / ADR-005 Decision 4: receipt-hash content gate.
#
# Production shape (verified against agents/review-gate.md Step 2 item 4 and
# scripts/subagent-stop.sh's `_record_reviewer_receipt`, not just assumed):
# a dispatched reviewer's ENTIRE final message (frontmatter fences +
# verdict/confidence + narrative, as authored) is what TASK-002's
# SubagentStop hook hashes into nazgul/logs/review-receipts.jsonl. The
# review-gate orchestrator then persists that SAME text to
# reviews/<unit>/<reviewer>.md with exactly one line, `review_token: TOKEN`,
# inserted into the frontmatter the reviewer authored — fences, verdict,
# confidence, and the entire narrative body are otherwise untouched.
#
# templates/config.json ships review_gate.receipt_hash_enforcement: false
# (opt-in — TASK-009 round-2 correction: TASK-002's carried-forward
# parallel-dispatch receipt-attribution weakness can false-trip in
# execution.parallel mode, this repo's own actual run mode, until an
# attribution-hardening follow-up lands), so every test below that means to
# exercise the check explicitly overrides
# '.review_gate.receipt_hash_enforcement = true' — the implicit-default-on
# assumption this comment used to state is exactly the kind of unstated
# fixture dependency that silently stops testing what it claims to.
# ===========================================================================

# Helper: hash text via the exact pattern both the capture side
# (subagent-stop.sh: `final_text=$(jq -rs ...)`) and the gate side use — a
# bash command substitution strips trailing newlines before the text ever
# reaches _rp_sha256, so this is the correct baseline for both sides.
_test_receipt_hash() {
  printf '%s' "$1" | _rp_sha256
}

# Helper: simulate one full dispatched-reviewer cycle exactly as production
# does it — a receipt for the reviewer's RAW returned text, and a persisted
# file carrying that same text plus one orchestrator-inserted review_token
# line.
# Usage: write_dispatched_review <unit> <reviewer> <verdict> <narrative>
#   [--no-receipt]   never write a review-receipts.jsonl line (reproduces a
#                     receipt-less persisted verdict — the FEAT-016/TASK-005
#                     fabrication shape: an invented verdict for a reviewer
#                     that never actually completed)
#   [--tamper]       persist DIFFERENT narrative than what was hashed into
#                     the receipt (reproduces a rewritten/forged verdict)
write_dispatched_review() {
  local unit="$1" reviewer="$2" verdict="$3" narrative="$4"
  shift 4
  local no_receipt=false tamper=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-receipt) no_receipt=true ;;
      --tamper) tamper=true ;;
    esac
    shift
  done

  local raw hash token persisted_narrative
  raw=$(printf -- '---\nverdict: %s\nconfidence: 90\n---\n%s\n' "$verdict" "$narrative")
  hash=$(_test_receipt_hash "$raw")
  token="deadbeefcafef00d"

  persisted_narrative="$narrative"
  [ "$tamper" = true ] && persisted_narrative="${narrative} TAMPERED AFTER REVIEW."

  mkdir -p "$TEST_DIR/nazgul/reviews/$unit"
  printf -- '---\nverdict: %s\nconfidence: 90\nreview_token: %s\n---\n%s\n' \
    "$verdict" "$token" "$persisted_narrative" \
    > "$TEST_DIR/nazgul/reviews/$unit/${reviewer}.md"

  if [ "$no_receipt" != true ]; then
    mkdir -p "$TEST_DIR/nazgul/logs"
    jq -cn --arg u "$unit" --arg r "$reviewer" --arg h "$hash" --arg ts "2026-07-23T00:00:00Z" \
      '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' \
      >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
  fi
}

# --- Test 47: matching content — persisted body reconstructs to the exact
# receipt hash (the orchestrator's review_token insertion is the ONLY diff
# between the raw captured text and the persisted file) — passes clean ---
setup_evidence_env "code-reviewer" '.review_gate.receipt_hash_enforcement = true'
write_dispatched_review "TASK-001" "code-reviewer" "APPROVE" "Looks good. No blocking issues found."
run_validate "TASK-001"
assert_exit_code "receipt match: exit 0" "$VAL_EC" 0
assert_eq "receipt match: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 48 (FEAT-016/TASK-005 reproduction): persisted body hash does NOT
# match the captured receipt — RECEIPT_MISMATCH, not a silent pass ---
setup_evidence_env "code-reviewer" '.review_gate.receipt_hash_enforcement = true'
write_dispatched_review "TASK-001" "code-reviewer" "APPROVE" "Looks good. No blocking issues found." --tamper
run_validate "TASK-001"
assert_exit_code "receipt mismatch: exit 1" "$VAL_EC" 1
assert_contains "receipt mismatch: RECEIPT_MISMATCH line" "$VAL_OUTPUT" "RECEIPT_MISMATCH code-reviewer"
teardown_temp_dir

# --- Test 49 (CORRECTED — see team-lead design-input messages during
# review): a persisted APPROVE verdict with NO review-receipts.jsonl at all
# for the unit is NOT flagged RECEIPT_MISMATCH. This is a deliberate,
# necessary correction, not the original design: stop-hook.sh's DONE-gate
# reconciliation pass (scripts/stop-hook.sh:231-259) re-runs
# validate_review_evidence against EVERY already-DONE task on EVERY
# iteration. Confirmed live in this repo's own main worktree while building
# this task: nazgul/logs/review-receipts.jsonl does not exist ANYWHERE on
# disk despite 6 tasks (TASK-001..004, 007, 008) already DONE with full
# review boards. A naive "missing receipt is always RECEIPT_MISMATCH" would
# have retroactively reset every one of those to IMPLEMENTED the moment this
# task's code landed — in this project and in every other Nazgul project
# upgrading past schema v30, since NO project's history has receipts before
# this feature shipped. See Test 56 below for the case this DOES still
# catch (a sibling reviewer's receipt proves capture WAS active for this
# board, making one reviewer's absence suspicious) ---
setup_evidence_env "code-reviewer" '.review_gate.receipt_hash_enforcement = true'
write_dispatched_review "TASK-001" "code-reviewer" "APPROVE" "Looks good. No blocking issues found." --no-receipt
run_validate "TASK-001"
assert_exit_code "no receipts at all for unit: exit 0 (capture never active)" "$VAL_EC" 0
assert_not_contains "no receipts at all for unit: not RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH"
teardown_temp_dir

# --- Test 50: review_gate.receipt_hash_enforcement: false — kill switch
# reverts to existence+verdict-only behavior; a tampered, receipt-less body
# is never flagged RECEIPT_MISMATCH ---
setup_evidence_env "code-reviewer" '.review_gate.receipt_hash_enforcement = false'
write_dispatched_review "TASK-001" "code-reviewer" "APPROVE" "Looks good. No blocking issues found." --tamper --no-receipt
run_validate "TASK-001"
assert_exit_code "enforcement off: exit 0" "$VAL_EC" 0
assert_not_contains "enforcement off: never RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH"
teardown_temp_dir

# --- Test 51: a CHANGES_REQUESTED verdict is ALSO receipt-checked — tampered
# content adds RECEIPT_MISMATCH alongside the existing UNAPPROVED problem
# (additive, per the MISSING/UNAPPROVED pattern) ---
setup_evidence_env "code-reviewer" '.review_gate.receipt_hash_enforcement = true'
write_dispatched_review "TASK-001" "code-reviewer" "CHANGES_REQUESTED" "Found a blocking issue in foo.sh." --tamper
run_validate "TASK-001"
assert_exit_code "changes_requested tampered: exit 1" "$VAL_EC" 1
assert_contains "changes_requested tampered: still UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
assert_contains "changes_requested tampered: also RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH code-reviewer"
teardown_temp_dir

# --- Test 52: an authorized SKIPPED stub is NEVER receipt-checked — it is
# orchestrator-authored (no dispatch, no transcript, no receipt ever exists
# for it), so requiring one would break every legitimate skip ---
setup_evidence_env "code-reviewer qa-reviewer" '.review_gate.conditional_dispatch = true' \
  '.review_gate.receipt_hash_enforcement = true'
write_review "TASK-001" "code-reviewer" "APPROVED"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: SKIPPED\nreview_token: deadbeefcafef00d\n---\nskipped: no tests changed\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/qa-reviewer.md"
write_diff_patch "TASK-001" "src/app.py"
write_manifest "TASK-001" "qa-reviewer:no tests changed"
# Deliberately NO nazgul/logs/review-receipts.jsonl at all.
run_validate "TASK-001"
assert_exit_code "SKIPPED never receipt-checked: exit 0" "$VAL_EC" 0
assert_not_contains "SKIPPED never receipt-checked: not RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH"
teardown_temp_dir

# --- Test 53: an authorized UNVERIFIED stub is likewise never receipt-
# checked (same orchestrator-stub reasoning as SKIPPED) ---
setup_evidence_env "code-reviewer" '.review_gate.receipt_hash_enforcement = true'
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: UNVERIFIED\nreview_token: deadbeefcafef00d\n---\nUnverified: timed out\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
# Deliberately NO nazgul/logs/review-receipts.jsonl at all.
run_validate "TASK-001"
assert_exit_code "UNVERIFIED never receipt-checked: exit 0" "$VAL_EC" 0
assert_not_contains "UNVERIFIED never receipt-checked: not RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH"
teardown_temp_dir

# --- Test 54: _re_reconstruct_pretoken_text unit check — a legacy file with
# NO frontmatter fence passes through byte-for-byte unmodified (never had a
# token inserted, so there is nothing to undo) ---
setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf '# Code Review\n\n## Verdict: APPROVED\n\nLegacy body text.\n' > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
RECON_OUT=$(_re_reconstruct_pretoken_text "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md")
ORIG_CONTENT=$(cat "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md")
assert_eq "no-frontmatter file: reconstruction is identity" "$RECON_OUT" "$ORIG_CONTENT"
teardown_temp_dir

# --- Test 55: _re_reconstruct_pretoken_text strips ONLY a review_token line
# strictly inside the frontmatter — a body line that happens to start with
# "review_token:" is left alone, so injected body content can't hide from
# the hash it's supposed to be part of ---
setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: APPROVE\nconfidence: 90\nreview_token: deadbeefcafef00d\n---\nNarrative.\nreview_token: not-really-frontmatter\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
RECON_OUT=$(_re_reconstruct_pretoken_text "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md")
assert_contains "body review_token-like line preserved" "$RECON_OUT" "review_token: not-really-frontmatter"
assert_not_contains "frontmatter review_token line removed" "$RECON_OUT" "deadbeefcafef00d"
teardown_temp_dir

# --- Test 56: a SIBLING reviewer's receipt on record for the SAME unit
# proves capture WAS active for this board — a specific reviewer's own
# receipt still being absent is now the targeted-suppression shape and IS
# flagged RECEIPT_MISMATCH (the case Test 49's correction carves out) ---
setup_evidence_env "code-reviewer qa-reviewer" '.review_gate.receipt_hash_enforcement = true'
write_dispatched_review "TASK-001" "code-reviewer" "APPROVE" "Looks good, ship it."
write_dispatched_review "TASK-001" "qa-reviewer" "APPROVE" "Test coverage is solid." --no-receipt
run_validate "TASK-001"
assert_exit_code "sibling receipt exists, this one missing: exit 1" "$VAL_EC" 1
assert_contains "sibling receipt exists, this one missing: RECEIPT_MISMATCH qa-reviewer" "$VAL_OUTPUT" "RECEIPT_MISMATCH qa-reviewer"
assert_not_contains "sibling receipt exists: code-reviewer itself not flagged" "$VAL_OUTPUT" "RECEIPT_MISMATCH code-reviewer"
teardown_temp_dir

# ===========================================================================
# Verdict-only resolution tolerance (team-lead design-input, live during
# review): review-gate legitimately overwrites ONLY the top-level `verdict:`
# field after Step 3/3.6/3.75 resolution (auto-fix applied, adversarial
# cross-check refuted, confidence-threshold downgrade) — confirmed against
# the REAL 2026-07-23 TASK-002 board's persisted files
# (nazgul/reviews/TASK-002/{architect,code,security}-reviewer.md in the main
# worktree): each carries a `> **review-gate resolution note:** ...` block
# disclosing the flip, with the reviewer's findings/narrative preserved
# "100% verbatim, unedited" below it — exactly the shape these tests model.
# A naive whole-document hash (this task's ORIGINAL design, before the
# correction) would RECEIPT_MISMATCH every one of those three legitimate,
# disclosed resolutions.
# ===========================================================================

# Helper: simulate a Step 3/3.6/3.75 VERDICT-ONLY resolution exactly as the
# real TASK-002 board produced it — reviewer originally returns
# <orig_verdict>/<orig_confidence> + <body>; review-gate persists
# <resolved_verdict> with a disclosed "review-gate resolution note" block
# inserted between the frontmatter and the reviewer's untouched body.
# Usage: write_resolved_review <unit> <reviewer> <orig_verdict> <orig_confidence> \
#   <resolved_verdict> <body> [--no-note] [--tamper-body]
write_resolved_review() {
  local unit="$1" reviewer="$2" orig_verdict="$3" orig_confidence="$4" resolved_verdict="$5" body="$6"
  shift 6
  local no_note=false tamper_body=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-note) no_note=true ;;
      --tamper-body) tamper_body=true ;;
    esac
    shift
  done

  # The RAW text a dispatched reviewer actually returned — what TASK-002's
  # SubagentStop hook hashes into the receipt.
  local raw hash
  raw=$(printf -- '---\nverdict: %s\nconfidence: %s\n---\n\n%s\n' "$orig_verdict" "$orig_confidence" "$body")
  hash=$(_test_receipt_hash "$raw")

  mkdir -p "$TEST_DIR/nazgul/reviews/$unit"
  local persisted_body="$body"
  [ "$tamper_body" = true ] && persisted_body="${body} TAMPERED AFTER RESOLUTION."

  if [ "$no_note" = true ]; then
    printf -- '---\nverdict: %s\nconfidence: %s\nreview_token: deadbeefcafef00d\n---\n\n%s\n' \
      "$resolved_verdict" "$orig_confidence" "$persisted_body" \
      > "$TEST_DIR/nazgul/reviews/$unit/${reviewer}.md"
  else
    printf -- '---\nverdict: %s\nconfidence: %s\nreview_token: deadbeefcafef00d\n---\n\n> **review-gate resolution note:** the original verdict %s was resolved to %s per Step 3.6 — findings preserved verbatim below.\n\n%s\n' \
      "$resolved_verdict" "$orig_confidence" "$orig_verdict" "$resolved_verdict" "$persisted_body" \
      > "$TEST_DIR/nazgul/reviews/$unit/${reviewer}.md"
  fi

  mkdir -p "$TEST_DIR/nazgul/logs"
  jq -cn --arg u "$unit" --arg r "$reviewer" --arg h "$hash" --arg ts "2026-07-23T00:00:00Z" \
    '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' \
    >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
}

# --- Test 57 (structural check): a disclosed, note-backed verdict flip
# (CHANGES_REQUESTED -> APPROVE, confidence unchanged, findings preserved
# verbatim below the note) passes clean — no RECEIPT_MISMATCH ---
setup_evidence_env "security-reviewer" '.review_gate.receipt_hash_enforcement = true'
write_resolved_review "TASK-001" "security-reviewer" "CHANGES_REQUESTED" "75" "APPROVE" \
  "## Scope of review

Read the diff. Found one HIGH finding, downgraded per Step 3.6 adversarial cross-check."
run_validate "TASK-001"
assert_exit_code "disclosed verdict-only flip: exit 0" "$VAL_EC" 0
assert_eq "disclosed verdict-only flip: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 57b (qa-reviewer round-1 requirement, round-4 UPGRADE: the FULL,
# UNTRUNCATED real nazgul/reviews/TASK-002/security-reviewer.md, all 91
# lines, pasted verbatim at authoring time so the test is self-contained and
# doesn't depend on that gitignored runtime file surviving to a future run.
# Round-4 correction: the PRIOR version of this test truncated the fixture
# "frontmatter through the first finding" and stopped BEFORE the file's
# trailing "---\n**Orchestrator note (review-gate Step 3.6...)" block — which
# is exactly why it passed even though candidate (ii) alone (top-revert only)
# cannot reconstruct the full real file (architect round-2 finding). This
# fixture is the real, full, untruncated file — it exercises the "both"
# composed candidate (top-revert AND trailing-strip), not just top-revert. ---
#
# METHODOLOGY DISCLOSURE (per round-4 instruction — the receipt below is
# derived FROM this same reconstruction's own output, then validated against
# a receipt built from that hash: internally self-consistent against the
# real bytes, NOT verified against an independently-captured ground-truth
# receipt, since none exists in this repo — nazgul/logs/review-receipts.jsonl
# has no TASK-002 entries at all. This is the strongest verification
# available without a live capture to compare against, stated plainly.)
setup_evidence_env "security-reviewer" '.review_gate.receipt_hash_enforcement = true'
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" << 'REALFIXTURE'
---
verdict: APPROVE
confidence: 75
review_token: a32840175b088c96
---

> **review-gate resolution note:** `_has_approved_verdict` (`scripts/lib/review-evidence.sh`) is
> VERDICT-ONLY by design — its own header comment states "confidence is handled by the review-gate
> agent," i.e. review-gate resolves confidence-threshold/Step 3.6 outcomes into the persisted
> `verdict:` field before the mechanical gate reads it. This reviewer's own self-authored header (as
> originally returned) was `verdict: CHANGES_REQUESTED, confidence: 75`. Its one blocking finding
> (unguarded jq under `set -e`, HIGH, confidence 82) was cross-checked per Step 3.6 and REFUTEd at
> confidence 90 (see the trailing orchestrator note below and
> `nazgul/reviews/TASK-002/adversarial/security-jq-guard.md`) — downgraded to a non-blocking CONCERN.
> With zero blocking findings remaining, this review resolves to APPROVED for gating purposes. The
> `verdict:` field above has been updated from the reviewer's original `CHANGES_REQUESTED` to
> `APPROVE` to reflect that resolution — **every finding and all narrative content below is preserved
> 100% verbatim, unedited, exactly as the reviewer returned it.** Full tally:
> `nazgul/reviews/TASK-002/consolidated-feedback.md`.

## Scope of review

Read `nazgul/reviews/TASK-002/diff.patch` (254 lines: `scripts/subagent-stop.sh` `_record_reviewer_receipt()` + `tests/test-subagent-stop.sh` Tests 13-17), the task manifest, the full current `scripts/subagent-stop.sh`, `scripts/lib/review-provenance.sh` (`_rp_sha256`, `write_dispatch_manifest`, `validate_review_provenance`), and the sibling `.transcript_path` precedent in `scripts/notify.sh:90`.

### Finding: Unguarded `jq` command substitutions in the manifest-scan loop can silently kill receipt capture on a single malformed `.dispatch.json`
- **Severity**: HIGH
- **Confidence**: 82
- **File**: `scripts/subagent-stop.sh:176,179-180` (worktree copy; same lines in the diff hunk, `_record_reviewer_receipt()` manifest-matching loop)
- **Category**: Security (safety-guard/mechanism integrity)
- **Verdict**: REJECT
- **Issue**: The script has `set -euo pipefail` (line 2). Inside the `for manifest in "$reviews_dir"/*/.dispatch.json` loop, three command substitutions are bare assignments with no `||` fallback:
  ```bash
  is_selected=$(jq -r --arg a "$AGENT" '(.selected // []) | any(. == $a)' "$manifest" 2>/dev/null)
  this_unit=$(jq -r '.unit // empty' "$manifest" 2>/dev/null)
  this_created=$(jq -r '.created_at // empty' "$manifest" 2>/dev/null)
  ```
  `local is_selected` / `is_selected=$(...)` are correctly split onto separate lines (avoiding the SC2155 "local masks return value" footgun) — but that means the fix for one footgun reintroduces the *other*: since the assignment is now a standalone simple command (not combined with `local`), its exit status is no longer masked, and `set -e` *will* trigger on it. If `jq` returns non-zero for ANY `.dispatch.json` under `nazgul/reviews/*/` (malformed JSON, partial/torn write, or a file deliberately dropped by a bash-capable agent), the loop — and the whole `_record_reviewer_receipt` function — aborts immediately at that statement. The `2>/dev/null` only suppresses jq's stderr diagnostic; it does not change the exit code. The abort is swallowed by the caller's `_record_reviewer_receipt || true` (line 219), so the hook still exits 0 with zero visible symptom: no error, no crash, no distinguishing log line — the function just silently produces no receipt line, indistinguishable from any of the intentional "safe no-op" paths.
  This is exploitable by exactly the actor this mechanism (LR-001) is designed to keep honest: review-gate (or any bash-capable subagent) has unrestricted write access to `nazgul/reviews/`, and `write_dispatch_manifest`'s own header explicitly documents this is "tamper-EVIDENCE... NOT authentication... a determined actor with shell access could forge one." A single adversarial or buggy `.dispatch.json` anywhere in `nazgul/reviews/` — not even the current unit's — silently disables receipt capture for every subsequent reviewer completion scanned in that pass, directly undermining the task's own stated acceptance criterion of appending receipts "reliably."
  This is also an internal inconsistency: the pre-existing `_record_review_coverage()` function immediately above in the same file guards every comparable jq assignment with an explicit fallback (`... || echo "default"`, `... || echo "null"`, `... || true`) precisely to avoid this class of bug. The new function does not follow that established, load-bearing pattern.
- **Fix**: Add explicit fallbacks matching the file's own convention, e.g.:
  ```bash
  is_selected=$(jq -r --arg a "$AGENT" '(.selected // []) | any(. == $a)' "$manifest" 2>/dev/null) || continue
  ...
  this_unit=$(jq -r '.unit // empty' "$manifest" 2>/dev/null) || continue
  this_created=$(jq -r '.created_at // empty' "$manifest" 2>/dev/null) || true
  ```
  Add a test case: seed `nazgul/reviews/<other-unit>/.dispatch.json` with invalid JSON (or an unreadable permission-0000 file) alongside a valid, matching manifest for the completing agent, and assert the valid unit's receipt is still written despite the corrupt sibling.
- **Pattern reference**: `scripts/subagent-stop.sh:53-54` (`_record_review_coverage`) — `feat_id=$(jq -r '.feat_id // "default"' "$CONFIG" 2>/dev/null || echo "default")` and `cur_iter=$(... || echo "null")` show the established defensive idiom this new function should mirror.
- **Rule reference**: none (no existing LR covers this; recommend logging as a new LR once fixed — "jq command substitutions inside `set -e` scripts must always carry an explicit `||` fallback, even when correctly split from `local`").

### Finding: Manifest tie-break trusts review-gate-controlled `created_at`/`selected` fields with no independent ordering signal
- **Severity**: MEDIUM
- **Confidence**: 55
- **File**: `scripts/subagent-stop.sh:172-186`
- **Category**: Security (state-machine/evidence-mechanism integrity)
- **Verdict**: CONCERN
- **Issue**: When the same reviewer name is `selected` in more than one unit's `.dispatch.json` at once, resolution picks the manifest with the lexicographically greatest `created_at` string. Both `selected` and `created_at` are fields review-gate itself writes via `write_dispatch_manifest` (or, since nothing enforces that path, via any direct `jq`/`printf` write) with no cryptographic binding to wall-clock time or to the actual dispatch event. A review-gate process could write a second `.dispatch.json` for a decoy/forged unit, listing the same reviewer name in `selected` with a `created_at` engineered to sort after the real manifest's, causing a real reviewer's genuine receipt to be misattributed away from its true unit — silently starving the correct unit of any receipt (see the fail-open finding below) while depositing an unrelated-but-real hash under the decoy unit. Because `review-provenance.sh` itself documents this is "tamper-EVIDENCE... NOT authentication," this isn't a regression this task introduces from nothing, but the tie-break rule as designed gives an adversarial review-gate a low-cost way to defeat the receipt's unit-binding guarantee before TASK-009's consumer even exists.
- **Fix**: Not blocking for TASK-002 given the explicit TRD sequencing (capture here, evidence-gate cross-check in TASK-009), but the tie-break design should be revisited before TASK-009 locks in its RECEIPT_MISMATCH logic — e.g., key on the manifest whose `nonce`/`token` correlates with data review-gate cannot easily backdate, or treat "reviewer name selected in >1 concurrently-live manifest" as itself suspicious/loggable rather than silently resolved.
- **Pattern reference**: `scripts/lib/review-provenance.sh:14-19` (header's own "HONEST TIER" disclosure).
- **Rule reference**: LR-001 (this is exactly the threat model LR-001 exists to eventually catch via TASK-009; flagging so the tie-break isn't taken as already-solved).

### Finding: Fail-open paths produce no distinguishing signal between "not a reviewer" and "reviewer selected but capture failed"
- **Severity**: LOW
- **Confidence**: 50
- **File**: `scripts/subagent-stop.sh:155-217`
- **Category**: Security (evidence-gate design gap, forward-looking)
- **Verdict**: CONCERN
- **Issue**: Every error path — no `jq`, empty `INPUT`, missing/unreadable `agent_transcript_path`, no matching manifest, empty `final_text`, hash failure — is an identical silent no-op with zero record of *why*. A future consumer (TASK-009) cannot distinguish "this agent was never dispatched as a reviewer for anything" (expected, benign) from "this agent WAS a selected reviewer per some `.dispatch.json` but its receipt capture failed" (should be treated as suspicious/fail-closed, per the task's own framing of what a missing receipt should mean later). As implemented, both collapse to the same observable state: no line in `review-receipts.jsonl`.
- **Fix**: Not required for this task's stated scope (capture-only; TASK-009 owns consumption), but worth carrying forward explicitly into TASK-009's manifest as a hard requirement, or — cheaply — emit a distinguishing sentinel line here when a manifest match IS found but transcript read/hash fails (e.g. `{unit, reviewer, hash: null, ts, error: "unreadable_transcript"}`) so "known-selected-but-uncaptured" is queryable later.
- **Pattern reference**: none in-repo yet (this would be new).
- **Rule reference**: none; flag for TASK-009 planning.

### Reviewed and passing

- **(a) Path/content trust** — PASS (confidence 88). `.agent_transcript_path` and `$AGENT` come from the same hook-stdin JSON already trusted for `.subagent_type`/`.agent_type`/`.name` and mirrors `notify.sh:90`'s existing `.transcript_path` read — no new trust boundary is crossed, no path is constructed from concatenated untrusted segments, and the file is only ever read via `jq -rs FILTER "$path"` (quoted, never globbed, never executed).
- **(c) Injection/shell safety** — PASS (confidence 90). Every jq invocation uses `--arg`; `$final_text`/`$unit`/`$AGENT`/`$hash`/`$ts` are only ever passed as `--arg` values into `jq -cn`, never string-interpolated into a jq filter or a shell command; no `eval`; `printf '%s' "$final_text" | _rp_sha256` treats content strictly as data.
- **(e) Log integrity/concurrency** — PASS (confidence 80). `jq -cn ... >> "$receipts_file"` is a single small (well under `PIPE_BUF`) `O_APPEND` write, atomic against concurrent appenders under `execution.parallel`, and matches the existing `events.jsonl`/`review-coverage.jsonl` append convention used directly above in the same file — not a violation of the project's temp-then-`mv` rule, since that rule applies to mutated JSON *documents* (e.g. `.dispatch.json`), not append-only JSONL logs.
- **Safety-guard integrity / state machine / AFK** — PASS (confidence 90). This diff touches only `subagent-stop.sh` and its test file; it does not modify `pre-tool-guard.sh`, `task-state-guard.sh`, `prompt-guard.sh`, `task-transition-guard.sh`, or any DONE/evidence-gate logic, and adds no new destructive command capability, so no matching guard-rule-plus-test obligation applies.
- **Secret exposure** — PASS (confidence 90). No secrets/tokens are read, logged, or forwarded; the receipt line contains only `unit`, `reviewer` (agent role name), a content hash, and a timestamp.

### Summary
- PASS: path/content trust (a), injection/shell safety (c), log-append concurrency (e), guard integrity/state-machine/AFK safety unaffected, no secret exposure.
- CONCERN: manifest tie-break trusts review-gate-controlled fields with no independent ordering signal (confidence 55); fail-open paths give TASK-009 no way to distinguish "not applicable" from "capture failed for a known reviewer" (confidence 50).
- REJECT: unguarded `jq` command substitutions in the manifest-scan loop can be silently aborted by `set -e` on any single malformed `.dispatch.json` anywhere under `nazgul/reviews/`, killing receipt capture with zero signal, inconsistent with this same file's own established defensive pattern (confidence 82).

## Final Verdict

CHANGES_REQUESTED. The blocking issue is narrow and mechanical: add `|| continue`/`|| true` fallbacks to the three unguarded `jq` assignments in the `.dispatch.json` scan loop (mirroring `_record_review_coverage`'s existing idiom in the same file) and add one test case exercising a malformed/corrupt sibling `.dispatch.json`. The two CONCERN items (tie-break trust, fail-open ambiguity) are architectural and legitimately belong to TASK-009 per this task's own stated sequencing — they don't need to block TASK-002, but should be explicitly carried into TASK-009's design so the eventual RECEIPT_MISMATCH gate isn't built on the assumption that "no receipt" always means "not a reviewer."

---
**Orchestrator note (review-gate Step 3.6 — adversarial cross-check, resolved):** the sole HIGH-severity REJECT finding above (confidence 82, in the borderline band [80, 90) per `adversarial_margin: 10`) was cross-checked per the bounded adversarial process. The orchestrator empirically ran the actual `scripts/subagent-stop.sh` twice against a real malformed sibling `.dispatch.json` (both file-ordering cases) and confirmed the hook exits 0 with the correct receipt still written — the claimed abort does not occur, because `_record_reviewer_receipt` is invoked as `_record_reviewer_receipt || true`, and per POSIX/bash AND-OR-list semantics `errexit` is suspended for the *entire* execution of a command on the left of `||`, not just its own top-level exit check; the guard clause `[ "$is_selected" = "true" ] || continue` then safely treats the resulting empty `is_selected` as "not selected." A fresh adversarial code-reviewer instance independently confirmed this reasoning against the GNU Bash Reference Manual's documented AND-OR-list exception and **REFUTEd the finding at confidence 90** (>= `confidence_threshold: 80`). Per Step 3.6 resolution rules, this finding is **DOWNGRADED from blocking REJECT to a non-blocking CONCERN**. Full cross-check detail: `nazgul/reviews/TASK-002/adversarial/security-jq-guard.md`. This downgrade is logged prominently here per the "security findings stay fail-closed" clause's disclosure requirement. The finding's *narrative content* above is preserved verbatim and unmodified — only its blocking status changes, recorded here and in `consolidated-feedback.md`, not by editing the finding itself.
REALFIXTURE
# Ground-truth receipt: derive via the MOST-reverted available candidate
# (both top-revert AND trailing-strip — this real file has both notes),
# self-consistently, per the methodology disclosure above.
FIXTURE_PATH="$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md"
REAL_TOP=$(_re_reconstruct_pretoken_text "$FIXTURE_PATH" --revert-resolution)
REAL_BOTH=$(printf '%s\n' "$REAL_TOP" | _re_strip_trailing_orchestrator_note)
REAL_HASH=$(printf '%s' "$REAL_BOTH" | _rp_sha256)
mkdir -p "$TEST_DIR/nazgul/logs"
jq -cn --arg u "TASK-001" --arg r "security-reviewer" --arg h "$REAL_HASH" --arg ts "2026-07-23T00:00:00Z" \
  '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
run_validate "TASK-001"
assert_exit_code "real UNTRUNCATED TASK-002-shape fixture (both notes): exit 0" "$VAL_EC" 0
assert_eq "real UNTRUNCATED TASK-002-shape fixture (both notes): no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 57c (compositional case, decisive negative): the SAME full real
# fixture, but with one sentence in the body tampered — must fail ALL FOUR
# candidates, not just the ones round-3 already tried. This is the direct
# answer to "would your design catch a gate that dresses up a rewritten
# narrative with BOTH sanctioned notes to get it past the gate?" ---
setup_evidence_env "security-reviewer" '.review_gate.receipt_hash_enforcement = true'
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
TAMPERED_FIXTURE="$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md"
cat > "$TAMPERED_FIXTURE" << 'TAMPEREDFIXTURE'
---
verdict: APPROVE
confidence: 75
review_token: a32840175b088c96
---

> **review-gate resolution note:** `_has_approved_verdict` (`scripts/lib/review-evidence.sh`) is
> VERDICT-ONLY by design — its own header comment states "confidence is handled by the review-gate
> agent," i.e. review-gate resolves confidence-threshold/Step 3.6 outcomes into the persisted
> `verdict:` field before the mechanical gate reads it. This reviewer's own self-authored header (as
> originally returned) was `verdict: CHANGES_REQUESTED, confidence: 75`. Its one blocking finding
> (unguarded jq under `set -e`, HIGH, confidence 82) was cross-checked per Step 3.6 and REFUTEd at
> confidence 90 (see the trailing orchestrator note below and
> `nazgul/reviews/TASK-002/adversarial/security-jq-guard.md`) — downgraded to a non-blocking CONCERN.
> With zero blocking findings remaining, this review resolves to APPROVED for gating purposes. The
> `verdict:` field above has been updated from the reviewer's original `CHANGES_REQUESTED` to
> `APPROVE` to reflect that resolution — **every finding and all narrative content below is preserved
> 100% verbatim, unedited, exactly as the reviewer returned it.** Full tally:
> `nazgul/reviews/TASK-002/consolidated-feedback.md`.

## Scope of review

TAMPERED SENTENCE HERE — this narrative was rewritten after the fact, exactly the FEAT-016/TASK-005 fabrication shape, dressed up with both sanctioned notes to try to get past the gate.

### Finding: Unguarded `jq` command substitutions in the manifest-scan loop can silently kill receipt capture on a single malformed `.dispatch.json`
- **Severity**: HIGH
- **Confidence**: 82
- **Verdict**: REJECT (downgraded to CONCERN per the Step 3.6 note above)

## Final Verdict

CHANGES_REQUESTED, resolved per the notes above.

---
**Orchestrator note (review-gate Step 3.6 — adversarial cross-check, resolved):** the sole HIGH-severity REJECT finding above was cross-checked and REFUTEd. Per Step 3.6 resolution rules, this finding is DOWNGRADED from blocking REJECT to a non-blocking CONCERN.
TAMPEREDFIXTURE
# Use the SAME ground-truth hash as Test 57b (the real, untampered file's
# receipt) — this tampered file must NOT match it via any candidate.
mkdir -p "$TEST_DIR/nazgul/logs"
jq -cn --arg u "TASK-001" --arg r "security-reviewer" --arg h "$REAL_HASH" --arg ts "2026-07-23T00:00:00Z" \
  '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
run_validate "TASK-001"
assert_exit_code "tampered body dressed up with both notes: exit 1" "$VAL_EC" 1
assert_contains "tampered body dressed up with both notes: RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH security-reviewer"
teardown_temp_dir

# --- Test 57d (compositional case: TRAILING note only, no top flip) — a
# Step 3 confidence-threshold downgrade can leave the OVERALL verdict at
# CHANGES_REQUESTED (other findings still block) while still appending a
# trailing orchestrator note about the ONE downgraded finding. Confirms the
# trailing-strip transform has no verdict precondition of its own. ---
setup_evidence_env "security-reviewer" '.review_gate.receipt_hash_enforcement = true'
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
TRAILING_ONLY_RAW=$(printf -- '---\nverdict: CHANGES_REQUESTED\nconfidence: 75\n---\n\n## Scope\n\nStill has an unrelated blocking finding.\n')
TRAILING_ONLY_HASH=$(printf '%s' "$TRAILING_ONLY_RAW" | _rp_sha256)
printf -- '---\nverdict: CHANGES_REQUESTED\nconfidence: 75\nreview_token: deadbeefcafef00d\n---\n\n## Scope\n\nStill has an unrelated blocking finding.\n\n---\n**Orchestrator note (review-gate Step 3):** one finding was downgraded below threshold; other findings still block.\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md"
mkdir -p "$TEST_DIR/nazgul/logs"
jq -cn --arg u "TASK-001" --arg r "security-reviewer" --arg h "$TRAILING_ONLY_HASH" --arg ts "2026-07-23T00:00:00Z" \
  '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
run_validate "TASK-001"
assert_exit_code "trailing-note-only, still CHANGES_REQUESTED: exit 1 (UNAPPROVED, not RECEIPT_MISMATCH)" "$VAL_EC" 1
assert_contains "trailing-note-only: UNAPPROVED (legitimately still requested)" "$VAL_OUTPUT" "UNAPPROVED security-reviewer"
assert_not_contains "trailing-note-only: content itself matches, no RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH"
teardown_temp_dir

# --- Test 57e (compositional case: TRAILING note only, verdict was ALREADY
# APPROVE from the start — no top flip ever needed, but a Step 3 note still
# documents a sub-threshold finding's disposition). Passes clean via
# candidate 3 (trailing-stripped only) — the true "matches cleanly" case,
# distinct from Test 57d where the verdict legitimately stays UNAPPROVED. ---
setup_evidence_env "security-reviewer" '.review_gate.receipt_hash_enforcement = true'
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
ALREADY_APPROVE_RAW=$(printf -- '---\nverdict: APPROVE\nconfidence: 90\n---\n\n## Scope\n\nNo blocking issues found.\n')
ALREADY_APPROVE_HASH=$(printf '%s' "$ALREADY_APPROVE_RAW" | _rp_sha256)
printf -- '---\nverdict: APPROVE\nconfidence: 90\nreview_token: deadbeefcafef00d\n---\n\n## Scope\n\nNo blocking issues found.\n\n---\n**Orchestrator note (review-gate Step 3):** one sub-threshold finding was automatically downgraded to non-blocking per the confidence-threshold rule; verdict was already APPROVE, unaffected.\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md"
mkdir -p "$TEST_DIR/nazgul/logs"
jq -cn --arg u "TASK-001" --arg r "security-reviewer" --arg h "$ALREADY_APPROVE_HASH" --arg ts "2026-07-23T00:00:00Z" \
  '{unit:$u, reviewer:$r, hash:$h, ts:$ts}' >> "$TEST_DIR/nazgul/logs/review-receipts.jsonl"
run_validate "TASK-001"
assert_exit_code "trailing-note-only, verdict already APPROVE: exit 0" "$VAL_EC" 0
assert_eq "trailing-note-only, verdict already APPROVE: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 58 (the decisive FEAT-016/TASK-005 check — "would your design
# have caught a gate inverting CHANGES_REQUESTED->APPROVE with a rewritten
# narrative?"): a resolution note is present (disclosed, well-formed), but
# the body BELOW the note was ALSO altered from what the reviewer actually
# returned — still RECEIPT_MISMATCH. A disclosed note only excuses the
# verdict field; it never excuses content tampering ---
setup_evidence_env "security-reviewer" '.review_gate.receipt_hash_enforcement = true'
write_resolved_review "TASK-001" "security-reviewer" "CHANGES_REQUESTED" "75" "APPROVE" \
  "## Scope of review

Read the diff. Found one HIGH finding, downgraded per Step 3.6 adversarial cross-check." \
  --tamper-body
run_validate "TASK-001"
assert_exit_code "note present but body tampered: exit 1" "$VAL_EC" 1
assert_contains "note present but body tampered: RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH security-reviewer"
teardown_temp_dir

# --- Test 59: an UNDISCLOSED verdict flip (verdict changed, body otherwise
# untouched, but NO resolution note at all) is RECEIPT_MISMATCH — candidate
# (ii)'s deterministic reversal in _re_receipt_matches requires BOTH the
# exact prior verdict AND the exact canonical marker; without a note it is
# never attempted, so a bare flip can never silently pass ---
setup_evidence_env "security-reviewer" '.review_gate.receipt_hash_enforcement = true'
write_resolved_review "TASK-001" "security-reviewer" "CHANGES_REQUESTED" "75" "APPROVE" \
  "## Scope of review

Read the diff. Found one HIGH finding, downgraded per Step 3.6 adversarial cross-check." \
  --no-note
run_validate "TASK-001"
assert_exit_code "undisclosed flip, no note: exit 1" "$VAL_EC" 1
assert_contains "undisclosed flip, no note: RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH security-reviewer"
teardown_temp_dir

# --- Test 60: _re_reconstruct_pretoken_text --revert-resolution unit check
# — a well-formed, exact-marker note on a currently-APPROVE verdict is
# stripped, the verdict is deterministically reverted to CHANGES_REQUESTED,
# and the note collapses back to the single blank line that separates
# frontmatter from narrative in every reviewer's own unedited return
# (verified against the real nazgul/reviews/TASK-002/qa-reviewer.md
# convention, TASK-009 Implementation Log) ---
setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: APPROVE\nconfidence: 75\nreview_token: deadbeefcafef00d\n---\n\n> **review-gate resolution note:** flipped per Step 3.6.\n> Second note line.\n\n## Scope\n\nBody text.\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md"
RECON_OUT=$(_re_reconstruct_pretoken_text "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" --revert-resolution)
RECON_EC=$?
assert_exit_code "--revert-resolution: well-formed note detected (exit 0)" "$RECON_EC" 0
assert_contains "--revert-resolution: verdict reverted to CHANGES_REQUESTED" "$RECON_OUT" "verdict: CHANGES_REQUESTED"
assert_not_contains "--revert-resolution: note text removed" "$RECON_OUT" "resolution note"
assert_contains "--revert-resolution: body preserved" "$RECON_OUT" "Body text."
teardown_temp_dir

# --- Test 61: _re_reconstruct_pretoken_text --revert-resolution returns
# failure (no output) when no note is present — callers must never revert a
# verdict without a genuine, disclosed note backing it ---
setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: APPROVE\nconfidence: 90\nreview_token: deadbeefcafef00d\n---\n\n## Scope\n\nBody text, no note.\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
RECON_OUT=$(_re_reconstruct_pretoken_text "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" --revert-resolution)
RECON_EC=$?
assert_exit_code "--revert-resolution: no note present (exit 1, no output)" "$RECON_EC" 1
assert_eq "--revert-resolution: no note present: empty output" "$RECON_OUT" ""
teardown_temp_dir

# --- Test 62: _re_reconstruct_pretoken_text --revert-resolution returns
# failure when the persisted verdict is NOT APPROVE — CHANGES_REQUESTED is
# the only sanctioned flip target's ORIGIN, never itself a value to revert
# FROM; a note present on a still-CHANGES_REQUESTED file is not the
# sanctioned shape and must not be tolerated ---
setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: CHANGES_REQUESTED\nconfidence: 75\nreview_token: deadbeefcafef00d\n---\n\n> **review-gate resolution note:** not actually resolved.\n\n## Scope\n\nBody text.\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md"
RECON_OUT=$(_re_reconstruct_pretoken_text "$TEST_DIR/nazgul/reviews/TASK-001/security-reviewer.md" --revert-resolution)
RECON_EC=$?
assert_exit_code "--revert-resolution: verdict not APPROVE (exit 1, no output)" "$RECON_EC" 1
assert_eq "--revert-resolution: verdict not APPROVE: empty output" "$RECON_OUT" ""
teardown_temp_dir

# --- Test 63: _re_reconstruct_pretoken_text --revert-resolution returns
# failure when a blockquote is present but does NOT open with the EXACT
# canonical marker — precision check: the phrase appearing later in the
# block, or a differently-worded blockquote, is not the canonical shape ---
setup_temp_dir
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
printf -- '---\nverdict: APPROVE\nconfidence: 90\nreview_token: deadbeefcafef00d\n---\n\n> Some unrelated blockquote that just happens to mention review-gate resolution note later.\n\n## Scope\n\nBody text.\n' \
  > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md"
RECON_OUT=$(_re_reconstruct_pretoken_text "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" --revert-resolution)
RECON_EC=$?
assert_exit_code "--revert-resolution: non-canonical blockquote (exit 1, no output)" "$RECON_EC" 1
assert_eq "--revert-resolution: non-canonical blockquote: empty output" "$RECON_OUT" ""
teardown_temp_dir

# --- Test 64: _re_strip_trailing_orchestrator_note unit check — a
# well-formed trailing block (---  then a line starting with the exact
# literal prefix) is stripped from that --- through EOF, regardless of
# verdict (no precondition of its own) ---
TRAIL_IN=$(printf -- '## Scope\n\nBody text.\n\n---\n**Orchestrator note (review-gate Step 3.6 — adversarial cross-check, resolved):** downgraded.\n')
TRAIL_OUT=$(printf '%s\n' "$TRAIL_IN" | _re_strip_trailing_orchestrator_note)
TRAIL_EC=$?
assert_exit_code "trailing-strip: well-formed block detected (exit 0)" "$TRAIL_EC" 0
assert_not_contains "trailing-strip: orchestrator note removed" "$TRAIL_OUT" "Orchestrator note"
assert_contains "trailing-strip: body preserved" "$TRAIL_OUT" "Body text."

# --- Test 65: _re_strip_trailing_orchestrator_note returns failure (no
# output) when no trailing block is present ---
NOTAIL_IN=$(printf -- '## Scope\n\nBody text, no trailing note.\n')
NOTAIL_OUT=$(printf '%s\n' "$NOTAIL_IN" | _re_strip_trailing_orchestrator_note)
NOTAIL_EC=$?
assert_exit_code "trailing-strip: no block present (exit 1, no output)" "$NOTAIL_EC" 1
assert_eq "trailing-strip: no block present: empty output" "$NOTAIL_OUT" ""

# --- Test 66: _re_strip_trailing_orchestrator_note precision check — a
# trailing '---' followed by an UNRELATED blockquote (not the canonical
# prefix) is left alone, not stripped ---
UNRELATED_IN=$(printf -- '## Scope\n\nBody text.\n\n---\n**Some other trailing note, not the canonical marker.**\n')
UNRELATED_OUT=$(printf '%s\n' "$UNRELATED_IN" | _re_strip_trailing_orchestrator_note)
UNRELATED_EC=$?
assert_exit_code "trailing-strip: non-canonical trailing block (exit 1, no output)" "$UNRELATED_EC" 1
assert_eq "trailing-strip: non-canonical trailing block: empty output" "$UNRELATED_OUT" ""

report_results
