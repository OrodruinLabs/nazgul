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

# Helper: build a nazgul dir with config listing given reviewers
# Usage: setup_evidence_env "code-reviewer qa-reviewer"
setup_evidence_env() {
  setup_temp_dir
  setup_nazgul_dir
  local reviewers_json
  # shellcheck disable=SC2086 # intentional word-splitting on space-separated reviewer list
  reviewers_json=$(printf '%s\n' $1 | jq -R . | jq -s .)
  create_config ".agents.reviewers = $reviewers_json"
}

# Helper: write a review file with the given verdict
# Usage: write_review TASK-001 code-reviewer APPROVED
write_review() {
  mkdir -p "$TEST_DIR/nazgul/reviews/$1"
  printf '# Review: %s\n\n## Verdict: %s\n' "$1" "$3" > "$TEST_DIR/nazgul/reviews/$1/$2.md"
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
setup_evidence_env "code-reviewer"
mkdir -p "$TEST_DIR/nazgul/reviews/TASK-001"
cat > "$TEST_DIR/nazgul/reviews/TASK-001/code-reviewer.md" << 'REVIEW_EOF'
# Review: TASK-001

## Verdict: APPROVE

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

report_results
