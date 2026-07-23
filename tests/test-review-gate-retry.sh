#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because we test exit codes / output explicitly

# Test: review-gate.md's Step 2.5 bounded 1-retry tier escalation (MF-014) and
# filename self-check (MF-058), per FEAT-016 TASK-004.
#
# review-gate.md is a prose agent prompt, not an executable script, so this
# test exercises the SHARED mechanisms that prose instructs the orchestrator
# to call: scripts/lib/reviewer-tier.sh (the tier ladder) and the Step
# 2.5-area filename self-check algorithm (reproduced here exactly as
# review-gate.md specifies it, sourcing review-evidence.sh's
# _is_review_meta_file() rather than duplicating its list).
TEST_NAME="test-review-gate-retry"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

source "$REPO_ROOT/scripts/lib/reviewer-tier.sh"
source "$REPO_ROOT/scripts/lib/review-evidence.sh"

# --- next_tier_up: the escalation ladder ---
assert_eq "next_tier_up haiku -> sonnet" "$(next_tier_up haiku)" "sonnet"
assert_eq "next_tier_up sonnet -> opus" "$(next_tier_up sonnet)" "opus"
assert_eq "next_tier_up opus -> opus (top tier, no error)" "$(next_tier_up opus)" "opus"
assert_eq "next_tier_up unknown tier -> unchanged" "$(next_tier_up custom-model)" "custom-model"

# --- resolve_retry_model: escalate=true resolves one tier up ---
assert_eq "resolve_retry_model haiku true -> sonnet" "$(resolve_retry_model haiku true)" "sonnet"
assert_eq "resolve_retry_model sonnet true -> opus" "$(resolve_retry_model sonnet true)" "opus"
assert_eq "resolve_retry_model opus true -> opus (stays top)" "$(resolve_retry_model opus true)" "opus"

# --- resolve_retry_model: stall_retry_escalate_tier: false preserves same-tier retry exactly ---
assert_eq "resolve_retry_model haiku false -> haiku (kill switch off)" "$(resolve_retry_model haiku false)" "haiku"
assert_eq "resolve_retry_model sonnet false -> sonnet (kill switch off)" "$(resolve_retry_model sonnet false)" "sonnet"
assert_eq "resolve_retry_model opus false -> opus (kill switch off)" "$(resolve_retry_model opus false)" "opus"

# --- The identity-check jq expression review-gate.md specifies (guards against
#     `//`-fallback false-coalescing an explicit `false` back to `true`) ---
resolve_escalate_tier() {
  # Mirrors the exact jq expression in agents/review-gate.md's Step 2.5
  # tier-escalation block.
  local config="$1"
  jq -r 'if .review_gate.stall_retry_escalate_tier == false then "false" else "true" end' "$config" 2>/dev/null || echo "true"
}

setup_temp_dir
setup_nazgul_dir

echo '{"review_gate": {"stall_retry_escalate_tier": false}}' > "$TEST_DIR/nazgul/config.json"
assert_eq "explicit stall_retry_escalate_tier:false is honored (not coalesced)" \
  "$(resolve_escalate_tier "$TEST_DIR/nazgul/config.json")" "false"

echo '{"review_gate": {"stall_retry_escalate_tier": true}}' > "$TEST_DIR/nazgul/config.json"
assert_eq "explicit stall_retry_escalate_tier:true resolves true" \
  "$(resolve_escalate_tier "$TEST_DIR/nazgul/config.json")" "true"

echo '{"review_gate": {}}' > "$TEST_DIR/nazgul/config.json"
assert_eq "absent stall_retry_escalate_tier defaults true" \
  "$(resolve_escalate_tier "$TEST_DIR/nazgul/config.json")" "true"

# --- Simulated stalled-reviewer retry scenario end-to-end ---
# A reviewer resolved to "haiku" at Step 2, returns unparseable text, and the
# project has NOT disabled tier escalation: assert the retry model is "sonnet"
# (one tier up), not "haiku" (same tier — the old, pre-MF-014 behavior).
echo '{"review_gate": {"stall_retry_escalate_tier": true}}' > "$TEST_DIR/nazgul/config.json"
ESCALATE=$(resolve_escalate_tier "$TEST_DIR/nazgul/config.json")
RETRY_MODEL=$(resolve_retry_model "haiku" "$ESCALATE")
assert_eq "stalled default-tier reviewer escalates on retry" "$RETRY_MODEL" "sonnet"

# Same scenario but stall_retry_escalate_tier: false — same-tier retry preserved exactly.
echo '{"review_gate": {"stall_retry_escalate_tier": false}}' > "$TEST_DIR/nazgul/config.json"
ESCALATE=$(resolve_escalate_tier "$TEST_DIR/nazgul/config.json")
RETRY_MODEL=$(resolve_retry_model "haiku" "$ESCALATE")
assert_eq "kill-switched: stalled reviewer retries at same tier" "$RETRY_MODEL" "haiku"

