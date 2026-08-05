#!/usr/bin/env bash
set -uo pipefail

# Test: the assertion library itself cannot report a check it never made.
# FEAT-028 TASK-017 (retroactive audit, docs/test-audit-2026-08.md). Three vacuity
# repairs are pinned here, each against the defect the original could not catch:
#   V4 — a needle grep cannot evaluate was scored as "looked and found none"
#   V5 — report_results returned 0 when zero assertions ran
#   V5 — an absent tool was scored with _pass instead of a counted skip
TEST_NAME="test-assertion-vacuity"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

LIB="$SCRIPT_DIR/lib/assertions.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nazgul-assert-vacuity-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- V5: skipped checks must never be authored as passes or counted locally ---

FAKE_PASS_FILES=(
  test-board-sync-github.sh
  test-emit-event.sh
  test-formatter.sh
  test-in-flight-hold.sh
  test-notify.sh
  test-stack-utils.sh
  test-stop-hook.sh
  test-subagent-resume.sh
  test-subagent-stop.sh
  test-webhook-forward.sh
)
for test_file in "${FAKE_PASS_FILES[@]}"; do
  fake_passes=$(grep -nE '_pass .*([Ss][Kk][Ii][Pp]|not installed|running as root|unavailable)' \
    "$SCRIPT_DIR/$test_file" 2>/dev/null || true)
  assert_eq "V5: $test_file has no skipped check authored as _pass" "$fake_passes" ""
done

local_skip_defs=$(grep -Rsl '^_skip()' "$SCRIPT_DIR" --include='*.sh' \
  | grep -vF "$SCRIPT_DIR/lib/assertions.sh" || true)
assert_eq "V5: only the shared assertion library defines _skip" "$local_skip_defs" ""

# Drive the library through a child shell — the same way every test file uses it —
# and hand back stdout+stderr plus the child's exit code.
run_child() {
  local body="$1" out ec=0
  out=$(TEST_NAME=child bash -c "source '$LIB'
$body" 2>&1) || ec=$?
  printf '%s\n__EC__%s\n' "$out" "$ec"
}

# --- V4: a `-`-leading needle is unevaluable by grep, not a negative result ---

R=$(run_child 'assert_not_contains "dash needle" "the haystack contains --- right here" "---"')
assert_contains "V4: assert_not_contains with a dash needle now FAILS on a haystack that has it" \
  "$R" "FAIL: dash needle"
assert_contains "V4: it fails as a real negative result, not as a parse error" \
  "$R" "expected NOT to contain"
assert_not_contains "V4: it is never scored as a pass" "$R" "PASS: dash needle"

R=$(run_child 'assert_contains "dash needle present" "flags: --afk --yolo" "--afk"')
assert_contains "V4: assert_contains now evaluates a dash-leading needle that IS present" \
  "$R" "PASS: dash needle present"

printf 'plain body line\n' > "$WORK/f.txt"
R=$(run_child "assert_file_not_contains 'bad BRE' '$WORK/f.txt' 'unbalanced \\('")
assert_contains "V4: assert_file_not_contains on a malformed BRE FAILS" "$R" "FAIL: bad BRE"
assert_contains "V4: the malformed-BRE failure names the cause" "$R" "grep could not evaluate"

# --- V4: an absent file is never-looked, not looked-and-found-none (RULES §15) ---

R=$(run_child "assert_file_not_contains 'absent file' '$WORK/does-not-exist.txt' 'anything'")
assert_contains "V4: assert_file_not_contains on an absent file FAILS" "$R" "FAIL: absent file"
assert_contains "V4: the absent-file failure says absence cannot stand in for a negative" \
  "$R" "absence cannot stand in for a negative result"

# --- V5: a file that asserted nothing has not passed ---

R=$(run_child 'report_results')
assert_contains "V5: zero assertions reports NOTHING CHECKED" "$R" "NOTHING CHECKED"
assert_contains "V5: zero assertions uses the shared nothing-checked exit" "$R" "__EC__2"

R=$(run_child '_skip "tool absent"
report_results')
assert_contains "V5: a skip is printed as SKIP, never as PASS" "$R" "SKIP: tool absent"
assert_not_contains "V5: a skip never emits a PASS line" "$R" "PASS: tool absent"
assert_contains "V5: skips alone still report 0/0" "$R" "child: 0/0 passed"
assert_contains "V5: skips alone use the shared nothing-checked exit" "$R" "__EC__2"

R=$(run_child 'assert_eq "real check" a a
_skip "tool absent"
report_results')
assert_contains "V5: skips are counted apart from passes in the summary" "$R" "1 SKIPPED — not checked"
assert_contains "V5: a real check alongside a skip still exits 0" "$R" "__EC__0"

# --- Red-capability canary: the harness can still see a genuine failure here ---

R=$(run_child 'assert_eq "canary" got expected
report_results')
assert_contains "canary: a real mismatch is still reported FAIL" "$R" "FAIL: canary"
assert_contains "canary: a real mismatch still exits nonzero" "$R" "__EC__1"

report_results
