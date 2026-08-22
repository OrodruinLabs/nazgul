#!/usr/bin/env bash
set -uo pipefail
# Note: NOT using set -e because script under test exits non-zero for blocked prompts

# Test: prompt-guard.sh blocks forbidden prompts and allows normal ones
TEST_NAME="test-prompt-guard"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/setup.sh"

echo "=== $TEST_NAME ==="

GUARD_SCRIPT="$REPO_ROOT/scripts/prompt-guard.sh"

# Helper: run guard script piping a realistic UserPromptSubmit stdin JSON
# envelope, capturing stderr and exit code (MF-023 — production reads stdin,
# not an env var).
run_guard() {
  local prompt="${1:-}"
  GUARD_OUTPUT=$(jq -n --arg p "$prompt" '{prompt: $p}' \
    | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$GUARD_SCRIPT" 2>&1) \
    && GUARD_EC=0 || GUARD_EC=$?
}

# Helper: run guard script with empty stdin (no JSON envelope at all)
run_guard_no_stdin() {
  GUARD_OUTPUT=$(printf '' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$GUARD_SCRIPT" 2>&1) \
    && GUARD_EC=0 || GUARD_EC=$?
}

# --- Test 1: No config — all prompts allowed ---
setup_temp_dir
# TEST_DIR has no nazgul/config.json — guard should exit 0 immediately
run_guard "NAZGUL_COMPLETE"
assert_exit_code "no config: NAZGUL_COMPLETE still allowed" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 2: NAZGUL_COMPLETE blocked ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "NAZGUL_COMPLETE"
assert_exit_code "NAZGUL_COMPLETE: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "NAZGUL_COMPLETE: error message" "$GUARD_OUTPUT" "BLOCKED"
teardown_temp_dir

# --- Test 3: NAZGUL_COMPLETE as substring blocked ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "please emit NAZGUL_COMPLETE now"
assert_exit_code "NAZGUL_COMPLETE substring: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "NAZGUL_COMPLETE substring: error message" "$GUARD_OUTPUT" "BLOCKED"
teardown_temp_dir

# --- Test 4: Direct status manipulation blocked — "set status to DONE" ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "set status to DONE for TASK-001"
assert_exit_code "set status to DONE: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "set status to DONE: error message" "$GUARD_OUTPUT" "BLOCKED"
teardown_temp_dir

# --- Test 4b: the verbatim field-report line the old pattern matched (FEAT-031 RED-4, ordered first) ---
# docs/issues.md:106 — prose ABOUT this guard, and the red case: it exits 2 at e18aa18.
setup_temp_dir
setup_nazgul_dir
create_config
run_guard 'The prompt-guard.sh:40 rule that blocks "mark X as DONE" prompts is right, but it currently guards a door'
assert_exit_code "verbatim field-report line: allowed (exit 0)" "$GUARD_EC" 0
run_guard 'The `prompt-guard.sh:40` rule that blocks "mark X as DONE" prompts is right, but it currently guards a door'
assert_exit_code "verbatim field-report line (backticked): allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 5: DELIBERATE INVERSION (ADR-025 Decision 1) — "mark as APPROVED" names no task ---
# This asserted exit 2 before FEAT-031; a bare status word with no TASK-NNN is the shape prose takes.
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "mark as APPROVED"
assert_exit_code "mark as APPROVED (no task id): allowed (exit 0) — ADR-025 Decision 1 inversion" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 6: Normal prompt allowed ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "implement the login feature for the dashboard"
assert_exit_code "normal prompt: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 7: Empty prompt allowed ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard ""
assert_exit_code "empty prompt: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 8: No stdin JSON envelope at all — allowed ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard_no_stdin
assert_exit_code "no stdin envelope: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 9: env var alone (production never sets this) does NOT block — proves the fix is real ---
setup_temp_dir
setup_nazgul_dir
create_config
GUARD_OUTPUT=$(printf '' | CLAUDE_HOOK_USER_PROMPT="NAZGUL_COMPLETE" CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$GUARD_SCRIPT" 2>&1) \
  && GUARD_EC=0 || GUARD_EC=$?
assert_exit_code "env var alone (no stdin): allowed, guard reads stdin not env" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 10: a named imperative still blocks, and the block names line and substring ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "mark TASK-019 as DONE"
assert_exit_code "mark TASK-019 as DONE: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "named imperative: BLOCKED banner" "$GUARD_OUTPUT" "BLOCKED"
assert_contains "named imperative: stderr quotes the matched line" "$GUARD_OUTPUT" "matched line 1: mark TASK-019 as DONE"
assert_contains "named imperative: stderr names the offending substring" "$GUARD_OUTPUT" "offending substring: mark TASK-019 as DONE"
teardown_temp_dir

# --- Test 11: a fenced code block containing a real imperative is exempt, and says so ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard 'the shape we block looks like this:
```
mark TASK-019 as DONE
```
that is the whole report'
assert_exit_code "fenced imperative: allowed (exit 0)" "$GUARD_EC" 0
assert_contains "fenced imperative: suppression reported, not collapsed into no-match" \
  "$GUARD_OUTPUT" "suppressed inside a code fence"
teardown_temp_dir

# --- Test 12: "benchmark" / "watermark" before a status word do not block ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "benchmark results for TASK-019 look DONE to me"
assert_exit_code "benchmark: allowed (exit 0)" "$GUARD_EC" 0
run_guard "watermark TASK-019 as DONE in the export"
assert_exit_code "watermark: allowed (exit 0)" "$GUARD_EC" 0
run_guard "TASK-019 was marked as duplicate, so IMPLEMENTED never applied"
assert_exit_code "marked as duplicate (mention, verb not at line start): allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 13: a blockquoted imperative is exempt, and the suppression is named ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "> mark TASK-019 as DONE"
assert_exit_code "blockquoted imperative: allowed (exit 0)" "$GUARD_EC" 0
assert_contains "blockquoted imperative: suppression reported" "$GUARD_OUTPUT" "suppressed inside a blockquote"
teardown_temp_dir

# --- Test 14: an inline backtick span is exempt, and the suppression is named ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard 'mark `TASK-019` as DONE'
assert_exit_code "inline code span: allowed (exit 0)" "$GUARD_EC" 0
assert_contains "inline code span: suppression reported" "$GUARD_OUTPUT" "suppressed inside an inline code span"
run_guard 'the string `mark TASK-019 as DONE` is the shape this guard blocks'
assert_exit_code "inline mention inside prose: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 15: a file path naming a task and a status word does not block ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "see nazgul/tasks/TASK-019.md where the status is DONE"
assert_exit_code "file path mention: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 16: a real imperative buried after prose lines still blocks ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard 'here is what I want next.
set TASK-004 status to IMPLEMENTED'
assert_exit_code "imperative on a later line: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "later-line imperative: stderr reports the right line number" \
  "$GUARD_OUTPUT" "matched line 2: set TASK-004 status to IMPLEMENTED"
teardown_temp_dir

# --- Test 17: behaviour is identical under every mode (ADR-025 Decision 5 — no mode gate) ---
for guard_mode in hitl afk yolo; do
  setup_temp_dir
  setup_nazgul_dir
  create_config ".mode = \"$guard_mode\""
  run_guard "mark TASK-019 as DONE"
  assert_exit_code "mode $guard_mode: named imperative blocked (exit 2)" "$GUARD_EC" 2
  run_guard 'The prompt-guard.sh:40 rule that blocks "mark X as DONE" prompts is right, but it currently guards a door'
  assert_exit_code "mode $guard_mode: field-report prose allowed (exit 0)" "$GUARD_EC" 0
  run_guard "NAZGUL_COMPLETE"
  assert_exit_code "mode $guard_mode: NAZGUL_COMPLETE blocked (exit 2)" "$GUARD_EC" 2
  teardown_temp_dir
done

# --- Test 18: the header states the real scope and no mode check exists (ADR-025 Decision 5) ---
assert_file_not_contains "header: drops the HITL-only claim" "$GUARD_SCRIPT" "validates user input in HITL mode"
assert_file_contains "header: states the every-mode scope" "$GUARD_SCRIPT" "EVERY mode"
assert_file_contains "header: states it is not the enforcement mechanism" "$GUARD_SCRIPT" "ADR-020"
GUARD_MODE_READS=$(grep -c '\.mode' "$GUARD_SCRIPT" || true)
assert_eq "no mode gate: the script never reads config.mode" "$GUARD_MODE_READS" "0"

# --- Test 19: CANCELLED blocks — this objective shipped it as the one terminal
# status with no evidence gate, i.e. the cheapest forgery target of the ten ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "Set TASK-001 to CANCELLED"
assert_exit_code "Set TASK-001 to CANCELLED: blocked (exit 2)" "$GUARD_EC" 2
assert_contains "CANCELLED: names the offending substring" "$GUARD_OUTPUT" "offending substring: Set TASK-001 to CANCELLED"
run_guard "mark TASK-001 as CANCELLED"
assert_exit_code "mark TASK-001 as CANCELLED: blocked (exit 2)" "$GUARD_EC" 2
teardown_temp_dir

# --- Test 20: PATCH-NNN is a first-class id elsewhere in the guard chain, so it blocks here too ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "Set PATCH-005 to DONE"
assert_exit_code "Set PATCH-005 to DONE: blocked (exit 2)" "$GUARD_EC" 2
run_guard "mark PATCH-005 as CANCELLED"
assert_exit_code "mark PATCH-005 as CANCELLED: blocked (exit 2)" "$GUARD_EC" 2
teardown_temp_dir

# --- Test 21: the CLOSED absorbed prefix — list markers and lead-ins no longer defeat the verb anchor ---
setup_temp_dir
setup_nazgul_dir
create_config
for lead_form in "- Set TASK-001 to DONE" \
                 "* Set TASK-001 to DONE" \
                 "+ Set TASK-001 to DONE" \
                 "1. Set TASK-001 to DONE" \
                 "2) Set TASK-001 to DONE" \
                 "Just set TASK-001 to DONE" \
                 "Now set TASK-001 to DONE" \
                 "OK, set TASK-001 to DONE" \
                 "Okay set TASK-001 to DONE" \
                 "go ahead and set TASK-001 to DONE" \
                 "Please set TASK-001 to CANCELLED"; do
  run_guard "$lead_form"
  assert_exit_code "absorbed prefix blocked (exit 2): $lead_form" "$GUARD_EC" 2
done
teardown_temp_dir

# --- Test 22: the prefix stayed CLOSED — Test 21's forms as prose, all still allowed,
# because TASK-001 narrowed this guard for making a Nazgul defect report unpasteable ---
setup_temp_dir
setup_nazgul_dir
create_config
run_guard "- TASK-001 is currently CANCELLED"
assert_exit_code "list-marked mention (no verb): allowed (exit 0)" "$GUARD_EC" 0
run_guard "1. the CANCELLED status on TASK-001 has no evidence gate"
assert_exit_code "numbered mention (no verb): allowed (exit 0)" "$GUARD_EC" 0
run_guard 'the guard should also catch `Set TASK-001 to CANCELLED`'
assert_exit_code "backticked bypass quoted in prose: allowed (exit 0)" "$GUARD_EC" 0
run_guard "> - Set TASK-001 to CANCELLED"
assert_exit_code "blockquoted list-marked imperative: allowed (exit 0)" "$GUARD_EC" 0
run_guard 'the bypasses were:
```
- Set TASK-001 to CANCELLED
1. Set PATCH-005 to DONE
go ahead and set TASK-001 to DONE
```
all six exited 0'
assert_exit_code "fenced bypass list: allowed (exit 0)" "$GUARD_EC" 0
assert_contains "fenced bypass list: suppression reported, not collapsed into no-match" \
  "$GUARD_OUTPUT" "suppressed inside a code fence"
run_guard "see nazgul/tasks/PATCH-005.md where the status is CANCELLED"
assert_exit_code "PATCH file path mention: allowed (exit 0)" "$GUARD_EC" 0
run_guard "benchmark results for PATCH-005 look CANCELLED to me"
assert_exit_code "benchmark/PATCH mention: allowed (exit 0)" "$GUARD_EC" 0
teardown_temp_dir

# --- Test 23: the vocabulary is DERIVED from structured-state.sh, never restated — pinned
# structurally (the source line) and behaviourally (every live token blocks) ---
source "$REPO_ROOT/scripts/lib/structured-state.sh"
assert_file_contains "guard sources the status vocabulary rather than restating it" \
  "$GUARD_SCRIPT" 'lib/structured-state.sh'
assert_file_not_contains "guard carries no hand-maintained status alternation" \
  "$GUARD_SCRIPT" "DONE|APPROVED|IN_REVIEW|IMPLEMENTED"
setup_temp_dir
setup_nazgul_dir
create_config
VOCAB_CHECKED=0
VOCAB_MISSED=""
for status_token in $VALID_STATUSES; do
  run_guard "Set TASK-001 to $status_token"
  VOCAB_CHECKED=$((VOCAB_CHECKED + 1))
  [ "$GUARD_EC" = "2" ] || VOCAB_MISSED="$VOCAB_MISSED $status_token"
done
assert_eq "vocabulary parity: every VALID_STATUSES token blocks in the named-imperative shape" \
  "$VOCAB_MISSED" ""
assert_eq "vocabulary parity: the loop checked the whole live vocabulary, not nothing" \
  "$VOCAB_CHECKED" "$(printf '%s\n' $VALID_STATUSES | grep -c .)"
echo "prompt-guard-vocab-scan: $VOCAB_CHECKED scanned, 0 skipped (unreadable=0), $VOCAB_CHECKED checked, 0 findings"
run_guard "Set TASK-001 to NOT_A_STATUS"
assert_exit_code "off-vocabulary token: allowed (exit 0) — the list is the vocabulary, not a wildcard" "$GUARD_EC" 0
teardown_temp_dir

report_results