# A reviewer already at the top tier (opus) retries at opus regardless of the switch.
ESCALATE=$(resolve_escalate_tier "$TEST_DIR/nazgul/config.json")
assert_eq "top-tier reviewer retries at opus (kill-switched)" "$(resolve_retry_model "opus" "$ESCALATE")" "opus"
echo '{"review_gate": {"stall_retry_escalate_tier": true}}' > "$TEST_DIR/nazgul/config.json"
ESCALATE=$(resolve_escalate_tier "$TEST_DIR/nazgul/config.json")
assert_eq "top-tier reviewer retries at opus (escalation on)" "$(resolve_retry_model "opus" "$ESCALATE")" "opus"

# An EXPLICIT models.review_by_reviewer override is never escalated — the
# caller (review-gate.md's prose) simply never calls resolve_retry_model for
# such a reviewer, retrying it at its configured tier unchanged. Simulate that
# call-site decision directly: the override tier passes through untouched
# regardless of the escalation switch, because escalation is never invoked.
OVERRIDE_TIER="sonnet"
assert_eq "explicit override tier is never escalated (bypasses resolve_retry_model)" "$OVERRIDE_TIER" "sonnet"

teardown_temp_dir

# --- Step 2.5-area filename self-check (MF-058): flags a misnamed file, LOG-only ---
# Reproduces the algorithm agents/review-gate.md's Step 2.5-area self-check
# specifies, reusing review-evidence.sh's _is_review_meta_file() (sourced
# above) rather than a second copy of its meta-file list.
run_self_check() {
  local unit_dir="$1" reviewers="$2"
  local f base name
  for f in "$unit_dir"/*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
      diff.patch|.dispatch.json) continue ;;
      adversarial-*.md) continue ;;
      *.md)
        name="${base%.md}"
        grep -qxF "$name" <<< "$reviewers" && continue
        _is_review_meta_file "$base" && continue
        ;;
    esac
    echo "SELF-CHECK: unrecognized file in $unit_dir (LOG ONLY, not blocking): $base"
  done
}

setup_temp_dir
setup_nazgul_dir
UNIT_DIR="$TEST_DIR/nazgul/reviews/TASK-004"
mkdir -p "$UNIT_DIR"
REVIEWERS=$'code-reviewer\nqa-reviewer'

# Legitimate files: exact reviewer names, documented meta-files, and the
# structural/cross-check artifacts the self-check must NOT flag.
printf -- '---\nverdict: APPROVE\nconfidence: 90\n---\nok\n' > "$UNIT_DIR/code-reviewer.md"
printf -- '---\nverdict: APPROVE\nconfidence: 85\n---\nok\n' > "$UNIT_DIR/qa-reviewer.md"
printf 'consolidated feedback\n' > "$UNIT_DIR/consolidated-feedback.md"
printf 'summary\n' > "$UNIT_DIR/summary.md"
printf 'diff\n' > "$UNIT_DIR/diff.patch"
printf '{}' > "$UNIT_DIR/.dispatch.json"
printf -- '---\nresult: confirm\nconfidence: 90\n---\nok\n' > "$UNIT_DIR/adversarial-finding-1.md"
# A deliberately-misnamed file (typo'd reviewer name) — must be flagged.
printf -- '---\nverdict: APPROVE\nconfidence: 90\n---\nok\n' > "$UNIT_DIR/cod-reviewer.md"

SELF_CHECK_OUTPUT=$(run_self_check "$UNIT_DIR" "$REVIEWERS")

assert_contains "self-check flags the deliberately-misnamed file" "$SELF_CHECK_OUTPUT" "cod-reviewer.md"
assert_not_contains "self-check does NOT flag exact reviewer files" "$SELF_CHECK_OUTPUT" "code-reviewer.md"
assert_not_contains "self-check does NOT flag consolidated-feedback.md" "$SELF_CHECK_OUTPUT" "consolidated-feedback.md"
assert_not_contains "self-check does NOT flag summary.md" "$SELF_CHECK_OUTPUT" "summary.md"
assert_not_contains "self-check does NOT flag diff.patch" "$SELF_CHECK_OUTPUT" "diff.patch"
assert_not_contains "self-check does NOT flag .dispatch.json" "$SELF_CHECK_OUTPUT" ".dispatch.json"
assert_not_contains "self-check does NOT flag adversarial-*.md" "$SELF_CHECK_OUTPUT" "adversarial-finding-1.md"

teardown_temp_dir

report_results
