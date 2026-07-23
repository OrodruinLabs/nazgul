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
# templates/config.json ships review_gate.receipt_hash_enforcement: true
# (TASK-003, schema v30), so create_config/setup_evidence_env already default
# enforcement ON — no override needed for the "on" cases below.
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
setup_evidence_env "code-reviewer"
write_dispatched_review "TASK-001" "code-reviewer" "APPROVE" "Looks good. No blocking issues found."
run_validate "TASK-001"
assert_exit_code "receipt match: exit 0" "$VAL_EC" 0
assert_eq "receipt match: no output" "$VAL_OUTPUT" ""
teardown_temp_dir

# --- Test 48 (FEAT-016/TASK-005 reproduction): persisted body hash does NOT
# match the captured receipt — RECEIPT_MISMATCH, not a silent pass ---
setup_evidence_env "code-reviewer"
write_dispatched_review "TASK-001" "code-reviewer" "APPROVE" "Looks good. No blocking issues found." --tamper
run_validate "TASK-001"
assert_exit_code "receipt mismatch: exit 1" "$VAL_EC" 1
assert_contains "receipt mismatch: RECEIPT_MISMATCH line" "$VAL_OUTPUT" "RECEIPT_MISMATCH code-reviewer"
teardown_temp_dir

# --- Test 49 (FEAT-016/TASK-005 reproduction, other half): a persisted
# APPROVE verdict with NO matching receipt at all — the receipt-less
# fabrication shape — is ALSO RECEIPT_MISMATCH ---
setup_evidence_env "code-reviewer"
write_dispatched_review "TASK-001" "code-reviewer" "APPROVE" "Looks good. No blocking issues found." --no-receipt
run_validate "TASK-001"
assert_exit_code "receipt-less verdict: exit 1" "$VAL_EC" 1
assert_contains "receipt-less verdict: RECEIPT_MISMATCH line" "$VAL_OUTPUT" "RECEIPT_MISMATCH code-reviewer"
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
setup_evidence_env "code-reviewer"
write_dispatched_review "TASK-001" "code-reviewer" "CHANGES_REQUESTED" "Found a blocking issue in foo.sh." --tamper
run_validate "TASK-001"
assert_exit_code "changes_requested tampered: exit 1" "$VAL_EC" 1
assert_contains "changes_requested tampered: still UNAPPROVED" "$VAL_OUTPUT" "UNAPPROVED code-reviewer"
assert_contains "changes_requested tampered: also RECEIPT_MISMATCH" "$VAL_OUTPUT" "RECEIPT_MISMATCH code-reviewer"
teardown_temp_dir

# --- Test 52: an authorized SKIPPED stub is NEVER receipt-checked — it is
# orchestrator-authored (no dispatch, no transcript, no receipt ever exists
# for it), so requiring one would break every legitimate skip ---
setup_evidence_env "code-reviewer qa-reviewer" '.review_gate.conditional_dispatch = true'
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
setup_evidence_env "code-reviewer"
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

report_results
